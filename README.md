# NetWatch Observability PoC — CloudWatch Application Signals vs New Relic

> **検証コンセプト**: 大手キャリアが運用するネットワーク機器監視システム「NetWatch」を題材に、
> **CloudWatch Application Signals**（AWS ネイティブ）と **New Relic APM**（フェーズ 2）が
> それぞれ何をどこまで観測できるかを実機でハンズオン体験する。

---

## 目次

1. [アーキテクチャ概要](#1-アーキテクチャ概要)
2. [アプリケーション構成（NetWatch）](#2-アプリケーション構成netwatch)
3. [計装アーキテクチャ](#3-計装アーキテクチャ)
4. [作成される AWS リソース一覧](#4-作成される-aws-リソース一覧)
5. [費用概算](#5-費用概算)
6. [クイックスタート（CloudWatch フェーズ）](#6-クイックスタートcloudwatch-フェーズ)
7. [カオスシナリオ — ハンズオン学習ガイド](#7-カオスシナリオ--ハンズオン学習ガイド)
8. [CloudWatch Application Signals で確認する観点](#8-cloudwatch-application-signals-で確認する観点)
9. [CloudWatch Logs で確認する観点](#9-cloudwatch-logs-で確認する観点)
10. [Container Insights で確認する観点](#10-container-insights-で確認する観点)
11. [New Relic フェーズ（フェーズ 2・準備中）](#11-new-relic-フェーズフェーズ-2準備中)
12. [機能差比較表](#12-機能差比較表)
13. [PoC 後の削除手順](#13-poc-後の削除手順)
14. [前提・注意事項](#14-前提注意事項)

---

## 1. アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────────────────┐
│  EKS Cluster (obs-poc) — ap-northeast-1                             │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  EC2 Node (t3.small × 2)                                     │   │
│  │                                                              │   │
│  │  namespace: demo-ec2 (CloudWatch path)                       │   │
│  │                                                              │   │
│  │  ┌─────────────┐  HTTP  ┌────────────┐                       │   │
│  │  │ netwatch-ui │ ──────→│ device-api │                       │   │
│  │  │  (FastAPI   │        │ (FastAPI + │                       │   │
│  │  │  +Jinja2)   │ ──────→│  SQLite)   │                       │   │
│  │  │  [OTel SDK] │        │ [OTel SDK] │                       │   │
│  │  │  LoadBalancer│  HTTP  └────────────┘                       │   │
│  │  └──────┬──────┘        ┌────────────┐                       │   │
│  │         └──────────────→│ alert-api  │                       │   │
│  │                         │ (FastAPI)  │                       │   │
│  │                         │ [OTel SDK] │                       │   │
│  │                         └────────────┘                       │   │
│  │                              OTLP (gRPC :4315)               │   │
│  │                                    ↓                         │   │
│  │  namespace: amazon-cloudwatch                                │   │
│  │  ┌────────────────────────┐                                  │   │
│  │  │ CloudWatch Agent(ADOT) │──→ Application Signals / X-Ray   │   │
│  │  │                        │──→ CloudWatch Metrics            │   │
│  │  └────────────────────────┘                                  │   │
│  │  ┌──────────┐                                                │   │
│  │  │Fluent Bit│──→ CloudWatch Logs                             │   │
│  │  └──────────┘                                                │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘

ブラウザ ──→ ELB (LoadBalancer) ──→ netwatch-ui
                                        ↓ httpx (async)
                                   device-api / alert-api
                                        ↓ OTLP
                               CloudWatch Agent (4315)
                                        ↓
                            Application Signals / X-Ray
```

---

## 2. アプリケーション構成（NetWatch）

NetWatch は大手キャリアがネットワーク機器を監視する想定のシステムです。

### サービス一覧

| サービス | 役割 | ポート | 外部公開 |
|---------|------|--------|---------|
| **netwatch-ui** | ダッシュボード UI (FastAPI + Jinja2 + Tailwind CSS) | 8080 | ◎ LoadBalancer |
| **device-api** | ネットワーク機器 CRUD・フィルタ・カオス制御 | 8000 | × ClusterIP |
| **alert-api** | アラート管理・アラートストーム生成 | 8000 | × ClusterIP |

### 搭載データ

| 分類 | 内容 |
|-----|-----|
| **エリア** | 東京・大阪・名古屋・福岡・札幌 |
| **機器タイプ** | core_router, edge_router, l3_switch, l2_switch, firewall, load_balancer, access_point |
| **ステータス** | active, warning, critical, offline, maintenance |
| **初期台数** | 30 台 |
| **初期アラート** | 7 件（severity: critical / warning / info） |

### 画面一覧

| 画面 | URL | 内容 |
|-----|-----|-----|
| ダッシュボード | `/` | ステータスサマリ・エリア分布・最近のアラート |
| 機器一覧 | `/devices` | エリア・タイプ・ステータス・フリーワードで絞り込み |
| 機器詳細 | `/devices/{id}` | 機器情報・メトリクスバー・関連アラート |
| アラート一覧 | `/alerts` | 重大度・エリアフィルタ・解決ボタン |
| カオスコントロール | `/chaos` | カオスシナリオのON/OFFとCloudWatch調査ガイド |

### サービス間呼び出し（トレース生成源）

```
netwatch-ui:8080  ──GET /devices{?filters}──→  device-api:8000
netwatch-ui:8080  ──GET /devices/{id}──────→  device-api:8000
netwatch-ui:8080  ──GET /alerts{?filters}──→  alert-api:8000
netwatch-ui:8080  ──POST /chaos/*──────────→  device-api:8000 または alert-api:8000
device-api:8000   ──POST /chaos/*───────────→  (自身のカオス状態を変更)
```

httpx の非同期 HTTP クライアントが W3C TraceContext ヘッダーを自動伝播するため、
netwatch-ui → downstream のスパンが1本のトレースに結合されます。

---

## 3. 計装アーキテクチャ

### 「アプリに手を加えない」の定義

| 対象 | 変更有無 | 内容 |
|------|---------|------|
| `app.py` | **変更なし** | 純粋な FastAPI。OTel の import なし |
| `Dockerfile` | **変更なし** | `uvicorn` で起動するだけ |
| `requirements.txt` | **変更なし** | `fastapi`, `uvicorn`, `httpx`, `python-json-logger` のみ |
| K8s Deployment annotation | インフラ設定 | `instrumentation.opentelemetry.io/inject-python: "true"` |
| K8s Namespace annotation | インフラ設定 | OTel Operator が参照する注入トリガー |

### 計装フロー

```
EKS Add-on: amazon-cloudwatch-observability
  └─ OTel Operator: Namespace に inject-python アノテーションを検出
       └─ Init Container: opentelemetry-auto-instrumentation-python を注入
            └─ PYTHONPATH に sitecustomize.py を追加
                 ├─ FastAPI の全ルート → HTTPサーバースパン自動生成
                 ├─ httpx の全外部呼び出し → HTTPクライアントスパン自動生成
                 └─ W3C TraceContext ヘッダー自動伝播

スパン送信先:
  OTLP gRPC → cloudwatch-agent.amazon-cloudwatch:4315
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

| カテゴリ | リソース | 用途 |
|---------|---------|------|
| **EKS** | Cluster (obs-poc) | メインクラスター |
| | Managed Node Group (t3.small × 2) | EC2 path 実行環境 |
| | EKS Add-on: amazon-cloudwatch-observability | OTel Operator + ADOT + Fluent Bit |
| **ECR** | netwatch-ui, device-api, alert-api（計3リポジトリ） | アプリイメージ |
| **IAM** | IRSA ロール (app-signals-sa) | EC2 → CloudWatch / X-Ray |
| **VPC** | VPC + Subnet + SG | ネットワーク基盤 |
| | Interface Endpoints (ecr.api, ecr.dkr, logs, sts, monitoring, xray) | NAT 不使用 |
| **CloudWatch** | Application Signals | APM・サービスマップ・SLO |
| | Container Insights | K8s メトリクス |
| | Log Groups (/aws/containerinsights/obs-poc/application など) | アプリ・システムログ |
| | RUM App Monitor | フロントエンド監視（オプション） |
| | Synthetics Canary | 死活監視（オプション） |

---

## 5. 費用概算

| リソース | 時間単価 | 月額概算 |
|---------|---------|---------|
| EKS クラスター | $0.10/h | ~$75 |
| EC2 t3.small × 2 | $0.023/h × 2 | ~$35 |
| Application Signals (トレース) | 従量 | ~$5–15 |
| Container Insights | 従量 | ~$5–10 |
| CloudWatch Logs | 従量 | ~$3–5 |
| RUM + Synthetics（オプション） | 従量 | ~$3–5 |
| **合計（概算）** | | **~$125–145/月** |

> PoC 終了後は `make down` で即削除してください。

---

## 6. クイックスタート（CloudWatch フェーズ）

### 前提条件

```bash
aws --version       # >= 2.x
kubectl version     # >= 1.28
helm version        # >= 3.x
terraform version   # >= 1.5
docker version      # >= 24.x
```

### .env 設定

```bash
cp .env.example .env
```

**最低限設定する項目**:

```bash
AWS_REGION=ap-northeast-1
AWS_ACCOUNT_ID=123456789012   # 12桁のアカウント番号
CLUSTER_NAME=obs-poc
```

### 手順

```bash
# 1. EKS クラスター・AWS リソース作成（~20 分）
make up

# 2. Docker イメージビルド & ECR push
make build-push

# 3. CloudWatch スタックセットアップ（OTel Operator・アノテーション付与）
make install-cloudwatch-full

# 4. アプリデプロイ（demo-ec2 namespace）
make deploy-ec2

# 5. ELB URL の払い出しを待つ（1〜2 分）
kubectl get svc netwatch-ui -n demo-ec2 -w

# 6. .env に EC2_BASE を追記
EC2_LB=$(kubectl get svc netwatch-ui -n demo-ec2 \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "EC2_BASE=http://${EC2_LB}" >> .env

# 7. ブラウザで確認
source .env
open ${EC2_BASE}

# 8. 負荷生成（トレース・メトリクス生成）
make load

# 9. ステータス確認
make status
```

### 計装の確認

```bash
# OTel SDK init container が注入されているか確認
kubectl get pod -n demo-ec2 -l app=netwatch-ui \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'
# 期待値: opentelemetry-auto-instrumentation-python

# CloudWatch Application Signals にサービスが表示されているか確認
aws cloudwatch list-metrics \
  --namespace ApplicationSignals \
  --dimensions Name=Service,Value=netwatch-ui \
  --region ap-northeast-1 \
  --query 'Metrics[*].MetricName' \
  --output text
```

---

## 7. カオスシナリオ — ハンズオン学習ガイド

`{EC2_BASE}/chaos` のカオスコントロール画面、またはカオスシナリオ終了後にコンソールで確認します。

### シナリオ 1: スロークエリ（レイテンシ異常の検知）

**目的**: Application Signals の P99 レイテンシ急増を体験する

**操作**（カオス画面 → "Slow Query ON" ボタン、または）:
```bash
source .env
curl -X POST "${EC2_BASE}/api/chaos/slow-query" \
  -H "Content-Type: application/json" \
  -d '{"enabled": true, "slow_ms": 3000}'
make load    # 負荷生成
```

**CloudWatch で確認すること**:

| コンソール | 確認ポイント |
|-----------|------------|
| Application Signals > Services > device-api | Latency (P99) が 3s 超に急増しているか |
| Application Signals > Service Map | device-api ノードの色が変化しているか |
| X-Ray > Traces > Filter: duration > 2s | 遅延トレースの内訳でどのスパンが長いか |
| CloudWatch Logs Insights | `filter @duration > 2000` でスロークエリログを特定 |

**復旧**:
```bash
curl -X POST "${EC2_BASE}/api/chaos/reset"
```

---

### シナリオ 2: エラーインジェクション（エラー率モニタリング）

**目的**: Application Signals のエラー率グラフと Log Insights を使ったエラー分析を体験する

**操作**（カオス画面 → "Error Inject (30%)" ボタン、または）:
```bash
source .env
curl -X POST "${EC2_BASE}/api/chaos/error-inject" \
  -H "Content-Type: application/json" \
  -d '{"error_rate": 30}'
make load
```

**CloudWatch で確認すること**:

| コンソール | 確認ポイント |
|-----------|------------|
| Application Signals > Services > device-api | Error/Fault 率が約 30% に達しているか |
| Application Signals > Service Map | エッジ（矢印）がエラー状態を示す色に変わるか |
| X-Ray > Traces > Filter: error = true | 500 エラートレースのスパン詳細を確認 |
| CloudWatch Logs Insights | 下記クエリでエラーログを集計 |

```sql
fields @timestamp, service_name, level, message, status_code
| filter level = "ERROR"
| sort @timestamp desc
| limit 50
```

**復旧**:
```bash
curl -X POST "${EC2_BASE}/api/chaos/reset"
```

---

### シナリオ 3: アラートストーム（ログボリューム急増の検知）

**目的**: 異常なログボリューム増加を Container Insights と Logs Insights で捕捉する体験

**操作**（カオス画面 → "Alert Storm" ボタン、または）:
```bash
source .env
curl -X POST "${EC2_BASE}/api/chaos/alert-storm"
```

**CloudWatch で確認すること**:

| コンソール | 確認ポイント |
|-----------|------------|
| CloudWatch Logs > Log groups | /aws/containerinsights/obs-poc/application のインジェストバイト急増 |
| CloudWatch Logs Insights | `stats count(*) by bin(1m)` でログ件数の急増タイミングを確認 |
| Application Signals > alert-api | スループットの急増が見えるか |

```sql
fields @timestamp, service_name, severity, message
| filter service_name = "alert-api"
| stats count(*) as cnt by bin(1m)
| sort @timestamp asc
```

**復旧**:
```bash
curl -X POST "${EC2_BASE}/api/chaos/reset"
```

---

## 8. CloudWatch Application Signals で確認する観点

### コンソール URL

```
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:services
```

### 確認項目

| 観点 | 確認内容 | コンソールパス |
|------|---------|---------------|
| **サービス一覧** | netwatch-ui / device-api / alert-api が自動検出されているか | Application Signals > Services |
| **サービスマップ** | UI → device-api / alert-api の呼び出し依存グラフが自動生成されているか | Application Signals > Service Map |
| **SLO** | netwatch-ui や device-api に SLO（可用性 99.9%, レイテンシ P99 < 1s）を設定する | Application Signals > SLOs |
| **レイテンシ** | P50 / P90 / P99 の時系列グラフ | Service > Operations |
| **エラー率** | 4xx / 5xx の時系列グラフ | Service > Operations |
| **分散トレース** | X-Ray トレースマップ・スパン詳細・サービス間の因果関係 | X-Ray > Traces |

### Application Signals で自動的に取れるもの（コード変更なし）

- FastAPI の全ルートの HTTP サーバースパン（メソッド・URL・ステータスコード付き）
- httpx による下流 API 呼び出しの HTTP クライアントスパン
- W3C TraceContext による自動トレース伝播（netwatch-ui → device-api/alert-api が1本のトレースに）
- Python ランタイムメトリクス

### トレース分析の基本操作

```
X-Ray > Traces
  └─ Filter: service("netwatch-ui")
       └─ 遅いトレースを選択 → Trace Map でスパン間の時間を確認
            └─ device-api のスパンを展開 → どのエンドポイントで詰まっているか
```

---

## 9. CloudWatch Logs で確認する観点

### Log Group

```
/aws/containerinsights/obs-poc/application   ← アプリ JSON ログ
/aws/containerinsights/obs-poc/performance   ← Container Insights パフォーマンスログ
/aws/containerinsights/obs-poc/dataplane     ← K8s コントロールプレーンログ
```

### Logs Insights クエリ例

**エラーログ集計**:
```sql
fields @timestamp, service_name, level, message
| filter level = "ERROR"
| sort @timestamp desc
| limit 50
```

**レイテンシ分布（スロークエリ検知）**:
```sql
fields @timestamp, service_name, duration_ms, path
| filter duration_ms > 1000
| sort duration_ms desc
| limit 20
```

**サービス別ログ件数（アラートストーム確認）**:
```sql
fields @timestamp, service_name
| stats count(*) as cnt by service_name, bin(1m)
| sort @timestamp asc
```

**trace_id でのログ→トレース紐付け**:
```sql
fields @timestamp, trace_id, message, level
| filter trace_id = "1-xxxxxxxx-xxxxxxxxxxxxxxxxxxxx"
```

> ヒント: X-Ray でトレースを見つけたら trace_id をコピーして上記クエリで実行すると、
> そのトレースに対応するアプリログを即座に特定できます。

---

## 10. Container Insights で確認する観点

```
CloudWatch > Container Insights > Performance monitoring
クラスター: obs-poc
```

| 確認内容 | 見るべき指標 |
|---------|------------|
| Node レベル | CPU 使用率・Memory 使用率・Network I/O |
| Pod レベル | CPU throttling・Memory 上限接近 |
| Namespace レベル | demo-ec2 の Pod 全体のリソース消費 |

カオスシナリオ実行中は CPU・メモリが微増するため、負荷と Container Insights の相関を確認してください。

---

## 11. New Relic フェーズ（フェーズ 2・準備中）

CloudWatch での観測に慣れた後、同一アプリイメージを使って New Relic APM と比較します。

### フェーズ 2 の計画

```
# New Relic path（別 namespace で同一イメージを使用）
kubectl create namespace demo-newrelic

# k8s-agents-operator（nri-bundle に含まれる）を使って NR Python agent を自動注入
# annotation: instrumentation.newrelic.com/inject-python: "newrelic"
make install-newrelic-full
make deploy-newrelic
```

### フェーズ 2 で比較する観点

| 機能 | CloudWatch | New Relic |
|------|-----------|-----------|
| サービスマップの情報量 | レイテンシ・エラー率 | Apdex・スループット・エラー率・レイテンシ |
| エラー分析 | 個別トレースを目視 | Errors Inbox（自動グルーピング・stack trace） |
| 遅いトランザクション | 手動フィルタ | Transaction Traces（自動キャプチャ・Breakdown） |
| ログとトレースの紐付け | trace_id で手動検索（2ステップ） | Logs in Context（1クリック） |
| アラート条件の定義 | メトリクスアラーム | NRQL 1行でそのままアラート化 |

---

## 12. 機能差比較表

| 機能 | CloudWatch Application Signals | New Relic APM（フェーズ 2） |
|------|-------------------------------|----------------------------|
| **計装方式** | OTel Operator（CW addon）自動注入 | k8s-agents-operator 自動注入 |
| **エージェント** | ADOT（OTel SDK + AWS Distro） | New Relic Python APM agent |
| **APM トレース** | X-Ray + Application Signals | NR Distributed Tracing |
| **サービスマップ** | Application Signals Service Map | APM Service Map |
| **SLO 管理** | Application Signals SLOs | Service Levels |
| **K8s メトリクス** | Container Insights | NR Kubernetes |
| **ログ** | CloudWatch Logs (Fluent Bit) | NR Logs (Fluent Bit) |
| **Logs in Context** | trace_id で手動検索が必要 | トレース詳細から1クリック |
| **エラーグルーピング** | 個別トレースを目視 | Errors Inbox（自動グルーピング） |
| **遅いトランザクション検出** | 手動フィルタ | Transaction Traces（自動キャプチャ） |
| **ユーザー体感スコア** | なし | Apdex |
| **アラート柔軟性** | メトリクスアラーム（ディメンション固定） | NRQL で任意条件をそのままアラート化 |
| **コスト構造** | AWS 従量課金 | NR サブスクリプション |

---

## 13. PoC 後の削除手順

```bash
make down
```

削除される内容:

1. CloudWatch Synthetics canary 停止
2. Helm リリース削除（nri-bundle）
3. K8s namespace 削除（demo-ec2, demo-fargate, demo-newrelic, newrelic, aws-observability）
4. Terraform destroy（EKS, ECR × 3, VPC, IAM, CloudWatch RUM, Synthetics など）

残留リソース確認:
```bash
make destroy-check
```

---

## 14. 前提・注意事項

- **AWS アカウント**: `AdministratorAccess` 相当が必要（EKS, ECR, IAM, VPC, CloudWatch を作成するため）
- **VPC エンドポイント**: NAT Gateway の代わりに Interface Endpoints を使用（ecr.api, ecr.dkr, logs, sts, monitoring, xray）
- **シングル AZ 構成**: PoC コスト削減のため。本番は Multi-AZ 必須
- **ECR リポジトリ**: `force_delete=true` のため、イメージが残っていても `make down` で削除される
- **X-Ray サンプリング**: Central Sampling のため低サンプリングレートになる場合がある。Application Signals メトリクスは全リクエストから集計されるため、トレースが少なくてもメトリクスは正確
- **New Relic フェーズ**: `.env` に `NEW_RELIC_LICENSE_KEY` / `NEW_RELIC_ACCOUNT_ID` が必要
