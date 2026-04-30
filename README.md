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
8. [障害検証メニュー](#8-障害検証メニュー)
9. [負荷テストガイド（scripts/load.sh）](#9-負荷テストガイドscriptsloadsh)
10. [外形監視（CloudWatch Synthetics）](#10-外形監視cloudwatch-synthetics)
11. [CloudWatch Application Signals で確認する観点](#11-cloudwatch-application-signals-で確認する観点)
12. [CloudWatch Logs で確認する観点](#12-cloudwatch-logs-で確認する観点)
13. [Container Insights で確認する観点](#13-container-insights-で確認する観点)
14. [New Relic フェーズ（フェーズ 2・準備中）](#14-new-relic-フェーズフェーズ-2準備中)
15. [機能差比較表](#15-機能差比較表)
16. [PoC 後の削除手順](#16-poc-後の削除手順)
17. [前提・注意事項](#17-前提注意事項)

> **詳細手順**: `docs/observability-lab.md` — Application Signals / Synthetics / RUM の検証手順  
> **運用 Runbook**: `docs/runbook.md` — Tier1/Tier2/Tier3 切り分け手順
11. [New Relic フェーズ（フェーズ 2・準備中）](#11-new-relic-フェーズフェーズ-2準備中)
12. [機能差比較表](#12-機能差比較表)
13. [PoC 後の削除手順](#13-poc-後の削除手順)
14. [前提・注意事項](#14-前提注意事項)

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
│  │  全サービス → OTLP gRPC :4315 → CloudWatch Agent (ADOT)          │   │
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

X-Ray / Application Signals の分散トレースで「どのサービスのどの操作で遅延が発生しているか」を
学ぶには、最低 3 段のスパンが必要です。2 ホップではトレースマップが単純すぎてハンズオンになりません。

| ホップ | サービス | 操作 |
|--------|---------|------|
| 1st | netwatch-ui | ユーザーのブラウザリクエストを受けて device-api を呼ぶ |
| 2nd | device-api | RDS から機器情報を取得し metrics-collector を呼ぶ |
| 3rd | metrics-collector | 機器 ID とステータスに基づくメトリクスを返す |

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
netwatch-ui:8080  ──GET /devices{?filters}──────→  device-api:8000
netwatch-ui:8080  ──GET /devices/{id}────────────→  device-api:8000
                                                         └──GET /metrics/{id}──→  metrics-collector:8000
netwatch-ui:8080  ──GET /alerts{?filters}────────→  alert-api:8000
netwatch-ui:8080  ──POST /api/chaos/*────────────→  device-api または alert-api
```

OTel auto-instrumentation が httpx の全呼び出しに W3C TraceContext ヘッダーを自動付与するため、
`GET /devices/{id}` のトレースは自動的に 3 段のスパンとして記録されます。

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
| **ECR** | netwatch-ui, device-api, alert-api, metrics-collector（計4リポジトリ） | アプリイメージ |
| **RDS** | PostgreSQL 16 db.t3.micro（シングルAZ, プライベートサブネット） | 機器マスターデータ |
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
| RDS PostgreSQL db.t3.micro | $0.022/h | ~$16 |
| Application Signals (トレース) | 従量 | ~$5–15 |
| Container Insights | 従量 | ~$5–10 |
| CloudWatch Logs | 従量 | ~$3–5 |
| RUM + Synthetics（オプション） | 従量 | ~$3–5 |
| **合計（概算）** | | **~$140–160/月** |

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
# OTel SDK init container が注入されているか確認（4サービス全て）
for svc in netwatch-ui device-api alert-api metrics-collector; do
  echo -n "${svc}: "
  kubectl get pod -n demo-ec2 -l app=${svc} \
    -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null
  echo ""
done
# 期待値: opentelemetry-auto-instrumentation-python

# 3ホップトレースの確認（機器詳細ページを1回叩く）
source .env
curl -s "${EC2_BASE}/devices/TKY-CORE-001" > /dev/null

# CloudWatch Application Signals に 3 サービスが出るか確認
for svc in netwatch-ui device-api metrics-collector; do
  echo -n "${svc}: "
  aws cloudwatch list-metrics \
    --namespace ApplicationSignals \
    --dimensions Name=Service,Value=${svc} \
    --region ap-northeast-1 \
    --query 'length(Metrics)' \
    --output text
done

# RDS への接続確認（device-apiのログでエラーがないか）
kubectl logs -n demo-ec2 -l app=device-api --tail=20 | grep -E "startup|db_initialized|ERROR"
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

## 8. 障害検証メニュー

### メニュー 1: 正常時のベースライン確認

**目的**: 正常時の数値を把握し、異常時との比較基準を作る

```bash
source .env
./scripts/load.sh mixed-user-flow   # / → /devices → /devices/TKY-CORE-001 → /alerts → /chaos
```

確認画面:
| 確認先 | 確認内容 |
|--------|---------|
| Application Signals > Services | 4サービスが表示されるか |
| Application Signals > Service Map | 3段の依存グラフが見えるか |
| X-Ray > Traces | 3ホップトレースが1本のトレースに結合されているか |
| Container Insights > demo-ec2 | Pod CPU/Memory の正常値を把握 |
| CloudWatch Logs Insights | JSON構造化ログが流れているか |

---

### メニュー 2: Slow Query によるAPI遅延の切り分け

**目的**: DB起因の遅延をApplication SignalsとTraceで特定する練習

```bash
source .env
# Step 1: カオス画面（/chaos）またはcurlでSlow Query ON
curl -X POST "${EC2_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"

# Step 2: 負荷をかける
./scripts/load.sh slow-query-devices

# Step 3: 観測 → 復旧
curl -X POST "${EC2_BASE}/api/chaos/reset"
```

確認画面:
| 確認先 | 期待する見え方 |
|--------|--------------|
| App Signals > device-api > Operations | `GET /devices` の P99 が 5s 超に急増 |
| App Signals > Service Map | device-api ノードが黄/赤に変化 |
| X-Ray > Traces > device-api span | span duration が 5s 前後になっている |
| CloudWatch Logs Insights | `filter message like "slow_query"` でログを確認 |
| Container Insights > device-api Pod | CPUに大きな変化はない（sleepなので） |

---

### メニュー 3: Error Inject によるエラー率上昇の特定

**目的**: エラー率が上昇したとき、どのサービス・Operationが悪いかを特定する練習

```bash
source .env
# Step 1: Error Inject ON（50%）
curl -X POST "${EC2_BASE}/api/chaos/error-inject?rate=50"

# Step 2: 負荷をかける
./scripts/load.sh error-inject-devices

# Step 3: 復旧
curl -X POST "${EC2_BASE}/api/chaos/reset"
```

確認画面:
| 確認先 | 期待する見え方 |
|--------|--------------|
| App Signals > device-api | Error rate が ~50% に上昇 |
| App Signals > Service Map | netwatch-ui → device-api のエッジが赤くなる |
| App Signals > netwatch-ui | Error rate も上昇する（下流エラーが伝播） |
| X-Ray > Traces > Filter: Fault=true | エラートレースの span 詳細を確認 |
| Logs Insights | `filter message like "error_injected"` |

---

### メニュー 4: Alert Storm によるアラート大量発生

**目的**: ログボリューム急増とアラート疲労の見え方を確認する

```bash
source .env
# Step 1: Alert Storm 実行
curl -X POST "${EC2_BASE}/api/chaos/alert-storm"

# Step 2: アラート一覧を確認
./scripts/load.sh alert-storm-alerts

# Step 3: 復旧
curl -X POST "${EC2_BASE}/api/chaos/reset"
```

確認画面:
| 確認先 | 期待する見え方 |
|--------|--------------|
| App Signals > alert-api | Request count・Throughput が急増 |
| CloudWatch Logs | /aws/containerinsights/obs-poc/application のインジェストバイト急増 |
| Logs Insights | `filter service_name = "alert-api" \| stats count(*) by bin(1m)` |
| Container Insights > alert-api Pod | CPU が微増 |

---

### メニュー 5: 3ホップトレースの確認

**目的**: 分散トレースの親子関係（netwatch-ui → device-api → metrics-collector）を理解する

```bash
source .env
# 機器詳細を複数回叩いて十分なトレースを生成
./scripts/load.sh normal-device-detail
```

X-Ray で確認:
1. X-Ray > Traces を開く
2. Filter: `service("device-api") AND url CONTAINS "/devices/"` で絞る
3. トレースを1件開く → Trace Map で3段のスパンを確認
4. span 別の duration を確認：どのホップで時間がかかっているか

---

### メニュー 6: Synthetics Canary + 外形監視

**目的**: 外部からの死活監視とApplication Signalsの内部監視を組み合わせる

```bash
# Canary を手動開始
aws synthetics start-canary --name obs-poc-health-check --region ap-northeast-1

# Slow Query を ON にして Canary の duration 悪化を確認
curl -X POST "${EC2_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
# → Canary: duration 悪化（HTTP 200 は返るが応答遅延）

# Error Inject を ON にして Canary の FAIL を確認
curl -X POST "${EC2_BASE}/api/chaos/error-inject?rate=80"
# → Canary: /devices に HTTP 500 が増えて FAIL になる可能性あり

# コスト節約のため使用後は停止
aws synthetics stop-canary --name obs-poc-health-check --region ap-northeast-1
```

---

### メニュー 7: SLO / Alarm 設計イメージの確認

**目的**: Application Signals SLO と CloudWatch Alarm の設定感を掴む

Application Signals SLO 設定例:
```
Service: netwatch-ui
SLO Type: Latency
Threshold: P99 < 3000ms
Period: 1日
Target: 99.0%
```

CloudWatch Alarm 設定例（コンソール: CloudWatch > Alarms > Create alarm）:
```
Metric: ApplicationSignals > Service=device-api, Operation=GET /devices
Metric name: Latency
Statistic: p99
Period: 5 minutes
Threshold: > 2000 (ms)
Action: SNS通知
```

---

## 9. 負荷テストガイド（scripts/load.sh）

### 基本的な使い方

```bash
source .env   # EC2_BASE を読み込む

# ── 正常時 ──────────────────────────────────────────────────────
make load                              # 全シナリオ（デフォルト）
./scripts/load.sh normal-dashboard    # ダッシュボードのみ
./scripts/load.sh normal-devices      # 機器一覧（フィルタ各種）
./scripts/load.sh normal-device-detail # 機器詳細 7件（3ホップトレース生成）
./scripts/load.sh normal-alerts       # アラート一覧
./scripts/load.sh mixed-user-flow     # 回遊シナリオ

# ── カオス検証 ───────────────────────────────────────────────────
# 事前に /chaos 画面または curl でカオスを ON にしてから実行
./scripts/load.sh slow-query-devices     # Slow Query 検証用
./scripts/load.sh error-inject-devices   # Error Inject 検証用
./scripts/load.sh alert-storm-alerts     # Alert Storm 検証用
```

### 環境変数でラウンド数・遅延を調整

```bash
ROUNDS=10 DELAY=0.5 ./scripts/load.sh normal-device-detail
```

### 負荷実行後に見るべき画面

| シナリオ | 主な確認先 |
|---------|-----------|
| normal-device-detail | X-Ray > Traces（3ホップ確認）、App Signals > Service Map |
| slow-query-devices | App Signals > device-api > Latency P99 |
| error-inject-devices | App Signals > device-api > Error rate |
| alert-storm-alerts | CloudWatch Logs > ログボリューム、App Signals > alert-api Throughput |
| mixed-user-flow | App Signals > Service Map 全体 |

---

## 10. 外形監視（CloudWatch Synthetics）

### Canary 仕様

1本の Canary が4エンドポイントを順番にチェックします:

| エンドポイント | チェック内容 |
|--------------|------------|
| `GET /` | HTTP 200 + "NetWatch" が含まれること |
| `GET /devices` | HTTP 200 + "devices" が含まれること |
| `GET /devices/TKY-CORE-001` | HTTP 200 + "TKY-CORE-001" が含まれること |
| `GET /alerts` | HTTP 200 + "alerts" が含まれること |

実行頻度: 5分ごと（`rate(5 minutes)`）  
S3 アーティファクト: `s3://{cluster_name}-synthetics-{account_id}/canary-results/`

### Canary 管理コマンド

```bash
# Canary 開始（PoC時のみ。使わないときは停止してコスト節約）
aws synthetics start-canary --name obs-poc-health-check --region ap-northeast-1

# Canary 停止
aws synthetics stop-canary --name obs-poc-health-check --region ap-northeast-1

# 最新実行結果を確認
aws synthetics get-canary-runs --name obs-poc-health-check \
  --region ap-northeast-1 --query 'CanaryRuns[0]'
```

### Canary Alarm の作成

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "netwatch-canary-failed" \
  --metric-name "SuccessPercent" \
  --namespace "CloudWatchSynthetics" \
  --dimensions Name=CanaryName,Value=obs-poc-health-check \
  --statistic Average \
  --period 300 \
  --threshold 100 \
  --comparison-operator LessThanThreshold \
  --evaluation-periods 1 \
  --alarm-description "NetWatch Canary FAIL" \
  --region ap-northeast-1
```

### カオス時の Canary の見え方

| カオス状態 | Canary への影響 |
|-----------|---------------|
| Slow Query ON (5秒) | duration が増加するが HTTP 200 なので成功。ダッシュボードで duration 悪化を確認 |
| Error Inject ON (50%) | `/devices` で HTTP 500 が出ると FAIL → Alarm 発火 |
| Error Inject ON (20%) | 確率的に FAIL / PASS が混在。SuccessPercent が 100% 未満になる |
| Alert Storm | Canary には影響なし（/alerts はHTTP 200 のまま） |

### Synthetics vs Application Signals の使い分け

| | Synthetics (外形監視) | Application Signals (内部監視) |
|--|----------------------|-------------------------------|
| 視点 | 外部ユーザー視点の死活 | サービス内部のどこが遅い/エラー |
| 最初に見る | 問題があるかどうかを確認 | 問題の原因を特定 |
| アラート | Canary FAIL → 即通知 | メトリクス超過 → 通知 |
| トレース | なし | X-Ray で詳細トレース |

---

## 11. CloudWatch Application Signals で確認する観点

### コンソール URL

```
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:services
```

### 確認項目

| 観点 | 確認内容 | コンソールパス |
|------|---------|---------------|
| **サービス一覧** | netwatch-ui / device-api / alert-api / metrics-collector が自動検出されているか | Application Signals > Services |
| **サービスマップ** | `netwatch-ui → device-api → metrics-collector` の 3 段グラフが自動生成されているか | Application Signals > Service Map |
| **SLO** | netwatch-ui や device-api に SLO（可用性 99.9%, レイテンシ P99 < 1s）を設定する | Application Signals > SLOs |
| **レイテンシ** | P50 / P90 / P99 の時系列グラフ | Service > Operations |
| **エラー率** | 4xx / 5xx の時系列グラフ | Service > Operations |
| **分散トレース** | X-Ray で 3 ホップのトレースマップを確認 | X-Ray > Traces |

### Application Signals で自動的に取れるもの（コード変更なし）

- FastAPI の全ルートの HTTP サーバースパン（メソッド・URL・ステータスコード付き）
- httpx による下流 API 呼び出しの HTTP クライアントスパン
- W3C TraceContext による自動トレース伝播（3 サービスを貫く1本のトレース）
- Python ランタイムメトリクス

### 3ホップトレースの読み方

```
X-Ray > Traces > Filter: service("netwatch-ui") AND url CONTAINS "/devices/"
  └─ トレースを選択 → Trace Map
       ├─ [span1] netwatch-ui: GET /devices/{id}  ← ここが遅ければ UI 側の問題
       ├─ [span2] device-api:  GET /devices/{id}  ← ここが遅ければ DB クエリ問題
       └─ [span3] metrics-collector: GET /metrics/{id}  ← ここが遅ければメトリクス収集問題
```

スロークエリカオスを ON にすると span2 の duration が 3s 伸び、span3 への影響がないことも X-Ray で確認できます。

---

## 12. CloudWatch Logs で確認する観点

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

## 13. Container Insights で確認する観点

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

## 14. New Relic フェーズ（フェーズ 2・準備中）

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

## 15. 機能差比較表

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

## 16. PoC 後の削除手順

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

## 17. 前提・注意事項

- **AWS アカウント**: `AdministratorAccess` 相当が必要（EKS, ECR, IAM, VPC, CloudWatch を作成するため）
- **VPC エンドポイント**: NAT Gateway の代わりに Interface Endpoints を使用（ecr.api, ecr.dkr, logs, sts, monitoring, xray）
- **シングル AZ 構成**: PoC コスト削減のため。本番は Multi-AZ 必須
- **ECR リポジトリ**: `force_delete=true` のため、イメージが残っていても `make down` で削除される
- **X-Ray サンプリング**: Central Sampling のため低サンプリングレートになる場合がある。Application Signals メトリクスは全リクエストから集計されるため、トレースが少なくてもメトリクスは正確
- **New Relic フェーズ**: `.env` に `NEW_RELIC_LICENSE_KEY` / `NEW_RELIC_ACCOUNT_ID` が必要
