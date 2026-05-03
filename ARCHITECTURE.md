# NetWatch — 現在のサービス構成

## アプリケーション概要

大手キャリアがネットワーク機器を監視する想定のシステム「NetWatch」。
CloudWatch Application Signals / New Relic APM のハンズオン学習用 PoC として構築。

---

## サービス構成（4サービス）

```
[ブラウザ]
    ↓ HTTP
netwatch-ui  (FastAPI + Jinja2 + Tailwind CSS, port 8080)
    ├─→ device-api        (FastAPI + PostgreSQL, port 8000)
    │       └─→ metrics-collector  (FastAPI, port 8000)
    └─→ alert-api         (FastAPI, port 8000)
```

| サービス | 言語/FW | DB | 外部公開 |
|---------|---------|-----|---------|
| netwatch-ui | Python / FastAPI + Jinja2 | なし | LoadBalancer (ELB) |
| device-api | Python / FastAPI | RDS PostgreSQL db.t3.micro | ClusterIP (内部のみ) |
| metrics-collector | Python / FastAPI | なし | ClusterIP (内部のみ) |
| alert-api | Python / FastAPI | in-memory (Python リスト) | ClusterIP (内部のみ) |

---

## データ

### devices テーブル（RDS PostgreSQL）

30台のネットワーク機器。起動時に device-api がシードデータを投入する。

| フィールド | 型 | 説明 |
|-----------|-----|------|
| device_id | TEXT PK | 例: TKY-CORE-001 |
| name | TEXT | 例: 東京コアルーター1 |
| type | TEXT | core_router / edge_router / l3_switch / l2_switch / firewall / load_balancer / access_point |
| area | TEXT | tokyo / osaka / nagoya / fukuoka / sapporo |
| location | TEXT | 例: 東京DC-A棟 |
| ip_address | TEXT | 例: 10.1.1.1 |
| vendor | TEXT | Cisco / Juniper / Palo Alto / NEC / Fujitsu |
| model | TEXT | 例: ASR 9922 |
| status | TEXT | active / warning / critical / offline / maintenance |
| uptime_days | INTEGER | 稼働日数（offline/maintenance は 0） |
| last_seen | TEXT | ISO8601 タイムスタンプ |

エリア別台数: 東京 10台 / 大阪 8台 / 名古屋 5台 / 福岡 4台 / 札幌 3台

### alerts（in-memory、alert-api）

初期 7件。severity: critical / warning / info。
解決操作（resolve）で is_resolved フラグが立つ。
alert-api を再起動すると初期 7件にリセットされる。

---

## API エンドポイント一覧

### netwatch-ui（port 8080）

| メソッド | パス | 説明 |
|---------|------|------|
| GET | / | ダッシュボード（ステータスサマリ・エリア分布・最近のアラート・Criticalデバイスリスト） |
| GET | /devices | 機器一覧（クエリパラメータ: area / type / status / q） |
| GET | /devices/{id} | 機器詳細（メトリクスバー・稼働情報・関連アラート） |
| GET | /alerts | アラート一覧（クエリパラメータ: severity / area） |
| GET | /chaos | カオスコントロール画面（シナリオ ON/OFF と CloudWatch 調査ガイド） |
| POST | /api/chaos/slow-query | device-api のスロークエリ ON/OFF |
| POST | /api/chaos/error-inject | device-api のエラー率設定 |
| POST | /api/chaos/alert-storm | alert-api のアラートストーム発火 |
| POST | /api/chaos/reset | 全カオスリセット |
| POST | /api/alerts/{id}/resolve | アラート解決 |

### device-api（port 8000）

| メソッド | パス | 説明 |
|---------|------|------|
| GET | /devices | 機器一覧（フィルタ: area / type / status / q）。RDS を SELECT |
| GET | /devices/{id} | 機器詳細。RDS から取得後 metrics-collector を HTTP 呼び出し（3ホップ目） |
| POST | /chaos/slow-query | DB クエリ前に sleep を挿入（デフォルト 3000ms） |
| POST | /chaos/error-inject | 指定確率（0〜100%）で HTTP 500 を返す |
| POST | /chaos/reset | カオス状態をリセット |
| GET | /chaos/state | 現在のカオス設定を返す |
| GET | /health | ヘルスチェック |

### metrics-collector（port 8000）

| メソッド | パス | 説明 |
|---------|------|------|
| GET | /metrics/{device_id}?status={status} | ステータスに応じた合成メトリクスを返す |
| GET | /health | ヘルスチェック |

