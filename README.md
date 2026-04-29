# Observability PoC — CloudWatch Application Signals vs New Relic

> **検証コンセプト**: 同一のアプリコード・同一の Docker イメージを使い、インフラ側の設定だけで
> **CloudWatch Application Signals**（AWS ネイティブ）と **New Relic APM**（New Relic エージェント）
> がそれぞれどこまで観測できるかを比較する。

---

## 目次

1. [検証コンセプトと計装アーキテクチャ](#1-検証コンセプトと計装アーキテクチャ)
2. [全体構成図](#2-全体構成図)
3. [作成される AWS リソース一覧](#3-作成される-aws-リソース一覧)
4. [費用概算](#4-費用概算)
5. [サンプルアプリの構成](#5-サンプルアプリの構成)
6. [トレース分析用シナリオ](#6-トレース分析用シナリオ)
7. [クイックスタート](#7-クイックスタート)
8. [CloudWatch Application Signals で確認する観点](#8-cloudwatch-application-signals-で確認する観点)
9. [Container Insights で確認する観点](#9-container-insights-で確認する観点)
10. [CloudWatch Logs で確認する観点](#10-cloudwatch-logs-で確認する観点)
11. [New Relic APM で確認する観点](#11-new-relic-apm-で確認する観点)
12. [New Relic Kubernetes で確認する観点](#12-new-relic-kubernetes-で確認する観点)
13. [New Relic Logs で確認する観点](#13-new-relic-logs-で確認する観点)
14. [機能差比較表](#14-機能差比較表)
15. [PoC 後の削除手順](#15-poc-後の削除手順)
16. [前提・注意事項](#16-前提注意事項)

---

## 1. 検証コンセプトと計装アーキテクチャ

### 「アプリに手を加えない」の定義

| 対象 | 変更有無 | 内容 |
|------|---------|------|
| `app.py`（アプリコード） | **変更なし** | 純粋な FastAPI。OTel/NR の import なし |
| `Dockerfile` | **変更なし** | `uvicorn` で起動するだけ |
| `requirements.txt` | **変更なし** | `fastapi`, `uvicorn`, `httpx`, `python-json-logger` のみ |
| k8s Deployment annotation | インフラ設定 | エージェント注入のアノテーション |
| k8s Namespace annotation | インフラ設定 | Operator が参照する注入トリガー |
| Helm values | インフラ設定 | Operator/エージェントの設定 |

アプリのソースコード・イメージは CloudWatch path / New Relic path で**完全に同一**。

### 計装フロー（アプリ変更ゼロ）

```
CloudWatch Application Signals path (namespace: demo-ec2, demo-fargate)
─────────────────────────────────────────────────────────────────────
App Pod（プレーンな FastAPI イメージ）
  ↓ OTel Operator（amazon-cloudwatch-observability EKS Add-on 内蔵）
    Pod annotation: instrumentation.opentelemetry.io/inject-python: "true"
    → OTel Python SDK を init container として自動注入
  ↓ OTel SDK が FastAPI・httpx を自動計装
  ↓ OTLP → cloudwatch-agent.amazon-cloudwatch:4317（ADOT）
  → CloudWatch Application Signals（APM + Service Map + SLO）
  → X-Ray（Distributed Tracing）
  → CloudWatch Logs（Fluent Bit）
  → Container Insights（メトリクス）

New Relic APM path (namespace: demo-newrelic)
─────────────────────────────────────────────────────────────────────
同一の App Pod（同じプレーンな FastAPI イメージ）
  ↓ k8s-agents-operator（nri-bundle に含まれる）
    Pod annotation: instrumentation.newrelic.com/inject-python: "newrelic"
    Instrumentation CR → NR Python agent を init container として自動注入
  ↓ NR Python agent が FastAPI を自動計装
  → New Relic APM（APM + Distributed Tracing + Service Maps）
  → New Relic Kubernetes（nri-bundle DaemonSet）
  → New Relic Logs（Fluent Bit）
```

### 2 つのパスの独立性

| | CloudWatch path | New Relic path |
|--|--|--|
| **注入 Operator** | OTel Operator（CW addon 内蔵） | k8s-agents-operator（nri-bundle） |
| **注入アノテーション** | `instrumentation.opentelemetry.io/inject-python: "true"` | `instrumentation.newrelic.com/inject-python: "newrelic"` |
| **エージェント** | ADOT（OTel SDK + AWS Distro） | New Relic Python APM agent |
| **データ送信先** | CloudWatch（AWS リージョン内） | New Relic（SaaS） |
| **namespace** | `demo-ec2` / `demo-fargate` | `demo-newrelic` |
| **アプリイメージ** | 同一 | 同一 |

2 つのパスは完全に独立。OTel のデータが New Relic に流れ込むことはなく、逆もない。

---

## 2. 全体構成図

```
┌─────────────────────────────────────────────────────────────────────┐
│  EKS Cluster (obs-poc) — ap-northeast-1                             │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  EC2 Node (t3.medium)                                        │   │
│  │                                                              │   │
│  │  namespace: demo-ec2 (CloudWatch path)                       │   │
│  │  ┌──────────────┐  ┌─────┐  ┌─────────┐  ┌──────────┐      │   │
│  │  │ frontend-ui  │  │ bff │  │order-api│  │ ...      │      │   │
│  │  │ [OTel SDK]   │  │[OTel│  │ [OTel]  │  │ [OTel]   │      │   │
│  │  └──────┬───────┘  └──┬──┘  └────┬────┘  └────┬─────┘      │   │
│  │         └─────────────┴──────────┴─────────────┘            │   │
│  │                        OTLP (4317)                           │   │
│  │                            ↓                                 │   │
│  │  namespace: amazon-cloudwatch                                │   │
│  │  ┌──────────────────────┐                                    │   │
│  │  │ CloudWatch Agent     │ → Application Signals / X-Ray      │   │
│  │  │ (ADOT)               │ → CloudWatch Metrics               │   │
│  │  └──────────────────────┘                                    │   │
│  │  ┌──────────┐                                                │   │
│  │  │Fluent Bit│ → CloudWatch Logs                              │   │
│  │  └──────────┘                                                │   │
│  │                                                              │   │
│  │  namespace: demo-newrelic (New Relic path)                   │   │
│  │  ┌──────────────┐  ┌─────┐  ┌─────────┐  ┌──────────┐      │   │
│  │  │ frontend-ui  │  │ bff │  │order-api│  │ ...      │      │   │
│  │  │ [NR agent]   │  │ [NR]│  │  [NR]   │  │  [NR]    │      │   │
│  │  └──────┬───────┘  └──┬──┘  └────┬────┘  └────┬─────┘      │   │
│  │         └─────────────┴──────────┴─────────────┘            │   │
│  │                    NR agent protocol                         │   │
│  │                            ↓                                 │   │
│  │                    New Relic APM (SaaS)                      │   │
│  │                                                              │   │
│  │  namespace: newrelic                                         │   │
│  │  ┌────────────────────────────────────────────┐             │   │
│  │  │ nri-bundle: infra DaemonSet + k8s-agents-  │             │   │
│  │  │ operator + Fluent Bit + kube-state-metrics  │             │   │
│  │  └────────────────────────────────────────────┘             │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  Fargate Profile → namespace: demo-fargate                          │
│  (CloudWatch path のみ。NR DaemonSet は Fargate 非対応)              │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. 作成される AWS リソース一覧

| カテゴリ | リソース | 用途 |
|---------|---------|------|
| **EKS** | Cluster (obs-poc) | メインクラスター |
| | Managed Node Group (t3.medium × 1) | EC2 path 実行環境 |
| | Fargate Profile | demo-fargate namespace |
| | EKS Add-on: amazon-cloudwatch-observability | OTel Operator + ADOT + Fluent Bit |
| **ECR** | 6 リポジトリ | アプリイメージ |
| **IAM** | IRSA ロール (app-signals-sa) | EC2/Fargate → CloudWatch/X-Ray |
| | IRSA ロール (newrelic-integration) | NR → CloudWatch Metrics polling |
| **VPC** | VPC + Subnet + SG | ネットワーク基盤 |
| | Interface Endpoints (ecr.api, ecr.dkr, logs, sts, monitoring, xray) | NAT 不使用 |
| **CloudWatch** | Application Signals | APM・サービスマップ・SLO |
| | Container Insights | K8s メトリクス |
| | Log Groups | アプリ・システムログ |
| | RUM App Monitor | フロントエンド監視 |
| | Synthetics Canary | 死活監視 |

---

## 4. 費用概算

| リソース | 時間単価 | 月額概算 |
|---------|---------|---------|
| EKS クラスター | $0.10/h | ~$75 |
| EC2 t3.medium × 1 | $0.052/h | ~$38 |
| Fargate (0.25vCPU × 0.5GB × 6 pods) | ~$0.02/h | ~$15 |
| Application Signals (トレース) | 従量 | ~$5–20 |
| Container Insights | 従量 | ~$5–10 |
| CloudWatch Logs | 従量 | ~$3–5 |
| RUM + Synthetics | 従量 | ~$3–5 |
| **合計（概算）** | | **~$150–170/月** |

> **注意**: New Relic は別途サブスクリプション費用が発生します。PoC 終了後は `make down` で即削除してください。

---

## 5. サンプルアプリの構成

```
frontend-ui          → backend-for-frontend (BFF)
                              ↓
                    ┌─────────┬──────────┬──────────────────────┐
                    ↓         ↓          ↓                      ↓
                order-api  inventory-api  payment-api  external-api-simulator
```

| サービス | 役割 | 外部呼び出し |
|---------|------|------------|
| frontend-ui | HTML UI / 静的アセット | BFF |
| backend-for-frontend | API 集約・シナリオ制御 | order, inventory, payment, external |
| order-api | 注文処理 | external |
| inventory-api | 在庫管理 | external |
| payment-api | 決済処理 | external |
| external-api-simulator | サードパーティ API 模擬 | — |

全サービス: Python FastAPI + uvicorn。アプリコードに計装なし。

---

## 6. トレース分析用シナリオ

BFF の `/scenario/{name}` エンドポイントで各シナリオをトリガー。

| シナリオ | 説明 | 期待される観測 |
|---------|------|--------------|
| `normal` | 全 API 正常呼び出し | 全スパン成功、通常レイテンシ |
| `slow_payment` | payment-api に意図的遅延（2–5s） | payment スパンのレイテンシ異常 |
| `inventory_error` | inventory-api が 500 エラー | エラースパン、サービスマップ上の赤色エッジ |
| `cascade_failure` | 複数サービスが連鎖エラー | ルートトレースからの連鎖確認 |
| `external_timeout` | external-api-simulator がタイムアウト | タイムアウトスパン検知 |

---

## 7. クイックスタート

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
# 以下を設定:
# NEW_RELIC_LICENSE_KEY=...   (NR ライセンスキー)
# NEW_RELIC_ACCOUNT_ID=...    (NR アカウント ID)
# AWS_REGION=ap-northeast-1
# CLUSTER_NAME=obs-poc
```

### 手順

```bash
# 1. EKS クラスター・AWS リソース作成（~20 分）
make up

# 2. K8s secrets 作成
make create-secrets

# 3. Docker イメージビルド & ECR push
make build-push

# ── CloudWatch path ──────────────────────────────────────────
# 4. CloudWatch スタックセットアップ（OTel Operator 有効化・アノテーション付与）
make install-cloudwatch-full

# 5. アプリデプロイ (EC2 → demo-ec2 namespace)
make deploy-ec2

# 6. アプリデプロイ (Fargate → demo-fargate namespace)
make deploy-fargate

# UI アクセス: CloudWatch path
make port-forward-ec2       # -> http://localhost:8080
make port-forward-fargate   # -> http://localhost:8081

# ── New Relic path ───────────────────────────────────────────
# 7. New Relic スタックセットアップ（nri-bundle + k8s-agents-operator）
make install-newrelic-full

# 8. アプリデプロイ (EC2 → demo-newrelic namespace)
make deploy-newrelic

# UI アクセス: New Relic path
make port-forward-newrelic  # -> http://localhost:8082

# ── 負荷生成・比較 ────────────────────────────────────────────
# 9. トレース生成
make load

# 10. ステータス確認
make status

# 11. 比較チェックリスト表示
make compare-check
```

### 計装の確認

```bash
# CloudWatch path: OTel SDK init container が注入されているか確認
kubectl get pod -n demo-ec2 -l app=frontend-ui \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'
# 期待値: opentelemetry-auto-instrumentation-python

# New Relic path: NR agent init container が注入されているか確認
kubectl get pod -n demo-newrelic -l app=frontend-ui \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'
# 期待値: newrelic-instrumentation-python (または類似名)
```

---

## 8. CloudWatch Application Signals で確認する観点

### コンソール URL

```
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:services
```

### 確認項目

| 観点 | 確認内容 | コンソール |
|------|---------|-----------|
| サービス一覧 | 6 サービスが自動検出されているか | Application Signals > Services |
| サービスマップ | 呼び出し依存グラフが自動生成されているか | Application Signals > Service Map |
| SLO | フロントエンドに SLO を設定できるか | Application Signals > SLOs |
| レイテンシ | p50/p90/p99 が表示されるか | Service > Metrics |
| エラー率 | 4xx/5xx エラー率 | Service > Metrics |
| 分散トレース | X-Ray トレースマップ・スパン詳細 | X-Ray > Traces |
| K8s メトリクス | Pod CPU・メモリ | Container Insights |
| ログ | JSON 構造化ログ | CloudWatch Logs |

### OTel 自動計装で取れるもの（コード変更なし）

- HTTP リクエスト/レスポンスのスパン（FastAPI, httpx）
- W3C TraceContext・Baggage の自動伝播
- HTTP ステータスコード・URL・メソッド
- Python ランタイムメトリクス（CPU, GC など）

---

## 9. Container Insights で確認する観点

```
CloudWatch > Container Insights > Performance monitoring
```

| 確認内容 | 見るべき指標 |
|---------|------------|
| Node レベル | CPU, Memory, Network I/O |
| Pod レベル | CPU throttling, Memory limits |
| Namespace レベル | demo-ec2 / demo-fargate の比較 |

---

## 10. CloudWatch Logs で確認する観点

```
CloudWatch > Log groups
  /aws/containerinsights/obs-poc/application  → アプリログ (JSON)
  /aws/containerinsights/obs-poc/performance  → パフォーマンスログ
```

- JSON 構造化ログ（service_name, level, message, timestamp）
- Logs Insights での集計クエリ例:

```
fields @timestamp, service_name, level, message
| filter level = "ERROR"
| sort @timestamp desc
| limit 50
```

---

## 11. New Relic APM で確認する観点

### コンソール URL

```
https://one.newrelic.com/apm
```

### 確認項目

| 観点 | 確認内容 | コンソール |
|------|---------|-----------|
| サービス一覧 | 6 サービスが自動検出されているか | APM > Summary |
| サービスマップ | 依存グラフ（エラー・レイテンシ付き） | APM > Service Map |
| Distributed Tracing | エンドツーエンドトレース | Distributed Tracing |
| Transaction | 遅いトランザクション・エラー | APM > Transactions |
| Errors Inbox | エラーのグルーピング・根本原因 | APM > Errors Inbox |
| SLI/SLO | サービスレベル目標設定 | APM > Service Levels |
| Apdex | ユーザー体感スコア | APM > Summary |
| Logs in Context | トレースに紐付いたログ | APM > Logs |

### NR Python agent で取れるもの（コード変更なし）

- FastAPI ルートごとのトランザクション追跡
- 外部 HTTP 呼び出し（httpx）のスパン
- 分散トレース（W3C TraceContext + NR 独自ヘッダー）
- Python ランタイムメトリクス
- エラーの stack trace 自動取得
- Logs in Context（ログと APM の自動紐付け）

---

## 12. New Relic Kubernetes で確認する観点

```
https://one.newrelic.com/kubernetes
```

| 確認内容 | 見るべき指標 |
|---------|------------|
| Cluster Explorer | Pod・Node・Namespace の可視化 |
| Node 利用率 | CPU・Memory |
| Pod ステータス | demo-newrelic namespace の Pod |
| K8s Events | エラーイベント検出 |

---

## 13. New Relic Logs で確認する観点

```
https://one.newrelic.com/logger
```

- `environment:demo-newrelic` でフィルタ
- APM との Logs in Context（トレース ID でログ検索）
- NRQL でのログ集計:

```sql
SELECT count(*) FROM Log
WHERE environment = 'demo-newrelic'
FACET service_name, level
SINCE 1 hour ago
```

---

## 14. 機能差比較表

| 機能 | CloudWatch Application Signals | New Relic APM |
|------|-------------------------------|---------------|
| **計装方式** | OTel Operator（CW addon）自動注入 | k8s-agents-operator（NR）自動注入 |
| **エージェント** | ADOT（OTel SDK + AWS Distro） | New Relic Python APM agent |
| **APM トレース** | X-Ray + App Signals | NR Distributed Tracing |
| **サービスマップ** | Application Signals Service Map | APM Service Map |
| **SLO 管理** | Application Signals SLOs | Service Levels |
| **K8s メトリクス** | Container Insights | NR Kubernetes |
| **ログ** | CloudWatch Logs（Fluent Bit） | NR Logs（Fluent Bit） |
| **Logs in Context** | なし（別途手動連携が必要） | あり（自動） |
| **エラー分析** | X-Ray エラー | Errors Inbox（AI グルーピング） |
| **アラート** | CloudWatch Alarms | NR Alerts + NRQL |
| **フロントエンド** | CloudWatch RUM | NR Browser |
| **合成監視** | CloudWatch Synthetics | NR Synthetics |
| **コスト構造** | AWS 従量課金 | NR サブスクリプション |
| **Fargate 対応** | フル対応（CW Agent サイドカー） | 部分対応（DaemonSet 非対応） |
| **AWS 統合** | ネイティブ（IAM/VPC/X-Ray） | API Polling / CloudWatch Metric Streams |

---

## 15. PoC 後の削除手順

```bash
make down
```

削除される内容:
1. CloudWatch Synthetics canary 停止
2. Helm リリース削除（nri-bundle）
3. K8s namespace 削除（demo-ec2, demo-fargate, demo-newrelic, newrelic）
4. Terraform destroy（EKS, ECR, VPC, IAM, CloudWatch RUM, Synthetics など）

残留リソース確認:
```bash
make destroy-check
```

---

## 16. 前提・注意事項

- **AWS アカウント**: `AmazonEKSClusterPolicy`, `AmazonEC2ContainerRegistryFullAccess`, `CloudWatchFullAccess`, `AmazonRDSFullAccess`（相当） が必要
- **New Relic**: Pro 以上のライセンスを推奨（k8s-agents-operator は Full Stack Observability 要）
- **VPC エンドポイント**: NAT Gateway の代わりに Interface Endpoints を使用（ecr.api, ecr.dkr, logs, sts, monitoring, xray）
- **シングル AZ 構成**: PoC コスト削減のため。本番は Multi-AZ 必須
- **OTel Operator と NR Operator の共存**: 同一クラスターに両 Operator を入れているが、namespace が異なるため干渉しない
- **Fargate + NR**: NR DaemonSet は Fargate 非対応。NR の K8s メトリクスは EC2 ノード上の DaemonSet が K8s API 経由で Fargate Pod データも収集する
