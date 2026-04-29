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
14. [APM 機能有意差の重点確認シナリオ](#14-apm-機能有意差の重点確認シナリオ)
15. [CloudWatch → New Relic ログ転送シナリオ（エージェントレス）](#15-cloudwatch--new-relic-ログ転送シナリオエージェントレス)
16. [機能差比較表](#16-機能差比較表)
17. [PoC 後の削除手順](#17-poc-後の削除手順)
18. [前提・注意事項](#18-前提注意事項)

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

frontend-ui / BFF の `/api/checkout/{scenario}` エンドポイントで各シナリオをトリガー。

| シナリオ | 説明 | 期待される観測 |
|---------|------|--------------|
| `normal` | 全 API 正常呼び出し | 全スパン成功、通常レイテンシ |
| `slow-payment` | payment-api に意図的遅延（2–5s） | payment スパンのレイテンシ異常 |
| `slow-inventory` | inventory-api に意図的遅延 | inventory スパンのレイテンシ異常 |
| `payment-error` | payment-api が 500 エラー | エラースパン、サービスマップ上の赤色エッジ |
| `external-slow` | external-api-simulator がタイムアウト | タイムアウトスパン検知 |
| `random` | 上記シナリオをランダム実行 | 混在トラフィックでのサービスマップ確認 |

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
```

**make up 前に設定する項目**:

```bash
# New Relic (Administration > API keys で取得)
NEW_RELIC_LICENSE_KEY=...     # INGEST - LICENSE タイプ
NEW_RELIC_API_KEY=NRAK-...    # USER タイプ（NRAK- で始まる）
NEW_RELIC_ACCOUNT_ID=...      # アカウント番号
NEW_RELIC_REGION=US           # one.newrelic.com → US / one.eu.newrelic.com → EU

# AWS
AWS_REGION=ap-northeast-1
AWS_ACCOUNT_ID=...            # 12 桁のアカウント番号
CLUSTER_NAME=obs-poc
```

**make up 後に terraform output で追記する項目**:

```bash
echo "CW_RUM_APP_MONITOR_ID=$(terraform -chdir=infra/terraform output -raw rum_app_monitor_id)" >> .env
echo "CW_RUM_IDENTITY_POOL_ID=$(terraform -chdir=infra/terraform output -raw cognito_identity_pool_id)" >> .env
```

**EC2_BASE / FARGATE_BASE / NEWRELIC_BASE / SYNTHETICS_CANARY_URL はアプリデプロイ後に設定する**（手順 11 参照）。

### 手順

```bash
# 1. EKS クラスター・AWS リソース作成（~20 分）
make up

# 2. terraform output を .env に追記
echo "CW_RUM_APP_MONITOR_ID=$(terraform -chdir=infra/terraform output -raw rum_app_monitor_id)" >> .env
echo "CW_RUM_IDENTITY_POOL_ID=$(terraform -chdir=infra/terraform output -raw cognito_identity_pool_id)" >> .env

# 3. K8s secrets 作成
make create-secrets

# 4. Docker イメージビルド & ECR push
make build-push

# ── CloudWatch path ──────────────────────────────────────────
# 5. CloudWatch スタックセットアップ（OTel Operator 有効化・アノテーション付与）
make install-cloudwatch-full

# 6. アプリデプロイ (EC2 → demo-ec2 namespace)
make deploy-ec2

# 7. アプリデプロイ (Fargate → demo-fargate namespace)
make deploy-fargate

# ── New Relic path ───────────────────────────────────────────
# 8. New Relic スタックセットアップ（nri-bundle + k8s-agents-operator）
make install-newrelic-full

# 9. アプリデプロイ (New Relic path → demo-newrelic namespace)
make deploy-newrelic

# ── URL 取得・ブラウザ確認 ────────────────────────────────────
# 10. ELB hostname の払い出しを待つ（1〜2 分）
kubectl get svc frontend-ui -n demo-ec2 -w      # EXTERNAL-IP が表示されたら Ctrl+C

# 11. 各 namespace の ELB URL を .env に追記
EC2_LB=$(kubectl get svc frontend-ui -n demo-ec2 \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
FARGATE_LB=$(kubectl get svc frontend-ui -n demo-fargate \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
NR_LB=$(kubectl get svc frontend-ui -n demo-newrelic \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "EC2_BASE=http://${EC2_LB}" >> .env
echo "FARGATE_BASE=http://${FARGATE_LB}" >> .env
echo "NEWRELIC_BASE=http://${NR_LB}" >> .env

# 12. Synthetics Canary の監視対象 URL を設定して terraform apply
source .env
terraform -chdir=infra/terraform apply -auto-approve \
  -var="new_relic_license_key=${NEW_RELIC_LICENSE_KEY}" \
  -var="new_relic_account_id=${NEW_RELIC_ACCOUNT_ID}" \
  -var="synthetics_canary_url=${EC2_BASE}"

# 13. ブラウザでアプリを開いて動作確認
#     各 URL でショッピングシナリオを手動操作すると即座にトレースが生成される
open ${EC2_BASE}      # CloudWatch path (EC2) — demo-ec2 namespace
open ${FARGATE_BASE}  # CloudWatch path (Fargate) — demo-fargate namespace
open ${NR_LB}         # New Relic path — demo-newrelic namespace

# ── トラフィック生成 ──────────────────────────────────────────
# 14. 自動負荷生成（EC2 / Fargate / New Relic 全 path に全シナリオを送信）
#     EC2_BASE・FARGATE_BASE は .env から自動読み込み
make load
# New Relic path にも同じシナリオを送信
source .env
for scenario in checkout/normal checkout/slow-payment checkout/slow-inventory \
                checkout/payment-error checkout/external-slow checkout/random; do
  curl -s "${NEWRELIC_BASE}/api/${scenario}" > /dev/null
  sleep 1
done

# ── 結果確認 ─────────────────────────────────────────────────
# 15. ステータス確認
make status

# 16. 比較チェックリスト表示
make compare-check
```

> **観測データが出るまでの目安**: `make load` 実行後 2〜3 分で CloudWatch Application Signals・New Relic APM 双方にトレース・メトリクスが表示される。
> 詳細な確認手順はセクション 8〜14 を参照。

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

### APM 特化機能（CW との有意差が出やすい箇所）

**Transaction Traces**
```
APM > [service] > Transaction Traces
```
- 設定したしきい値（デフォルト Apdex T × 4）を超えた実行を自動キャプチャ
- Breakdown Table: FastAPI ルート・httpx 呼び出しごとの時間内訳
- `checkout/slow-payment` 実行後、payment-api スパンがどの関数で遅いかを確認

**Errors Inbox**
```
APM > [service] > Errors Inbox
```
- stack trace fingerprint でエラーを自動グルーピング（同種エラーをまとめて表示）
- occurrence count, First seen / Last seen が自動記録
- Resolved / Ignored / Assigned でステータス管理（チームでのトリアージが可能）
- `checkout/payment-error` を繰り返し実行してグルーピングを確認

**External Services**
```
APM > [service] > External services
```
- `external-api-simulator` への呼び出しが呼び出し元サービスごとに内訳表示
- レスポンスタイムの分布・スループット・エラー率を外部サービス単位で確認

**Apdex**
- ユーザー体感スコア（0–1）がサービスサマリに常時表示
- `slow-payment` 実行で Apdex が下がるタイミングを確認（CW には相当機能なし）

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

## 14. APM 機能有意差の重点確認シナリオ

New Relic は APM ツールに特化しているため、以下のシナリオで CloudWatch との**機能的有意差**が現れやすい。
同一トラフィックを発生させ、両ツールが何をどこまで見せるかを実機で比較する。

### シナリオ A: エラー分析の深度

**操作**（`source .env` で EC2_BASE を読み込んでから実行）:
```bash
source .env
for i in $(seq 1 25); do curl -s ${EC2_BASE}/api/checkout/payment-error > /dev/null; done
```

| 観点 | CloudWatch (X-Ray) | New Relic (Errors Inbox) |
|------|-------------------|--------------------------|
| エラーのグルーピング | なし。個別トレースをフィルタして目視 | stack trace fingerprint で自動グルーピング |
| stack trace の取得 | スパン属性で部分的 | Python 全 stack trace を自動キャプチャ |
| 発生回数・初回/最終発生 | 手動で時系列検索 | occurrence count, first/last seen が自動記録 |
| 担当者アサイン・ステータス管理 | なし | Errors Inbox で Resolved / Ignored / Assigned |

- **CW**: X-Ray > Traces > `Filter: Error = true` で個別トレースを目視
- **NR**: APM > [payment-api] > Errors Inbox でグルーピング済みエラーを確認

---

### シナリオ B: 遅いトランザクションの自動検出

**操作**:
```bash
source .env
for i in $(seq 1 30); do curl -s ${EC2_BASE}/api/checkout/slow-payment > /dev/null; done
```

| 観点 | CloudWatch (X-Ray) | New Relic (Transaction Traces) |
|------|-------------------|---------------------------------|
| 遅い実行の自動キャプチャ | なし。手動で duration フィルタして探す | しきい値超えの実行を Transaction Traces に自動保存 |
| 内訳の粒度 | HTTP スパン単位 | Breakdown Table で FastAPI ルート・httpx 呼び出しごとの時間 |
| どこで時間を使ったか | スパン間の空白時間は不明 | 各関数の占有時間をパーセンテージで表示 |
| しきい値アラート | メトリクス名を特定して CloudWatch Alarm | `percentile(duration, 99) > 2000` をそのままアラート条件に |

- **CW**: X-Ray > Traces > Sort by duration 降順 → 手動で遅いトレースを探す
- **NR**: APM > [backend-for-frontend] > Transaction Traces > Slowest traces

---

### シナリオ C: Logs in Context の操作性

**操作**: 任意のシナリオで負荷をかけ、トレース詳細画面からログへの到達手順を両ツールで比較する

| 観点 | CloudWatch | New Relic |
|------|-----------|-----------|
| トレース → ログへの移動 | trace_id を手動コピー → Logs Insights で検索クエリを書く | トレース詳細の "Logs" タブを1クリック |
| スパン上にログをマッピング | なし | スパンの時刻範囲内のログをタイムライン上に重ねて表示 |
| エラーログの APM サマリへの浮上 | なし | エラー件数が APM サービスサマリに自動カウント |
| ログ → トレースへの逆引き | trace_id でログを検索し X-Ray で再検索（2操作） | ログエントリから "View span in APM" で直接ジャンプ |

確認手順（NR 側）:
1. APM > [payment-api] > Distributed Tracing でエラートレースを選択
2. スパンを選択 → "Logs" タブ → そのスパンに紐付いたログが表示されるか確認
3. NR Logs でログエントリを選択 → "View span in APM" で逆引きナビゲーション

---

### シナリオ D: サービスマップの情報密度

**操作**: `make load` で全シナリオ混在のトラフィックを発生させた状態でサービスマップを比較

| 観点 | CloudWatch App Signals | New Relic APM |
|------|------------------------|---------------|
| ノードの情報量 | レイテンシ・エラー率 | Apdex・スループット・エラー率・レイテンシが1ノードに集約 |
| ユーザー体感スコア | なし | Apdex（0–1 のスコアで劣化が直感的に見える） |
| 外部サービスの可視性 | external-api-simulator が依存として表示 | External Services ページ: 呼び出し元ごとの response time breakdown |

---

### シナリオ E: アラート定義の柔軟性

同じアラート条件を両ツールで設定し、定義のしやすさを比較する

| 条件例 | CloudWatch | New Relic NRQL アラート |
|--------|-----------|------------------------|
| payment-api の p99 レイテンシ > 2 秒 | App Signals メトリクスを特定してアラーム設定 | `SELECT percentile(duration,99) FROM Transaction WHERE appName='payment-api'` |
| エラー率 5% 超え | X-Ray フィルタグループ + アラーム | `SELECT percentage(count(*), WHERE error IS true) FROM Transaction` |
| 特定エンドポイントのみ | ディメンション指定が複雑 | `WHERE request.uri LIKE '/pay/%'` を WHERE 句に追加するだけ |

---

### シナリオ F: 自動異常検知の感度

**操作**: `make load`（正常トラフィック）→ `slow-payment` を集中実行 → 自動で異常として検出されるかを確認

| 観点 | CloudWatch | New Relic |
|------|-----------|-----------|
| 事前設定 | Anomaly Detection を各アラームに個別設定が必要 | Applied Intelligence (Lookout) が設定不要で全エンティティを横断スキャン |
| 検出スコープ | 設定済みメトリクスのみ | 全サービスの全シグナル（メトリクス・トレース・ログ）を横断 |
| 通知の集約 | SNS / CloudWatch Actions をサービスごとに設定 | Workflows + 通知チャネル（Slack 等）で一元管理 |

---

## 15. CloudWatch → New Relic ログ転送シナリオ（エージェントレス）

> **目的**: New Relic エージェントによる直接収集を停止し、CloudWatch が収集したログ・メトリクスの重要メッセージだけを New Relic に転送した場合、障害検知・エスカレーション対応がどこまで改善するかを確認する。

### アーキテクチャ

```
EKS Pod stdout/stderr
  └─ Fluent Bit (CW addon) ──→ CloudWatch Logs
                                  /aws/containerinsights/obs-poc/application
                                         │
                                  Subscription Filter
                                  filter_pattern: ?ERROR ?CRITICAL ?FATAL ?Exception ?Traceback
                                         │  ← ここでフィルタ。マッチした行だけ流れる
                                  Kinesis Firehose (HTTP endpoint destination)
                                         │
                                  New Relic Log API (log-api.newrelic.com/log/v1)
                                         │
                            New Relic Logs / Alerts / Applied Intelligence
```

- **Lambda ゼロ**: フィルタリングは CloudWatch Logs のサブスクリプションフィルターパターンで完結
- **転送対象**: ERROR/CRITICAL/FATAL/Exception/Traceback を含む行のみ（ノイズ削減）
- **New Relic エージェント**: 無効（namespace `demo-newrelic` には何もデプロイしない）
- **New Relic APM トレース・メトリクス**: 取得しない。ログのみを New Relic に渡す

### 有効化手順

```bash
# 1. .env に NR ライセンスキーが設定されていることを確認
source .env

# 2. Terraform 変数を有効化して apply
cd infra/terraform
terraform apply \
  -var="new_relic_license_key=${NEW_RELIC_LICENSE_KEY}" \
  -var="new_relic_account_id=${NEW_RELIC_ACCOUNT_ID}" \
  -var="cw_to_newrelic_enabled=true"
```

`apply` 完了後、EKS アプリからエラーが発生すると自動的に New Relic Logs に転送される。

### 確認シナリオ G: エラーログの New Relic 到達確認

**操作**:
```bash
source .env
# EC2 デプロイ済みの場合はそのエンドポイントでも可
for i in $(seq 1 10); do curl -s ${EC2_BASE}/api/checkout/payment-error > /dev/null; done
```

**New Relic 側の確認**:
1. New Relic One → **Logs** → すべてのログを表示
2. 検索クエリ:
   ```sql
   SELECT * FROM Log
   WHERE logGroup = '/aws/containerinsights/obs-poc/application'
   SINCE 10 minutes ago
   ```
3. `logStream`・`logGroup` 属性が入っていることを確認（Firehose が CW Logs の生 JSON をそのまま転送するため自動付与）

| 観点 | CloudWatch のみ | CW → Firehose → NR 転送あり |
|------|----------------|------------------------------|
| エラーログの到達先 | CloudWatch Logs Insights のみ | New Relic Logs にも自動転送 |
| 検索インタフェース | CWL Insights (SQL ライク) | NRQL / New Relic Logs UI |
| ノイズ量 | 全ログが流れる | ERROR 系のみフィルタ済み（サブスクリプションフィルターで制御） |
| カスタムコード | 不要 | 不要（Lambda ゼロ） |
| 転送コスト | - | Firehose $0.029/GB + NR インジェスト |

---

### 確認シナリオ H: NRQL アラートによる障害自動検知

CloudWatch Alarm との比較：同じ「エラーが N 件/分を超えたら通知」をどちらが簡単に設定できるか。

**New Relic アラート設定手順**:
1. New Relic One → **Alerts** → Create alert condition
2. Signal type: **NRQL**
3. 条件式:
   ```sql
   SELECT count(*) FROM Log
   WHERE source = 'cloudwatch-forwarded'
   AND level = 'error'
   FACET log.stream
   ```
4. しきい値: `count > 5 for at least 1 minute` で Critical

**CloudWatch Alarm 設定手順（比較）**:
1. CloudWatch → Alarms → Create alarm
2. メトリクス: `AWS/Logs` → `IncomingLogEvents`（エラー件数の直接メトリクスは存在しない）
3. エラーカウントのメトリクスフィルタを先に作成してからアラームを設定（2ステップ）

| 観点 | CloudWatch Alarm | New Relic NRQL Alert |
|------|-----------------|----------------------|
| 条件定義の手順 | メトリクスフィルタ作成 → Alarm 作成（2ステップ） | NRQL 1 行でそのままアラート化 |
| フィルタの柔軟性 | ログメトリクスフィルタのパターン構文に制約あり | ログの任意フィールドを WHERE / FACET で絞り込み可 |
| 複数サービスの集約 | サービスごとにアラームが必要 | `FACET log.stream` で一条件に集約 |
| 通知先 | SNS → メール / Lambda / Slack（別途設定） | Workflows で Slack / PagerDuty / メールを統合管理 |

---

### 確認シナリオ I: Applied Intelligence による異常集約とエスカレーション

**操作**: `payment-error` シナリオを断続的に流し、New Relic が複数のアラートをどう集約するかを確認

1. New Relic One → **Alerts** → Issues & Activity
2. 同じエラーストリームから発火した複数のアラートが **1 Issue** に集約されているか確認
3. Issue 詳細 → "Correlated alerts" でログ件数の時系列グラフを確認
4. Acknowledge / Resolve ボタンでエスカレーション状態を管理

| 観点 | CloudWatch | New Relic Applied Intelligence |
|------|-----------|-------------------------------|
| 複数アラートの集約 | なし（アラームは個別に発火） | Issues に自動集約・重複排除 |
| 根本原因の提示 | なし | 相関するエンティティ・ログを Issue に自動リンク |
| エスカレーション状態管理 | なし | Acknowledged / Resolved / In progress |
| オンコール通知 | SNS + 手動ルーティング | Workflows → PagerDuty / Slack / Opsgenie 統合 |

### エージェントレス構成の制約まとめ

| 取得できるデータ | 取得できないデータ |
|----------------|-----------------|
| ERROR 以上のログ（NR Logs） | APM トレース・スパン |
| ログに基づく NRQL アラート | サービスマップ・依存関係 |
| Applied Intelligence によるアラート集約 | Transaction Traces・Breakdown |
| ログからの手動トレース検索 | Errors Inbox のスタックトレース自動グルーピング |

> **結論**: エージェントレスでも NR の「アラート定義の簡潔さ・Applied Intelligence の集約・エスカレーション管理」は有効。ただし APM レベルの根本原因分析（トレース・スタックトレース）は得られないため、エージェントフル構成との組み合わせが最大効果。

---

## 16. 機能差比較表

| 機能 | CloudWatch Application Signals | New Relic APM |
|------|-------------------------------|---------------|
| **計装方式** | OTel Operator（CW addon）自動注入 | k8s-agents-operator（NR）自動注入 |
| **エージェント** | ADOT（OTel SDK + AWS Distro） | New Relic Python APM agent |
| **APM トレース** | X-Ray + App Signals | NR Distributed Tracing |
| **サービスマップ** | Application Signals Service Map | APM Service Map |
| **SLO 管理** | Application Signals SLOs | Service Levels |
| **K8s メトリクス** | Container Insights | NR Kubernetes |
| **ログ** | CloudWatch Logs（Fluent Bit） | NR Logs（Fluent Bit） |
| **Logs in Context** | なし（trace_id で手動検索が必要） | あり（トレース詳細から1クリック・逆引きも可） |
| **エラーグルーピング** | なし（個別トレースを目視） | Errors Inbox（stack trace fingerprint で自動グルーピング・ステータス管理） |
| **遅いトランザクション自動検出** | なし（手動フィルタ） | Transaction Traces（しきい値超えを自動キャプチャ・Breakdown Table） |
| **ユーザー体感スコア** | なし | Apdex（0–1 スコアがサービスサマリに常時表示） |
| **アラート条件の柔軟性** | メトリクスアラーム（ディメンション固定） | NRQL で任意のシグナル・フィルタをそのままアラート化 |
| **自動異常検知** | Anomaly Detection（アラームごとに設定必要） | Applied Intelligence / Lookout（設定不要で全エンティティ横断スキャン） |
| **外部サービス分析** | スパンで確認 | External Services ページ（呼び出し元ごとの breakdown） |
| **アラート** | CloudWatch Alarms | NR Alerts + NRQL |
| **フロントエンド** | CloudWatch RUM | NR Browser |
| **合成監視** | CloudWatch Synthetics | NR Synthetics |
| **コスト構造** | AWS 従量課金 | NR サブスクリプション |
| **Fargate 対応** | フル対応（CW Agent サイドカー） | 部分対応（DaemonSet 非対応） |
| **AWS 統合** | ネイティブ（IAM/VPC/X-Ray） | API Polling / CloudWatch Metric Streams |

---

## 17. PoC 後の削除手順

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

## 18. 前提・注意事項

- **AWS アカウント**: `AdministratorAccess` 相当が必要（EKS, ECR, IAM, VPC, CloudWatch, Cognito, S3, Kinesis Firehose, Synthetics を作成するため）
- **New Relic**: Pro 以上のライセンスを推奨（k8s-agents-operator は Full Stack Observability 要）
- **VPC エンドポイント**: NAT Gateway の代わりに Interface Endpoints を使用（ecr.api, ecr.dkr, logs, sts, monitoring, xray）
- **シングル AZ 構成**: PoC コスト削減のため。本番は Multi-AZ 必須
- **OTel Operator と NR Operator の共存**: 同一クラスターに両 Operator を入れているが、namespace が異なるため干渉しない
- **Fargate + NR**: NR DaemonSet は Fargate 非対応。NR の K8s メトリクスは EC2 ノード上の DaemonSet が K8s API 経由で Fargate Pod データも収集する