返却フィールド: cpu_usage / memory_usage / bandwidth_in / bandwidth_out / packet_loss / latency_ms

ステータス別の値域:

| status | cpu | memory | packet_loss | latency_ms |
|--------|-----|--------|-------------|------------|
| active | 15〜65% | 35〜70% | 0〜0.5% | 0.5〜5ms |
| warning | 70〜88% | 75〜88% | 5〜15% | 80〜400ms |
| critical | 92〜99% | 90〜99% | 20〜60% | 800〜5000ms |
| offline / maintenance | 0% | 0% | 0% | 0ms |

### alert-api（port 8000）

| メソッド | パス | 説明 |
|---------|------|------|
| GET | /alerts | アラート一覧（フィルタ: severity / area） |
| POST | /alerts/{id}/resolve | アラート解決（is_resolved = true） |
| POST | /chaos/alert-storm | 60件のアラートを 0.3秒間隔で in-memory に追加（バックグラウンドスレッド） |
| POST | /chaos/reset | アラートを初期 7件にリセット |
| GET | /health | ヘルスチェック |

---

## トレース構造（分散トレースの流れ）

OTel auto-instrumentation（コード変更なし）が httpx の全呼び出しに W3C TraceContext ヘッダーを自動付与する。

```
# 機器詳細を開いたとき（3ホップ）
[span1] netwatch-ui       GET /devices/{id}           〜5ms+
  └[span2] device-api     GET /devices/{id}           〜3ms+（RDS クエリ含む）
      └[span3] metrics-collector  GET /metrics/{id}   〜1ms

# 機器一覧を開いたとき（2ホップ）
[span1] netwatch-ui       GET /devices
  └[span2] device-api     GET /devices                〜3ms+（RDS クエリ含む）

# アラート一覧（2ホップ）
[span1] netwatch-ui       GET /alerts
  └[span2] alert-api      GET /alerts
```

---

## カオスシナリオ（現状 3 種類）

| シナリオ | 操作対象サービス | 発動方法 | 効果 |
|---------|---------------|---------|------|
| **Slow Query** | device-api | POST /chaos/slow-query + enabled=true + slow_ms=3000 | /devices・/devices/{id} の DB クエリ前に sleep を挿入 |
| **Error Inject** | device-api | POST /chaos/error-inject + rate=30 | 指定確率（%）で HTTP 500 を返す |
| **Alert Storm** | alert-api | POST /chaos/alert-storm | 60件のアラートを 0.3秒間隔でバックグラウンド生成 |

全カオスのリセット: POST /api/chaos/reset（netwatch-ui 経由）または各サービスに直接 POST /chaos/reset

---

## インフラ構成（AWS）

```
EKS Cluster: obs-poc (ap-northeast-1)
  ├─ Managed Node Group: t3.small × 2
  │    └─ Namespace: eks-ec2-appsignals       (EC2 + App Signals)
  │    │    └─ Deployment: netwatch-ui / device-api / alert-api / metrics-collector
  │    │    └─ Service: netwatch-ui (LoadBalancer) / 他3つ (ClusterIP)
  │    └─ Namespace: eks-ec2-newrelic  (EC2 + New Relic)
  │         └─ 同構成アプリ (NR Python Agent 注入)
  └─ Fargate Profile
       └─ Namespace: eks-fargate-appsignals   (Fargate + App Signals)
            └─ 同構成アプリ (OTel Operator 注入。Agent は Deployment として別起動)

RDS: PostgreSQL 16, db.t3.micro, Single-AZ, private subnet
     DB名: netwatch / ユーザー: netwatch
     ※ 全3環境から共用

CloudWatch Observability (EKS Add-on: amazon-cloudwatch-observability):
  ├─ OTel Operator → 全 Pod に OTel Python SDK を自動注入（initContainer）
  ├─ CloudWatch Agent (ADOT) → OTLP HTTP/protobuf :4316 受信 → Application Signals / X-Ray
  ├─ Fluent Bit → stdout JSON → CloudWatch Logs
  └─ Container Insights → Pod/Node メトリクス収集

New Relic Stack (Helm: nri-bundle + k8s-agents-operator):
  ├─ k8s-agents-operator → NR Python Agent を自動注入（initContainer）
  ├─ nri-bundle → Infrastructure Agent / KSM / Prometheus → New Relic
  └─ Fluent Bit → stdout JSON → New Relic Logs

ECR: 4リポジトリ（全3環境共用）
  obs-poc/netwatch-ui
  obs-poc/device-api
  obs-poc/alert-api
  obs-poc/metrics-collector
```

