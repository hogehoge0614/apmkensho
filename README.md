# NetWatch Observability PoC — CloudWatch Application Signals vs New Relic

> **検証コンセプト**: 大手キャリアが運用するネットワーク機器監視システム「NetWatch」を題材に、
> **CloudWatch Application Signals**（AWS ネイティブ）と **New Relic APM** が
> それぞれ何をどこまで観測できるかを実機でハンズオン体験する。

| ドキュメント | 内容 |
|-------------|------|
| このファイル | 環境構築・セットアップガイド |
| [`docs/observability-lab.md`](docs/observability-lab.md) | CloudWatch ハンズオン検証ガイド（全シナリオ手順） |
| [`docs/rum-lab.md`](docs/rum-lab.md) | CloudWatch RUM ブラウザ監視ハンズオン |
| [`docs/custom-metrics-lab.md`](docs/custom-metrics-lab.md) | StatsD カスタムメトリクスハンズオン |
| [`docs/environment-comparison.md`](docs/environment-comparison.md) | 3 環境構成の比較ガイド（EC2+AppSignals / Fargate+AppSignals / EC2+NewRelic） |
| [`docs/runbook.md`](docs/runbook.md) | Tier1/2/3 障害対応 Runbook・コマンド集 |

---

## 目次

1. [アーキテクチャ概要](#1-アーキテクチャ概要)
2. [アプリケーション構成（NetWatch）](#2-アプリケーション構成netwatch)
3. [計装アーキテクチャ](#3-計装アーキテクチャ)
4. [作成される AWS リソース一覧](#4-作成される-aws-リソース一覧)
5. [費用概算](#5-費用概算)
6. [クイックスタート](#6-クイックスタート)
7. [PoC 後の削除手順](#7-poc-後の削除手順)
8. [追加環境のセットアップ](#8-追加環境のセットアップ)
9. [機能差比較表](#9-機能差比較表)
10. [前提・注意事項](#10-前提注意事項)

---

## 1. アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────────────────────┐
│  EKS Cluster (obs-poc) — ap-northeast-1                                 │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  EC2 Node (t3.small × 2)       namespace: demo-ec2               │   │
│  │                                                                  │   │
│  │  ┌─────────────┐  HTTP   ┌────────────┐  HTTP  ┌──────────────┐ │   │
│  │  │ netwatch-ui │────────→│ device-api │───────→│metrics-      │ │   │
│  │  │  (FastAPI + │         │ (FastAPI + │        │collector     │ │   │
│  │  │   Jinja2)   │         │ PostgreSQL)│        │ (FastAPI)    │ │   │
│  │  │  [OTel SDK] │         │ [OTel SDK] │        │ [OTel SDK]   │ │   │
│  │  │ LoadBalancer│  HTTP   └────────────┘        └──────────────┘ │   │
│  │  └──────┬──────┘         ↑ RDS PostgreSQL                       │   │
│  │         │ HTTP           │ db.t3.micro                           │   │
│  │         └───────────→ ┌────────────┐                            │   │
│  │                       │ alert-api  │                            │   │
│  │                       │ (FastAPI)  │                            │   │
│  │                       │ [OTel SDK] │                            │   │
│  │                       └────────────┘                            │   │
│  │                                                                  │   │
│  │  全サービス → OTLP HTTP/protobuf :4316 → CloudWatch Agent (ADOT) │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Fargate Pod           namespace: demo-fargate                    │   │
│  │  (同一アプリ・同一 OTel 計装。Agent は DaemonSet ではなく Deployment) │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  EC2 Node              namespace: demo-newrelic                   │   │
│  │  (同一アプリ。OTel SDK の代わりに NR Python Agent を自動注入)        │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌──────────────────────────┐   ┌──────────────────────────────────┐   │
│  │ CloudWatch Agent (ADOT)  │   │ RDS PostgreSQL db.t3.micro       │   │
│  │  → Application Signals   │   │  private subnet, VPC内のみ接続可  │   │
│  │  → X-Ray                 │   │  DB: netwatch / user: netwatch   │   │
│  │  → CloudWatch Metrics    │   └──────────────────────────────────┘   │
│  └──────────────────────────┘                                           │
│  ┌──────────┐                                                           │
│  │Fluent Bit│──→ CloudWatch Logs                                        │
│  └──────────┘                                                           │
└─────────────────────────────────────────────────────────────────────────┘

トレースの流れ（3ホップ）:
  ブラウザ → [span1: netwatch-ui GET /devices/{id}]
                 → [span2: device-api GET /devices/{id}]  ← PostgreSQL クエリ
                     → [span3: metrics-collector GET /metrics/{id}]
```

### なぜ 3 ホップにするのか

X-Ray / Application Signals の分散トレースで「どのサービスのどの操作で遅延が発生しているか」を学ぶには、最低 3 段のスパンが必要です。2 ホップではトレースマップが単純すぎてハンズオンになりません。

| ホップ | サービス | 操作 |
|--------|---------|------|
| 1st | netwatch-ui | ユーザーのブラウザリクエストを受けて device-api を呼ぶ |
| 2nd | device-api | RDS から機器情報を取得し metrics-collector を呼ぶ |
| 3rd | metrics-collector | 機器 ID とステータスに基づくメトリクスを返す |

> 上図は **EC2 + App Signals** 環境の構成です。Fargate + App Signals / EC2 + New Relic の構成差は [`docs/environment-comparison.md`](docs/environment-comparison.md) を参照してください。

---

## 2. アプリケーション構成（NetWatch）

NetWatch は大手キャリアがネットワーク機器を監視する想定のシステムです。

### サービス一覧

| サービス | 役割 | ポート | 外部公開 |
|---------|------|--------|---------|
| **netwatch-ui** | ダッシュボード UI (FastAPI + Jinja2 + Tailwind CSS) | 8080 | ◎ LoadBalancer |
| **device-api** | 機器 CRUD・フィルタ・カオス制御（RDS PostgreSQL 使用） | 8000 | × ClusterIP |
| **alert-api** | アラート管理・アラートストーム生成（in-memory） | 8000 | × ClusterIP |
| **metrics-collector** | 機器メトリクス収集 API（device-api から呼ばれる 3rd hop） | 8000 | × ClusterIP |

### 搭載データ

| 分類 | 内容 |
|-----|-----|
| **エリア** | 東京・大阪・名古屋・福岡・札幌 |
| **機器タイプ** | core_router, edge_router, l3_switch, l2_switch, firewall, load_balancer, access_point |
| **ステータス** | active, warning, critical, offline, maintenance |
| **初期台数** | 30 台（RDS に永続化） |
| **初期アラート** | 7 件（severity: critical / warning / info） |

### 画面一覧

| 画面 | URL | 内容 |
|-----|-----|-----|
| ダッシュボード | `/` | ステータスサマリ・エリア分布・最近のアラート |
| 機器一覧 | `/devices` | エリア・タイプ・ステータス・フリーワードで絞り込み |
| 機器詳細 | `/devices/{id}` | 機器情報・メトリクスバー・関連アラート（3ホップトレースの起点） |
| アラート一覧 | `/alerts` | 重大度・エリアフィルタ・解決ボタン |
| カオスコントロール | `/chaos` | カオスシナリオのON/OFFとCloudWatch調査ガイド |

### サービス間呼び出し

```
netwatch-ui:8080  ──GET /devices{?filters}──────→  device-api:8000
netwatch-ui:8080  ──GET /devices/{id}────────────→  device-api:8000
                                                         └──GET /metrics/{id}──→  metrics-collector:8000
netwatch-ui:8080  ──GET /alerts{?filters}────────→  alert-api:8000
netwatch-ui:8080  ──POST /api/chaos/*────────────→  device-api または alert-api
```

OTel auto-instrumentation が httpx の全呼び出しに W3C TraceContext ヘッダーを自動付与するため、`GET /devices/{id}` のトレースは自動的に 3 段のスパンとして記録されます。

---

## 3. 計装アーキテクチャ

> この節は **EC2 + App Signals** 環境の計装フローを示します。Fargate 環境は Agent の起動方式が異なり、New Relic 環境は NR Python Agent を使用します。詳細は [`docs/environment-comparison.md`](docs/environment-comparison.md) を参照してください。

### 「アプリに手を加えない」の定義

| 対象 | 変更有無 | 内容 |
|------|---------|------|
| `app.py` | **最小限** | OTel の import なし。StatsD UDP 送信（socket 標準ライブラリのみ）と RUM snippet 生成を追加 |
| `Dockerfile` | **変更なし** | `uvicorn` で起動するだけ |
| `requirements.txt` | **変更なし** | `fastapi`, `uvicorn`, `httpx`, `python-json-logger` のみ |
| K8s Deployment annotation | インフラ設定 | `instrumentation.opentelemetry.io/inject-python: "true"` |

### 計装フロー

```
EKS Add-on: amazon-cloudwatch-observability
  └─ OTel Operator: Namespace に inject-python アノテーションを検出
       └─ Init Container: opentelemetry-auto-instrumentation-python を注入
            └─ PYTHONPATH に sitecustomize.py を追加
                 ├─ FastAPI の全ルート → HTTP サーバースパン自動生成
                 ├─ httpx の全外部呼び出し → HTTP クライアントスパン自動生成
                 └─ W3C TraceContext ヘッダー自動伝播

スパン送信先:
  OTLP HTTP/protobuf → cloudwatch-agent.amazon-cloudwatch:4316
    → CloudWatch Application Signals（APM・サービスマップ・SLO）
    → AWS X-Ray（分散トレース）

ログ:
  stdout（JSON 構造化）→ Fluent Bit → CloudWatch Logs
    /aws/containerinsights/obs-poc/application

メトリクス:
  Container Insights → CloudWatch Metrics
```

---

## 4. 作成される AWS リソース一覧

> `make up`（Terraform）で作成される共通リソースの一覧です。Fargate Profile は Terraform に含まれます。New Relic 用の追加リソース（nri-bundle Helm リリース）は `make install-newrelic-full` で別途インストールします。

| カテゴリ | リソース | 用途 |
|---------|---------|------|
| **EKS** | Cluster (obs-poc) | メインクラスター |
| | Managed Node Group (t3.small × 2) | EC2 アプリ実行環境 |
| | Fargate Profile | Fargate アプリ実行環境 |
| | EKS Add-on: amazon-cloudwatch-observability | OTel Operator + ADOT + Fluent Bit |
| **ECR** | netwatch-ui, device-api, alert-api, metrics-collector（計4リポジトリ） | アプリイメージ |
| **RDS** | PostgreSQL 16 db.t3.micro（シングルAZ, プライベートサブネット） | 機器マスターデータ |
| **IAM** | IRSA ロール (app-signals-sa) | CloudWatch / X-Ray 書き込み権限 |
| **VPC** | VPC + Subnet + SG | ネットワーク基盤 |
| | Interface Endpoints (ecr.api, ecr.dkr, logs, sts, monitoring, xray) | NAT 不使用 |
| **CloudWatch** | Application Signals | APM・サービスマップ・SLO |
| | Container Insights | K8s メトリクス |
| | Log Groups (/aws/containerinsights/obs-poc/application など) | アプリ・システムログ |
| | RUM App Monitor | フロントエンド監視（オプション） |
| | Synthetics Canary | 死活監視（オプション・デフォルト停止） |

---

## 5. 費用概算

| リソース | 時間単価 | 月額概算 |
|---------|---------|---------|
| EKS クラスター | $0.10/h | ~$75 |
| EC2 t3.small × 2 | $0.023/h × 2 | ~$35 |
| RDS PostgreSQL db.t3.micro | $0.022/h | ~$16 |
| Application Signals（トレース） | 従量 | ~$5–15 |
| Container Insights | 従量 | ~$5–10 |
| CloudWatch Logs | 従量 | ~$3–5 |
| RUM + Synthetics（オプション・停止中は無料） | 従量 | ~$3–5 |
| **合計（概算）** | | **~$140–160/月** |

> **注意**: Synthetics Canary はデフォルト停止状態です。使用時のみ `aws synthetics start-canary` で開始してください。PoC 終了後は必ず `make down` で削除してください。

---

## 6. クイックスタート

### 前提条件

以下のツールがインストール・設定済みであること:

```bash
aws --version        # >= 2.x（ap-northeast-1 アクセス可能なプロファイル設定済み）
kubectl version      # >= 1.28
helm version         # >= 3.x
terraform version    # >= 1.5
docker version       # >= 24.x（Docker Desktop 起動済み）
```

```bash
make check-prereq    # 上記ツールと AWS 認証情報を一括確認
```

### .env 設定

```bash
cp .env.example .env
```

`.env` を開いて以下の項目を設定してください:

```bash
AWS_REGION=ap-northeast-1
AWS_ACCOUNT_ID=123456789012    # 自分の AWS アカウント番号（12桁）
CLUSTER_NAME=obs-poc
```

### セットアップ手順

> このクイックスタートは **EC2 + App Signals** 環境の手順です。  
> Fargate + App Signals / EC2 + New Relic のセットアップは [セクション 8](#8-追加環境のセットアップ) を参照してください。

#### Step 1: インフラ構築（約20分）

```bash
make up
```

作成されるリソース: EKS クラスター、Managed Node Group (t3.small × 2)、Fargate Profile、RDS PostgreSQL、VPC、ECR リポジトリ × 4、IAM ロール、Interface VPC Endpoints

#### Step 2: Kubernetes シークレット作成

```bash
make create-secrets
```

RDS の接続情報（ホスト名・ユーザー・パスワード）を K8s Secret として作成します。

#### Step 3: アプリイメージのビルド & ECR プッシュ（約10分）

```bash
make build-push
```

4サービス（netwatch-ui / device-api / alert-api / metrics-collector）を Docker でビルドして ECR にプッシュします。

#### Step 4: CloudWatch スタックのセットアップ（約5分）

```bash
make install-cloudwatch-full
```

設定されるもの:
- EKS Add-on `amazon-cloudwatch-observability`（OTel Operator + ADOT + Fluent Bit）
- IRSA サービスアカウント（CloudWatch / X-Ray 書き込み権限）
- Namespace `demo-ec2` への OTel 自動注入アノテーション

#### Step 5: アプリのデプロイ（約3分）

```bash
make ec2-appsignals-deploy
```

作成されるもの: Namespace `demo-ec2`、4サービスの Deployment / Service

#### Step 6: デプロイ確認

```bash
make ec2-appsignals-verify
```

Pod の起動状態・OTel init container の注入・Application Signals コンソール URL を表示します。

#### Step 7: LoadBalancer URL の取得と .env 更新

```bash
# ELB が払い出されるまで 1〜2 分待つ
kubectl get svc netwatch-ui -n demo-ec2 -w
# EXTERNAL-IP 列に hostname が表示されたら Ctrl+C で停止

# .env に追記
EC2_LB=$(kubectl get svc netwatch-ui -n demo-ec2 \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "EC2_BASE=http://${EC2_LB}" >> .env
source .env
```

#### Step 8: ブラウザで確認

```bash
open ${EC2_BASE}
```

NetWatch のダッシュボードが表示されれば成功です。

#### Step 9: トレース・メトリクスの初期生成

```bash
make load
```

Application Signals / X-Ray にデータが出始めるまで 2〜3 分かかります。`make load` は `.env` に設定された `EC2_BASE` / `FARGATE_BASE` / `NEWRELIC_BASE` の到達可能な環境すべてにトラフィックを送信します。

---

### 計装の確認

デプロイ後、以下のコマンドで OTel 計装が正しく動作しているか確認してください:

```bash
# OTel SDK init container が4サービスすべてに注入されているか確認
# 期待値: opentelemetry-auto-instrumentation-python が含まれること
for svc in netwatch-ui device-api alert-api metrics-collector; do
  echo -n "${svc}: "
  kubectl get pod -n demo-ec2 -l app=${svc} \
    -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null
  echo ""
done

# RDS 接続確認（db_initialized が出ていれば成功）
kubectl logs -n demo-ec2 -l app=device-api --tail=30 \
  | grep -E "startup|db_initialized|ERROR"

# 3ホップトレースを1本生成して Application Signals へ送信
curl -s "${EC2_BASE}/devices/TKY-CORE-001" > /dev/null
echo "トレース送信完了（Application Signals に反映されるまで 2〜3 分）"
```

CloudWatch コンソールで確認:
```
Application Signals > Services
  → netwatch-ui / device-api / alert-api / metrics-collector の4サービスが表示されること

Application Signals > Service Map
  → netwatch-ui → device-api → metrics-collector の3段グラフが表示されること
```

---

### よくあるトラブル

| 症状 | 確認コマンド | 対処 |
|------|------------|------|
| App Signals にサービスが出ない | `make load` でトレースを生成 → 2〜3 分待つ | OTel init container を確認、ログにエラーがないか確認 |
| Pod が起動しない / CrashLoop | `kubectl describe pod -n demo-ec2 <pod>` | イメージが ECR に存在するか確認（`make build-push` 済みか） |
| `/devices` でエラーが出る | `kubectl logs -n demo-ec2 -l app=device-api --tail=50` | RDS 接続エラーがあれば `make create-secrets` → `make ec2-appsignals-deploy` |
| LoadBalancer の IP が出ない | `kubectl get svc -n demo-ec2` | ELB 払い出しに 3〜5 分かかることがある。VPC Endpoint 設定を確認 |

---

## 7. PoC 後の削除手順

```bash
make down
```

削除されるリソース:

1. CloudWatch Synthetics canary 停止
2. Helm リリース削除
3. K8s namespace 削除（demo-ec2, demo-fargate, demo-newrelic, newrelic, aws-observability）
4. Terraform destroy（EKS, ECR × 4, RDS, VPC, IAM, CloudWatch RUM, Synthetics など）

削除後の残留リソース確認:

```bash
make destroy-check
```

> ECR リポジトリは `force_delete = true` のため、イメージが残っていても削除されます。

---

## 8. 追加環境のセットアップ

EC2 + App Signals（クイックスタート）に加えて、以下の 2 環境が用意されています。環境ごとのアーキテクチャ・機能差は [`docs/environment-comparison.md`](docs/environment-comparison.md) を参照してください。

> **前提:** Step 1〜3（`make up` / `make create-secrets` / `make build-push`）が完了していること。

### Fargate + App Signals

同一アプリイメージを Fargate 上にデプロイし、EC2 との挙動の違いを確認します。k8s/fargate/ の全マニフェストが用意済みです。

```bash
make install-cloudwatch-full       # CloudWatch スタック（EC2 と共用可）
make fargate-appsignals-deploy     # demo-fargate namespace にデプロイ
make fargate-appsignals-verify     # Pod の起動確認

# Fargate LB URL を .env に追記
FARGATE_LB=$(kubectl get svc netwatch-ui -n demo-fargate \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "FARGATE_BASE=http://${FARGATE_LB}" >> .env
source .env

make load                          # トラフィック生成（EC2・Fargate 両方に送信）
```

> **Fargate の制約:** DaemonSet 非対応のため StatsD カスタムメトリクスは未対応。CloudWatch Agent は Deployment として別途起動します。

### EC2 + New Relic

CloudWatch での観測に慣れた後、同一アプリイメージを使って New Relic APM と比較します。k8s/newrelic/ の全マニフェストが用意済みです。

```bash
# .env に以下を設定してから実行
# NEW_RELIC_LICENSE_KEY=...
# NEW_RELIC_ACCOUNT_ID=...

make install-newrelic-full         # nri-bundle Helm + k8s-agents-operator インストール
make ec2-newrelic-deploy           # demo-newrelic namespace にデプロイ
make ec2-newrelic-verify           # NR agent 注入の確認

# NR LB URL を .env に追記
NEWRELIC_LB=$(kubectl get svc netwatch-ui -n demo-newrelic \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "NEWRELIC_BASE=http://${NEWRELIC_LB}" >> .env
source .env

make load                          # トラフィック生成（到達可能な全環境に送信）
```

New Relic は `instrumentation.newrelic.com/inject-python: "newrelic"` アノテーションで NR Python Agent を init container として自動注入します（`.env` に `NEW_RELIC_LICENSE_KEY` / `NEW_RELIC_ACCOUNT_ID` が必要）。

---

## 9. 機能差比較表

| 機能 | CloudWatch Application Signals | New Relic APM |
|------|-------------------------------|----------------------------|
| **計装方式** | OTel Operator（CW addon）自動注入 | k8s-agents-operator 自動注入 |
| **エージェント** | ADOT（OTel SDK + AWS Distro） | New Relic Python APM agent |
| **APM トレース** | X-Ray + Application Signals | NR Distributed Tracing |
| **サービスマップ** | Application Signals Service Map | APM Service Map |
| **SLO 管理** | Application Signals SLOs | Service Levels |
| **K8s メトリクス** | Container Insights | NR Kubernetes |
| **ログ** | CloudWatch Logs（Fluent Bit） | NR Logs（Fluent Bit） |
| **Logs in Context** | trace_id で手動検索（2ステップ） | トレース詳細から1クリック |
| **エラーグルーピング** | 個別トレースを目視 | Errors Inbox（自動グルーピング） |
| **遅いトランザクション検出** | 手動フィルタ | Transaction Traces（自動キャプチャ） |
| **ユーザー体感スコア** | なし | Apdex |
| **アラート柔軟性** | メトリクスアラーム（ディメンション固定） | NRQL で任意条件をそのままアラート化 |
| **コスト構造** | AWS 従量課金 | NR サブスクリプション |

---

## 10. 前提・注意事項

- **AWS アカウント**: `AdministratorAccess` 相当が必要（EKS, ECR, IAM, VPC, CloudWatch を作成するため）
- **VPC エンドポイント**: NAT Gateway の代わりに Interface Endpoints を使用（ecr.api, ecr.dkr, logs, sts, monitoring, xray）
- **シングル AZ 構成**: PoC コスト削減のため。本番は Multi-AZ 必須
- **ECR リポジトリ**: `force_delete = true` のため、イメージが残っていても `make down` で削除される
- **X-Ray サンプリング**: Central Sampling のため低サンプリングレートになる場合がある。Application Signals メトリクスは全リクエストから集計されるため、トレースが少なくてもメトリクスは正確
- **OTel プロトコル**: init container が `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` を設定するため、ポートは 4316（HTTP/protobuf）を使用
- **New Relic**: `.env` に `NEW_RELIC_LICENSE_KEY` / `NEW_RELIC_ACCOUNT_ID` が必要