---

## 観測できるシグナル

| シグナル | 収集先 | 主な内容 |
|---------|--------|---------|
| **Traces** | X-Ray / Application Signals | 3ホップの分散トレース、スパン詳細、レイテンシ分布 |
| **Metrics (APM)** | CloudWatch Application Signals | Latency P50/P90/P99、Error率、Fault率、スループット（サービス単位・オペレーション単位） |
| **Metrics (Infra)** | Container Insights | Pod CPU/Memory使用率、Node利用率、Network I/O |
| **Logs** | CloudWatch Logs | JSON構造化ログ（service_name / level / event / duration_ms / device_id 等） |

### ログの主なフィールド（JSON構造化）

```json
{
  "asctime": "2026-05-01 00:00:00",
  "name": "device-api",
  "levelname": "INFO",
  "message": "{\"event\": \"list_devices\", \"count\": 30, \"duration_ms\": 12, \"filters\": {...}}"
}
```

カオス時の追加フィールド例:
- slow_query: `event=slow_query, sleep_ms=3000`
- error_inject: `event=error_injected, error_rate=30`
- alert_storm: `event=alert_storm_started, count=60`

---

## ファイル構成（抜粋）

```
obs-poc/
├── apps/
│   ├── netwatch-ui/
│   │   ├── app.py           FastAPI + httpx で downstream 呼び出し
│   │   └── templates/       Jinja2 テンプレート（base/dashboard/devices/device_detail/alerts/chaos）
│   ├── device-api/
│   │   └── app.py           FastAPI + psycopg2 + httpx
│   ├── alert-api/
│   │   └── app.py           FastAPI + in-memory
│   └── metrics-collector/
│       └── app.py           FastAPI（ステートレス）
├── k8s/
│   ├── ec2/                 EC2 + App Signals 用マニフェスト（namespace: eks-ec2-appsignals）
│   │   ├── netwatch-ui.yaml
│   │   ├── device-api.yaml      OTel inject annotation / DATABASE_URL Secret
│   │   ├── alert-api.yaml
│   │   └── metrics-collector.yaml
│   ├── fargate/             Fargate + App Signals 用マニフェスト（namespace: eks-fargate-appsignals）
│   │   ├── netwatch-ui.yaml     nodeSelector なし / OTLP endpoint は CW Agent Service
│   │   ├── device-api.yaml
│   │   ├── alert-api.yaml
│   │   └── metrics-collector.yaml
│   ├── newrelic/            EC2 + New Relic 用マニフェスト（namespace: eks-ec2-newrelic）
│   │   ├── netwatch-ui.yaml     instrumentation.newrelic.com/inject-python annotation
│   │   ├── device-api.yaml
│   │   ├── alert-api.yaml
│   │   └── metrics-collector.yaml
│   └── namespaces.yaml      eks-ec2-appsignals / eks-fargate-appsignals / eks-ec2-newrelic namespace 定義
├── helm-values/
│   ├── newrelic-values.yaml       NR Helm 共通設定
│   ├── newrelic-ec2-values.yaml   EC2 ノード向け追加設定
│   └── newrelic-fargate-values.yaml (参考: Fargate+NR は本 PoC 対象外)
├── infra/terraform/
│   ├── eks.tf               EKS クラスター + Managed Node Group + Fargate Profile
│   ├── fargate.tf           Fargate Profile / Pod 実行ロール
│   ├── rds.tf               RDS PostgreSQL db.t3.micro
│   ├── vpc.tf               VPC + サブネット + VPC エンドポイント
│   └── variables.tf         rds_password / services リスト 等
└── scripts/
    ├── build-push.sh        Docker build & ECR push（4サービス）
    ├── deploy-ec2.sh        eks-ec2-appsignals への K8s マニフェスト適用
    ├── deploy-fargate.sh    eks-fargate-appsignals への K8s マニフェスト適用
    ├── deploy-newrelic.sh   eks-ec2-newrelic への K8s マニフェスト適用
    ├── create-secrets.sh    RDS 接続情報を K8s Secret として作成
    └── load.sh              負荷生成スクリプト（EC2/Fargate/NR 全環境対応）
```
