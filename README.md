# Observability PoC - CloudWatch + Application Signals vs New Relic Full Stack

> EKS on EC2 / EKS on Fargate の両環境で、CloudWatch Application Signals と New Relic Full Stack を比較検証するための PoC 環境。

---

## 目次

1. [全体構成図](#1-全体構成図)
2. [作成されるAWSリソース一覧](#2-作成されるawsリソース一覧)
3. [費用が発生するポイント](#3-費用が発生するポイント)
4. [費用を抑えるための設計判断](#4-費用を抑えるための設計判断)
5. [CloudWatch + Application Signals 完全版の構成説明](#5-cloudwatch--application-signals-完全版の構成説明)
6. [New Relic 完全版の構成説明](#6-new-relic-完全版の構成説明)
7. [サンプルアプリの構成説明](#7-サンプルアプリの構成説明)
8. [トレース分析用シナリオの説明](#8-トレース分析用シナリオの説明)
9. [EKS on EC2での検証手順](#9-eks-on-ec2での検証手順)
10. [EKS on Fargateでの検証手順](#10-eks-on-fargateでの検証手順)
11. [Application Signalsで確認する画面・観点](#11-application-signalsで確認する画面観点)
12. [Container Insightsで確認する画面・観点](#12-container-insightsで確認する画面観点)
13. [CloudWatch Logsで確認する画面・観点](#13-cloudwatch-logsで確認する画面観点)
14. [CloudWatch RUMで確認する画面・観点](#14-cloudwatch-rumで確認する画面観点)
15. [CloudWatch Syntheticsで確認する画面・観点](#15-cloudwatch-syntheticsで確認する画面観点)
16. [New Relic Kubernetesで確認する画面・観点](#16-new-relic-kubernetesで確認する画面観点)
17. [New Relic APMで確認する画面・観点](#17-new-relic-apmで確認する画面観点)
18. [New Relic Distributed Tracingで確認する画面・観点](#18-new-relic-distributed-tracingで確認する画面観点)
19. [New Relic Logsで確認する画面・観点](#19-new-relic-logsで確認する画面観点)
20. [New Relic Browserで確認する画面・観点](#20-new-relic-browserで確認する画面観点)
21. [New Relic Syntheticで確認する画面・観点](#21-new-relic-syntheticで確認する画面観点)
22. [EKS on EC2 と EKS on Fargate の導入差分](#22-eks-on-ec2-と-eks-on-fargate-の導入差分)
23. [CloudWatch + Application Signals と New Relic 機能差比較表](#23-cloudwatch--application-signals-と-new-relic-機能差比較表)
24. [トレース分析における両者の見え方の差](#24-トレース分析における両者の見え方の差)
25. [UIの利用方法](#25-uiの利用方法)
26. [PoC後の削除手順](#26-poc後の削除手順)
27. [削除漏れ確認コマンド](#27-削除漏れ確認コマンド)
28. [前提・未確認事項](#28-前提未確認事項)

---

## 1. 全体構成図

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  AWS ap-northeast-1                                                          │
│                                                                              │
│  ┌──────────────── VPC (10.0.0.0/16) ──────────────────────────────────┐   │
│  │                                                                       │   │
│  │  Public Subnet 1a          Public Subnet 1c                          │   │
│  │  ┌─────────────────────┐   ┌─────────────────────┐                  │   │
│  │  │  EKS Cluster: obs-poc                          │                  │   │
│  │  │                                                │                  │   │
│  │  │  ┌──── EC2 Node (t3.medium) ────────────────┐ │                  │   │
│  │  │  │  namespace: demo-ec2                      │ │                  │   │
│  │  │  │  ┌────────────┐  ┌─────────────────────┐ │ │                  │   │
│  │  │  │  │frontend-ui │  │backend-for-frontend  │ │ │                  │   │
│  │  │  │  └────────────┘  └─────────────────────┘ │ │                  │   │
│  │  │  │  ┌──────────┐ ┌─────────────┐ ┌────────┐ │ │                  │   │
│  │  │  │  │order-api │ │inventory-api│ │pay-api │ │ │                  │   │
│  │  │  │  └──────────┘ └─────────────┘ └────────┘ │ │                  │   │
│  │  │  │  ┌─────────────────────────┐              │ │                  │   │
│  │  │  │  │  external-api-simulator │              │ │                  │   │
│  │  │  │  └─────────────────────────┘              │ │                  │   │
│  │  │  │  [CW Agent DaemonSet] [Fluent Bit DS]     │ │                  │   │
│  │  │  └───────────────────────────────────────────┘ │                  │   │
│  │  │                                                │                  │   │
│  │  │  ┌──── Fargate Pods ───────────────────────┐  │                  │   │
│  │  │  │  namespace: demo-fargate                  │  │                  │   │
│  │  │  │  ┌────────────┐  ┌─────────────────────┐ │  │                  │   │
│  │  │  │  │frontend-ui │  │backend-for-frontend  │ │  │                  │   │
│  │  │  │  └────────────┘  └─────────────────────┘ │  │                  │   │
│  │  │  │  ┌──────────┐ ┌─────────────┐ ┌────────┐ │  │                  │   │
│  │  │  │  │order-api │ │inventory-api│ │pay-api │ │  │                  │   │
│  │  │  │  └──────────┘ └─────────────┘ └────────┘ │  │                  │   │
│  │  │  │  [CW Agent Sidecar] [Fluent Bit → CW]     │  │                  │   │
│  │  │  └────────────────────────────────────────────┘  │                  │   │
│  │  └────────────────────────────────────────────────── │                  │   │
│  │                                                                       │   │
│  │  VPC Endpoints: ECR API/DKR, S3 (Gateway), CloudWatch Logs, STS, XRay│   │
│  └───────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  CloudWatch Observability Stack:                                             │
│  ┌────────────────┐ ┌─────────────────┐ ┌──────────────┐ ┌─────────────┐  │
│  │  Application   │ │  Container      │ │  CloudWatch  │ │  CloudWatch │  │
│  │  Signals       │ │  Insights       │ │  RUM         │ │  Synthetics │  │
│  └────────────────┘ └─────────────────┘ └──────────────┘ └─────────────┘  │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  CloudWatch Logs  (retention: 1day)  │  CloudWatch Dashboard  │ Alarms│  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  New Relic Integration Stack:                                                │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  CloudWatch Metric Streams → Kinesis Firehose → New Relic Metric API  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│  ┌──────────────────────┐  ┌──────────────────────┐                         │
│  │  New Relic IAM Role  │  │  ECR Repositories (6) │                         │
│  │  (ReadOnlyAccess)    │  │  obs-poc/<service>    │                         │
│  └──────────────────────┘  └──────────────────────┘                         │
└─────────────────────────────────────────────────────────────────────────────┘

New Relic Cloud (US):
┌──────────────────────────────────────────────────────────┐
│  APM │ Kubernetes │ Distributed Tracing │ Logs │ Browser  │
│  Synthetic │ Infrastructure │ Dashboards │ Alerts         │
└──────────────────────────────────────────────────────────┘
```

---

## 2. 作成されるAWSリソース一覧

| カテゴリ | リソース名 | 備考 |
|----------|-----------|------|
| VPC | obs-poc-vpc | 10.0.0.0/16 |
| Subnet | obs-poc-public-1, public-2 | 2 AZ public subnets |
| Internet Gateway | obs-poc-igw | |
| VPC Endpoint | ecr.api, ecr.dkr, logs, sts, monitoring, xray | Interface endpoints |
| VPC Endpoint | s3 | Gateway (無料) |
| EKS Cluster | obs-poc | version 1.30 |
| EKS Add-on | coredns, kube-proxy, vpc-cni, eks-pod-identity-agent | |
| EKS Add-on | amazon-cloudwatch-observability | Application Signals + Container Insights |
| Managed Node Group | obs-poc-main | 1x t3.medium |
| Fargate Profile | demo-fargate, aws-observability | |
| ECR Repository | obs-poc/{6 services} | |
| IAM Role | cluster-role, node-role, fargate-role | |
| IAM Role | cloudwatch-agent, fluent-bit | IRSA |
| IAM Role | app-signals-ec2, app-signals-fargate | IRSA |
| IAM Role | newrelic-integration | New Relic AWS統合用 |
| IAM Role | metric-stream, firehose, synthetics | |
| CloudWatch Log Groups | /obs-poc/demo-ec2, /obs-poc/demo-fargate, etc. | 1日保持 |
| CloudWatch Dashboard | obs-poc-observability-poc | |
| CloudWatch Alarms | 5個 | latency/error/cpu |
| CloudWatch RUM | obs-poc-rum | |
| Cognito Identity Pool | obs-poc-rum-pool | RUM用 |
| CloudWatch Synthetics | obs-poc-health-check | |
| S3 Bucket | obs-poc-synthetics-{account} | アーティファクト保存 |
| S3 Bucket | obs-poc-firehose-backup-{account} | 失敗配信バックアップ |
| Kinesis Firehose | obs-poc-newrelic-metrics | New Relic連携 |
| CloudWatch Metric Stream | obs-poc-newrelic-stream | |

---

## 3. 費用が発生するポイント

| リソース | 単価 | PoC目安 |
|----------|------|---------|
| EKS Cluster | $0.10/hr | ~$2.40/day |
| EC2 t3.medium (1台) | $0.052/hr | ~$1.25/day |
| Fargate (pods) | vCPU/GB per sec | ~$0.50/day (軽負荷) |
| VPC Interface Endpoints | $0.01/hr × 5 | ~$1.20/day |
| CloudWatch Logs | $0.76/GB ingested | ~$0 (1日保持) |
| CloudWatch RUM | $1/10,000 events | ~$0 (PoC) |
| CloudWatch Synthetics | $0.0012/run | ~$0.02/day (5分毎) |
| Kinesis Firehose | $0.029/GB | ~$0 (PoC) |
| S3 | $0.023/GB | ~$0 |
| New Relic | 無料枠内 or 契約 | 別途 |
| **合計概算** | | **~$5-7/day** |

---

## 4. 費用を抑えるための設計判断

| 判断 | 理由 |
|------|------|
| NAT Gateway を使わない | NAT Gateway: ~$1.08/day + データ転送料。VPC Endpointで代替 |
| EKS Cluster 1つのみ | 2つにすると固定費が倍 |
| EC2ノード 1台 (t3.medium) | PoC規模に十分。スポットは複雑になるので回避 |
| CloudWatch Logs 保持1日 | ストレージ費用ゼロ化 |
| New Relic lowDataMode | インジェスト量を削減 |
| ALBを使わない | ALBは$0.022/hr。port-forwardで代替 |
| Synthetics は手動start | 常時実行を避けてコスト削減 |
| ECRライフサイクル最新5件 | ストレージ削減 |

---

## 5. CloudWatch + Application Signals 完全版の構成説明

### 構成要素

```
EKS Cluster
  └── amazon-cloudwatch-observability Add-on
        ├── CloudWatch Agent (DaemonSet on EC2)
        │     ├── メトリクス収集 (Container Insights)
        │     ├── OTLP受信 (Application Signals)
        │     └── X-Ray Proxy (Application Signals)
        ├── Fluent Bit (DaemonSet on EC2)
        │     └── コンテナログ → CloudWatch Logs
        └── ADOT Operator / OTel Webhook
              └── Python auto-instrumentation injection
```

### EC2 構成フロー
```
App (demo-ec2)
  → OTel SDK (Python)
  → OTLP → CloudWatch Agent :4317 (DaemonSet)
  → CloudWatch Application Signals
  → X-Ray Trace Store

App Logs (stdout)
  → Fluent Bit (DaemonSet)
  → CloudWatch Logs /obs-poc/demo-ec2/application
```

### Fargate 構成フロー (制約あり)
```
App (demo-fargate)
  → OTel SDK (Python)
  → OTLP → localhost:4317 (CW Agent sidecar - addon webhookが注入)
  → CloudWatch Application Signals

App Logs (stdout)
  → Fargate Fluent Bit (aws-observability ConfigMap で設定)
  → CloudWatch Logs /obs-poc/demo-fargate/application
```

### ⚠️ Fargate の制約
- **Container Insights 拡張監視** (Enhanced Monitoring): Fargate では **未対応**。Pod/Container レベルのメモリ・CPU の詳細メトリクスが取得できない場合あり
- **DaemonSet 不可**: CloudWatch Agent・Fluent Bit は DaemonSet ではなく、addon の mutating webhook によるサイドカーインジェクション、または Fargate ログルーターとして動作
- **Application Signals on Fargate**: CloudWatch Observability EKS Add-on v1.5+ で対応しているが、EC2 と異なる動作経路。PoC時点でのバージョンを確認すること
- **ノードメトリクス**: Fargate ノードの EC2 インスタンスメトリクスは取得不可

---

## 6. New Relic 完全版の構成説明

### 構成要素

```
nri-bundle Helm Chart
  ├── newrelic-infrastructure (DaemonSet - EC2 のみ)
  │     └── Pod/Node/Container メトリクス収集
  ├── nri-kube-events (Deployment)
  │     └── Kubernetes Events → New Relic
  ├── kube-state-metrics (Deployment)
  │     └── Kubernetes State Metrics
  ├── newrelic-logging (Fluent Bit DaemonSet - EC2 のみ)
  │     └── コンテナログ → New Relic Logs API
  └── nri-metadata-injection (Webhook)
        └── Pod に NR メタデータを自動注入

App Container
  ├── newrelic Python agent (APM + Distributed Tracing)
  │     └── New Relic APM API
  └── OTel SDK (OTLP exporter)
        └── New Relic OTLP Endpoint (otlp.nr-data.net:4317)

AWS Integration:
  CloudWatch Metric Streams → Kinesis Firehose → New Relic Metric API
  IAM Role (ReadOnlyAccess) → New Relic AWS API Polling
```

### ⚠️ Fargate の制約 (New Relic)
- **newrelic-infrastructure DaemonSet**: Fargate では実行不可。EC2 ノード上で実行し、K8s API 経由で Fargate Pod 情報を間接的に収集
- **Fluent Bit DaemonSet**: Fargate 非対応。Fargate ログは CloudWatch Logs 経由か、aws-observability の Fluent Bit ログルーターを使う
- **Pixie Integration**: Fargate 非対応
- **Infrastructure Agent on Fargate**: サポートなし。APM Agent はコンテナ内で動作するため使用可能
- **New Relic Kubernetes on Fargate**: 2024年時点でFargate向けのKubernetes Integration はEC2ノードから見た間接的な情報収集になる。Fargate Pod の直接エージェント監視は **Preview/制約あり**

---

## 7. サンプルアプリの構成説明

### サービス構成

```
Browser
  │
  ▼
frontend-ui (FastAPI port:8000)
  │  サービス検証: UI配信 + APIプロキシ
  │  Browser Agent / CloudWatch RUM を HTML に注入
  │
  ▼
backend-for-frontend (FastAPI port:8000)
  │  各ダウンストリームへの呼び出し制御
  │
  ├──▶ inventory-api (FastAPI port:8000)
  │       在庫確認、スロー遅延シミュレーション
  │
  ├──▶ order-api (FastAPI port:8000)
  │       注文処理、external-api-simulator を呼び出す
  │       │
  │       └──▶ external-api-simulator (FastAPI port:8000)
  │               外部 SaaS API 模倣、超遅延シミュレーション
  │
  └──▶ payment-api (FastAPI port:8000)
          決済処理、スロー遅延・エラーシミュレーション
```

### 計装方針

- **OpenTelemetry SDK**: 全サービスで使用。W3C Trace Context + B3 の両プロパゲーター対応
- **New Relic Python Agent**: `newrelic-admin run-program uvicorn` で起動し、OTel と並行動作
- **構造化 JSON ログ**: `python-json-logger` を使用。全フィールド (trace_id, span_id, request_id 等) を含む
- **X-Request-Id**: サービス間 HTTP ヘッダーで request_id を伝播

---

## 8. トレース分析用シナリオの説明

| シナリオ URL | 説明 | 遅延 | エラー |
|-------------|------|------|--------|
| `/api/checkout/normal` | 正常な全サービス呼び出し | ~100ms | なし |
| `/api/checkout/slow-inventory` | inventory-api が 2秒遅延 | ~2.1s | なし |
| `/api/checkout/slow-payment` | payment-api が 2.5秒遅延 | ~2.6s | なし |
| `/api/checkout/payment-error` | payment-api が HTTP 500 | ~50ms | あり |
| `/api/checkout/external-slow` | external-api-simulator が 3.5秒遅延 | ~3.6s | なし |
| `/api/checkout/random` | 上記をランダムに実行 | 不定 | 不定 |
| `/api/search` | 商品検索 (軽処理) | ~40ms | なし |
| `/api/user-journey` | 検索→在庫→注文→決済の完全フロー | ~200ms | なし |

### トレースで確認できること
- 1リクエストが6サービスに伝播する様子
- スパンの長さでボトルネックサービスを特定
- エラーが発生したサービスとスタックトレースの確認
- external-api-simulator が外部依存として表示される
- request_id → trace_id → span_id の相関

---

## 9. EKS on EC2での検証手順

```bash
# 1. AWSリソース作成
make up

# 2. New Relicシークレット作成
make create-secrets

# 3. イメージビルド・プッシュ
make build-push

# 4. EC2ノードにデプロイ
make deploy-ec2

# 5. CloudWatchスタック設定
make install-cloudwatch-full

# 6. New Relicスタック設定 (NEW_RELIC_LICENSE_KEY必須)
make install-newrelic-full

# 7. UIにアクセス
make port-forward-ec2
# → ブラウザで http://localhost:8080 を開く

# 8. 負荷生成 (別ターミナルで実行)
make load

# 9. 比較観点確認
make compare-check
```

### Application Signals 自動計装の確認

```bash
# 計装 Instrumentation リソース確認
kubectl get instrumentation -n demo-ec2

# Pod にサイドカーが注入されているか確認
kubectl describe pod -n demo-ec2 -l app=frontend-ui | grep -A5 "Init Containers"

# OTel コレクターへの疎通確認
kubectl exec -n demo-ec2 -l app=frontend-ui -- \
  curl -s http://cloudwatch-agent.amazon-cloudwatch:4317/healthz
```

---

## 10. EKS on Fargateでの検証手順

```bash
# 1. Fargateデプロイ (EC2セットアップ完了後)
make deploy-fargate

# 2. Fargate UIにアクセス
make port-forward-fargate
# → ブラウザで http://localhost:8081 を開く

# 3. Fargate Fluent Bit ログルーティング確認
kubectl get configmap aws-logging -n aws-observability -o yaml

# 4. 負荷生成
FARGATE_BASE=http://localhost:8081 make load

# 5. ログ確認 (Fargate)
make logs NS=demo-fargate SVC=frontend-ui
```

### Fargate Pod 確認

```bash
# Fargate Pod のノードタイプ確認
kubectl get pods -n demo-fargate -o wide
# → NODE列が "fargate-..." のような仮想ノード名になる

# Fargate Pod の制限確認
kubectl describe node -l eks.amazonaws.com/compute-type=fargate | head -50
```

---

## 11. Application Signalsで確認する画面・観点

**URL**: `CloudWatch > Application Signals > Services`

### Service Map
- `frontend-ui → backend-for-frontend → order-api/inventory-api/payment-api → external-api-simulator` の依存グラフ
- 各サービスのレイテンシ・エラー率のリアルタイム表示
- **slow-payment** シナリオ実行後: payment-api ノードが赤色に変化
- **EC2 vs Fargate**: `Environment` 別にフィルタして比較

### Traces 画面
- **Trace Explorer** でトレースを検索
- フィルタ: `service.name = payment-api AND status_code = 500`
- 個別トレースのウォーターフォール表示で各スパンの時間を確認
- スパンの `Attributes` でリクエスト詳細を確認

### SLOs
- レイテンシ SLO: p99 < 2000ms
- エラー率 SLO: < 1%

---

## 12. Container Insightsで確認する画面・観点

**URL**: `CloudWatch > Container Insights > Performance Monitoring`

### EC2 ノードの確認
- `Cluster` → `demo-ec2 namespace` → 各 Pod の CPU/Memory
- 時系列グラフで `slow-inventory` 実行中のリソース消費変化
- **Enhanced Monitoring**: 拡張メトリクスは EC2 で利用可能

### Fargate の確認 (制約あり)
- Fargate Pod のメモリ/CPU 確認は限定的
- `ContainerInsights` メトリクスで確認: `pod_cpu_utilization`, `pod_memory_utilization`
- **注意**: Fargate では enhanced monitoring は非対応

---

## 13. CloudWatch Logsで確認する画面・観点

**Log Group**: `/obs-poc/demo-ec2/application`, `/obs-poc/demo-fargate/application`

### Log Insights クエリ例

```sql
-- エラーログの検索
fields @timestamp, service_name, endpoint, status_code, latency_ms, trace_id, error_message
| filter status_code >= 400
| sort @timestamp desc
| limit 50

-- 特定サービスのレイテンシ分布
fields @timestamp, service_name, latency_ms
| filter service_name = "payment-api"
| stats avg(latency_ms), max(latency_ms), min(latency_ms) by bin(1m)

-- trace_id による相関検索
fields @timestamp, service_name, endpoint, trace_id
| filter trace_id = "YOUR_TRACE_ID_HERE"
| sort @timestamp asc
```

### Logs in Context (CloudWatch)
- Application Signals のトレース画面から `View in CloudWatch Logs` リンク
- trace_id でログをフィルタして対応ログを確認

---

## 14. CloudWatch RUMで確認する画面・観点

**URL**: `CloudWatch > RUM > App Monitors > obs-poc-rum`

### RUM Browser Snippet を frontend-ui に注入する手順

```bash
# 1. Terraform output から App Monitor ID を取得
cd infra/terraform && terraform output rum_app_monitor_id
cd infra/terraform && terraform output cognito_identity_pool_id

# 2. AWS Console でスニペットを取得
# CloudWatch > RUM > obs-poc-rum > Configuration > JavaScript snippet

# 3. frontend-ui の環境変数に設定 (k8s/ec2/frontend-ui.yaml)
env:
  - name: CW_RUM_SNIPPET
    value: |
      <script>
        (function(n,i,v,r,s,c,x,z){x=window.AwsRumClient=...
      </script>
```

### 確認観点
- **Page Views**: UI の `/ ` ページビュー数
- **JS Errors**: `Trigger JS Error` ボタン押下後のエラーキャプチャ
- **HTTP Errors**: `payment-error` シナリオ後の API エラー
- **Performance**: `Trigger Slow Render` 後の LCP 悪化
- **Sessions**: ユーザーセッション単位の行動追跡

---

## 15. CloudWatch Syntheticsで確認する画面・観点

**URL**: `CloudWatch > Synthetics > Canaries`

### カナリア起動手順
```bash
# PoC中のみ実行 (手動)
aws synthetics start-canary \
  --name obs-poc-health-check \
  --region ap-northeast-1

# 停止
aws synthetics stop-canary \
  --name obs-poc-health-check \
  --region ap-northeast-1
```

### 確認観点
- **Success Rate**: ヘルスチェックの成功率
- **Duration**: 応答時間トレンド
- **Screenshots**: 各実行のスクリーンショット
- **HAR files**: HTTP アーカイブの詳細

---

## 16. New Relic Kubernetesで確認する画面・観点

**URL**: `https://one.newrelic.com/kubernetes`

### 確認観点
- **Cluster Explorer**: obs-poc クラスターの全体マップ
- **Namespace View**: `demo-ec2` と `demo-fargate` の Pod 一覧
- **Pod Detail**: 各 Pod の CPU/Memory/ネットワーク
- **Events**: Kubernetes Events (nri-kube-events 経由)
- **APM Link**: Pod → APM サービスへのナビゲーション

### Fargate での確認
- EC2 ノード上の `newrelic-infrastructure` が Kubernetes API 経由で Fargate Pod 情報を収集
- ノードレベルのメトリクス (CPU/Memory) は EC2 ノードのみ詳細表示
- Fargate Pod のアプリレベルメトリクスは APM Agent 経由

---

## 17. New Relic APMで確認する画面・観点

**URL**: `https://one.newrelic.com/apm`

### 確認対象サービス
- `frontend-ui` / `frontend-ui-fargate`
- `backend-for-frontend` / `backend-for-frontend-fargate`
- `order-api` / `order-api-fargate`
- `inventory-api` / `inventory-api-fargate`
- `payment-api` / `payment-api-fargate`
- `external-api-simulator` / `external-api-simulator-fargate`

### 確認観点
- **Summary**: Apdex、スループット、エラー率、応答時間
- **Transactions**: エンドポイント別のレイテンシ分布
- **Errors**: エラー率、スタックトレース、エラーメッセージ
- **External Services**: `external-api-simulator` への呼び出し可視化
- **JVM/Python Runtime**: メモリ、GC、スレッド (Pythonエージェント)

---

## 18. New Relic Distributed Tracingで確認する画面・観点

**URL**: `https://one.newrelic.com/distributed-tracing`

### 検索フィルタ例
```
# サービス横断トレース
service.name = 'frontend-ui' AND trace.id = '<trace_id>'

# エラートレースのみ
error.group.message LIKE '%payment%'

# 遅延トレースのみ
duration.ms > 2000 AND service.name = 'backend-for-frontend'
```

### 確認観点
- **Trace Waterfall**: frontend-ui → bff → order-api → payment-api の全スパン
- **Span Detail**: 各スパンの属性、タグ、エラー詳細
- **Service Map**: トレースに関連するサービスの依存グラフ
- **Comparison**: Application Signals のウォーターフォールと比べた見やすさ

---

## 19. New Relic Logsで確認する画面・観点

**URL**: `https://one.newrelic.com/logger`

### 確認観点 (Logs in Context)
1. APM のトレース画面でスパンを選択
2. `Logs` タブをクリック → そのスパンのログが自動表示
3. JSON 構造化ログの各フィールドが検索可能

### ログ検索クエリ例
```
# エラーログ
service_name:'payment-api' status_code:>=400

# 特定トレース
trace_id:'<trace_id>'

# 遅延ログ
latency_ms:>1000 AND service_name:'inventory-api'
```

---

## 20. New Relic Browserで確認する画面・観点

**URL**: `https://one.newrelic.com/browser`

### Browser Agent を frontend-ui に注入する手順

```bash
# 1. New Relic UI > Browser > Add data > コピーする JS スニペット
# 2. k8s/ec2/frontend-ui.yaml の env に追加
env:
  - name: NEW_RELIC_BROWSER_SNIPPET
    value: |
      <script type="text/javascript">
        ;window.NREUM||(NREUM={}); ...
      </script>

# 3. または ConfigMap を使って注入
```

### 確認観点
- **Page Views**: ブラウザからの `/` アクセス
- **Core Web Vitals**: LCP, FID, INP, CLS
- **AJAX**: `/api/checkout/*` の AJAX 呼び出し
- **JS Errors**: `Trigger JS Error` ボタン後のエラー
- **Session Trace**: ユーザー操作の時系列再現
- **APM Correlation**: Browser セッション → Backend トレース

---

## 21. New Relic Syntheticで確認する画面・観点

**URL**: `https://one.newrelic.com/synthetics`

### モニター設定
- Type: Simple (Ping)
- URL: frontend-ui エンドポイント
- Frequency: 10分毎
- Location: AWS_AP_NORTHEAST_1

### 確認観点
- **Success Rate**: 可用性モニタリング
- **Response Time**: 時系列トレンド
- **Downtime Alerts**: 閾値超過時の通知

---

## 22. EKS on EC2 と EKS on Fargate の導入差分

| 項目 | EKS on EC2 | EKS on Fargate |
|------|------------|----------------|
| CloudWatch Agent | DaemonSet | Addon Webhook によるサイドカー注入 |
| Fluent Bit | DaemonSet | aws-observability ConfigMap (ログルーター) |
| Container Insights | 拡張監視対応 | 基本メトリクスのみ (制約あり) |
| Application Signals | 完全対応 | 対応 (addon v1.5+、制約あり) |
| NR Infrastructure | DaemonSet | 非対応 (EC2ノードから間接収集) |
| NR Fluent Bit | DaemonSet | 非対応 |
| NR APM Agent | コンテナ内 | コンテナ内 (同じ) |
| ノードアクセス | SSH / SSM | 不可 |
| Pod起動速度 | 速い (~30s) | 遅い (~60-90s) |
| スケーリング | HPA + Cluster Autoscaler | HPA のみ (自動) |

---

## 23. CloudWatch + Application Signals と New Relic 機能差比較表

| 比較項目 | EKS on EC2 + CloudWatch App Signals | EKS on EC2 + New Relic Full Stack | EKS on Fargate + CloudWatch App Signals | EKS on Fargate + New Relic Full Stack |
|---------|------------------------------------|------------------------------------|----------------------------------------|---------------------------------------|
| **導入方式** | EKS Add-on (1コマンド) | Helm Chart (nri-bundle) | EKS Add-on (Sidecar注入) | Helm Chart (EC2ノードのみ) |
| **アプリ改修有無** | なし (OTel自動計装) | なし (NRエージェント自動計装) | なし | なし |
| **Kubernetes側の設定** | Namespace annotation | Helm values + Secret | Namespace annotation | Helm values + Secret |
| **エージェント方式** | CW Agent DaemonSet | NR Infrastructure DaemonSet | CW Agent Sidecar | EC2上のDaemonSet (Fargate側非対応) |
| **APM計装方式** | OTel SDK → CW Agent → App Signals | New Relic Python Agent + OTel | OTel SDK → CW Agent Sidecar | New Relic Python Agent |
| **分散トレース** | X-Ray + OTLP | New Relic Distributed Tracing | X-Ray + OTLP | New Relic Distributed Tracing |
| **トレースの見やすさ** | ★★★★☆ ウォーターフォール表示 | ★★★★★ より詳細な属性・UI | ★★★☆☆ EC2に比べ一部制約 | ★★★★★ EC2と同等 |
| **サービス依存関係** | ★★★★☆ Service Map あり | ★★★★★ Service Map + Entity Explorer | ★★★☆☆ | ★★★★★ |
| **遅延箇所特定** | ★★★★☆ スパン時間グラフ | ★★★★★ ウォーターフォール+属性 | ★★★☆☆ | ★★★★★ |
| **エラー原因特定** | ★★★★☆ スタックトレースあり | ★★★★★ Error Analytics | ★★★☆☆ | ★★★★★ |
| **ログ連携** | CW Logs + trace_id 検索 | Logs in Context (自動リンク) | CW Logs (Fargate ログルーター) | Logs in Context |
| **メトリクス連携** | Container Insights | NR Infrastructure + Prometheus | 基本メトリクスのみ | EC2側から間接収集 |
| **Kubernetes可視化** | Container Insights | NR Kubernetes (Cluster Explorer) | 基本のみ | EC2ノードから見たFargate情報 |
| **Pod/Node状態** | CW Container Insights | NR Kubernetes | 制約あり | EC2ノードのみ詳細 |
| **ブラウザ監視** | CloudWatch RUM | New Relic Browser | CloudWatch RUM | New Relic Browser |
| **外形監視** | CloudWatch Synthetics | New Relic Synthetic | CloudWatch Synthetics | New Relic Synthetic |
| **ダッシュボード** | CW Dashboard (JSON定義) | NR Dashboard (NRQL) | CW Dashboard | NR Dashboard |
| **アラート** | CW Alarms | NR Alerts (NRQL/AI) | CW Alarms | NR Alerts |
| **取得できる情報** | AWS統合が強力・X-Rayトレース・RUM・Synthetics | APM/K8s/Logs/Browser/Syntheticsの完全統合 | Application Signals・基本メトリクス・ログ | APM・Logs・K8s間接情報 |
| **取得しづらい情報** | 複数サービス横断の相関が若干手間 | AWS CLoudFormation/EKS詳細はAWS Consoleが必要 | Container Insights拡張・ノードメトリクス | Fargateノードの詳細メトリクス |
| **初動分析のしやすさ** | ★★★★☆ | ★★★★★ | ★★★☆☆ | ★★★★☆ |
| **原因箇所特定** | ★★★★☆ | ★★★★★ | ★★★☆☆ | ★★★★★ |
| **ユーザー影響把握** | ★★★★☆ RUM + CW Alarms | ★★★★★ Browser + AI Monitoring | ★★★☆☆ | ★★★★★ |
| **運用上のメリット** | AWSネイティブ・IAM統合・追加コストなし | 1画面で全情報・Logs in Context・AI | AWSネイティブ・マネージド | クラウド横断監視可能 |
| **運用上の制約** | AWS外のサービスは別ツール必要 | NR費用・NR学習コスト | DaemonSet非対応・制約多い | Fargate直接エージェント非対応 |
| **本番導入時の注意点** | Fargate制約の確認・Application Signals料金 | NR Licenseコスト・インジェスト量管理 | 機能制約を事前に把握 | DaemonSet代替設計が必要 |
| **PoCで確認すべき画面** | App Signals Service Map / Traces | NR APM / Distributed Tracing | App Signals + CW Logs | NR APM + Kubernetes |

---

## 24. トレース分析における両者の見え方の差

### slow-payment シナリオでの比較

**CloudWatch Application Signals:**
```
Service Map: payment-api ノードの色が変化
Trace View:
  frontend-ui [===100ms=======]
    bff        [==90ms========]
      inventory [=20ms=]
      order-api [=30ms=]
      payment-api            [=====2500ms=====]  ← 赤色強調
```

**New Relic Distributed Tracing:**
```
Trace Waterfall:
  frontend-ui    |━━━━━━━━━━━━━━━━━━━━━━━━━━━━━| 2.6s
  bff            |━━━━━━━━━━━━━━━━━━━━━━━━━━━| 2.5s
  inventory-api  |━━| 20ms
  order-api      |━━━| 30ms
  payment-api              |━━━━━━━━━━━━━━| 2.5s ⚠️ SLOW
  Attributes: payment.delay_reason=fraud_check, delay_ms=2500
```

### 主な差異
| 観点 | Application Signals | New Relic |
|------|--------------------|-----------||
| Service Map のリアルタイム | ★★★★☆ | ★★★★★ |
| スパン属性の詳細度 | ★★★☆☆ | ★★★★★ |
| ログとのリンク | 手動 (trace_id コピー) | 自動 (クリック一発) |
| エラーのハイライト | ★★★☆☆ | ★★★★★ |
| 複数トレースの比較 | ★★★☆☆ | ★★★★☆ |
| UI の直感性 | ★★★★☆ | ★★★★★ |

---

## 25. UIの利用方法

```bash
# EC2版 UI を起動
make port-forward-ec2
# → http://localhost:8080

# Fargate版 UI を起動 (別ターミナル)
make port-forward-fargate
# → http://localhost:8081
```

### UI の操作方法
1. **左側パネル** でシナリオを選択して実行
2. **右側パネル** に実行結果・レイテンシ・コールパスが表示
3. **下部タイムライン** に直近のリクエスト履歴
4. **Browser Testing セクション** でブラウザRUM/エラーテスト
5. `Application Signals で見る観点` / `New Relic で見る観点` に確認手順を表示

### シナリオ実行後の確認手順
1. UIの `trace_id` をコピー
2. CloudWatch: `Application Signals > Traces > Search by Trace ID`
3. New Relic: `Distributed Tracing > Search > trace.id = '<trace_id>'`
4. `make compare-check` で詳細な確認観点を表示

---

## 26. PoC後の削除手順

```bash
# 1. Syntheticsカナリアを停止
aws synthetics stop-canary \
  --name obs-poc-health-check \
  --region ap-northeast-1

# 2. 全リソースを一括削除
make down

# 3. 削除漏れを確認
make destroy-check
```

### 個別削除コマンド (make down が失敗した場合)

```bash
# Helm releases
helm uninstall nri-bundle -n newrelic

# Kubernetes namespaces
kubectl delete namespace demo-ec2 demo-fargate newrelic aws-observability

# EKS Add-on
aws eks delete-addon \
  --cluster-name obs-poc \
  --addon-name amazon-cloudwatch-observability \
  --region ap-northeast-1

# Terraform
cd infra/terraform
terraform destroy -auto-approve \
  -var="new_relic_license_key=${NEW_RELIC_LICENSE_KEY}" \
  -var="new_relic_account_id=${NEW_RELIC_ACCOUNT_ID}"

# ECR (手動削除が必要な場合)
for svc in frontend-ui backend-for-frontend order-api inventory-api payment-api external-api-simulator; do
  aws ecr delete-repository \
    --repository-name obs-poc/${svc} \
    --force \
    --region ap-northeast-1
done
```

---

## 27. 削除漏れ確認コマンド

```bash
make destroy-check

# または手動確認
# EKS
aws eks list-clusters --region ap-northeast-1

# EC2 instances
aws ec2 describe-instances \
  --region ap-northeast-1 \
  --filters "Name=tag:Project,Values=obs-poc" "Name=instance-state-name,Values=running"

# VPC Endpoints (課金対象)
aws ec2 describe-vpc-endpoints \
  --region ap-northeast-1 \
  --filters "Name=tag:Project,Values=obs-poc" "Name=vpc-endpoint-state,Values=available"

# CloudWatch Log Groups
aws logs describe-log-groups \
  --log-group-name-prefix "/obs-poc" \
  --region ap-northeast-1

# Firehose
aws firehose list-delivery-streams --region ap-northeast-1

# S3 Buckets
aws s3 ls | grep obs-poc

# CloudWatch Metric Streams
aws cloudwatch list-metric-streams --region ap-northeast-1

# Synthetics
aws synthetics describe-canaries --region ap-northeast-1
```

---

## 28. 前提・未確認事項

### 前提条件 (PoC実行に必要なもの)

| 項目 | バージョン / 備考 |
|------|-----------------|
| AWS CLI | v2.x |
| kubectl | v1.29+ |
| helm | v3.14+ |
| docker | v24+ |
| terraform | v1.6+ |
| Python | v3.11 (Docker内) |
| New Relic アカウント | Free Tier でも動作可能 |
| AWS権限 | EKS/EC2/IAM/CloudWatch/ECR の Create/Delete |

### 未確認事項・注意点

1. **Application Signals on Fargate の制約範囲**: CloudWatch Observability EKS Add-on の最新バージョン (v1.5+) でFargate対応が追加されているが、EC2との完全同等性は未確認。PoC時に Addon バージョンを確認すること。
   ```bash
   aws eks describe-addon \
     --cluster-name obs-poc \
     --addon-name amazon-cloudwatch-observability \
     --query 'addon.addonVersion'
   ```

2. **New Relic Kubernetes on Fargate のステータス**: 2024年時点で、Fargate での New Relic Infrastructure Agent は正式非対応。Fargate Pod のエージェント直接監視は制限され、EC2ノード上の Infrastructure Agent から K8s API 経由で間接収集になる。最新情報は [NR Docs](https://docs.newrelic.com/docs/kubernetes-pixie/kubernetes-integration/installation/kubernetes-integration-install-configure/) で確認。

3. **CloudWatch Metric Streams の取り込みタイムラグ**: Metric Streams 経由のメトリクスは New Relic に 1-2分のタイムラグがある場合あり。

4. **New Relic OTel エンドポイント**: US データセンターの場合は `otlp.nr-data.net:4317`、EU の場合は `otlp.eu01.nr-data.net:4317`。アカウントのデータセンターを確認すること。

5. **Public Subnet + VPC Endpoint 構成の制限**: Fargate Pod に直接 Public IP が割り当てられないため、ECR への通信は VPC Endpoint 経由のみ。Interface Endpoint の設定が正しくないと Fargate Pod が ImagePullBackOff になる。

6. **Browser Agent / RUM の注入**: frontend-ui の `NEW_RELIC_BROWSER_SNIPPET` と `CW_RUM_SNIPPET` 環境変数への設定は、UIコンソールから手動でスニペットを取得して K8s Secret または ConfigMap に設定する必要がある。Terraform では取得不可。

7. **New Relic Synthetic Monitor URL**: port-forward 経由の `localhost:8080` はNew Relic Syntheticsからアクセス不可。Synthetics テスト用には外部アクセス可能なエンドポイントが必要。`make down` 前に Synthetics モニターを停止すること。

8. **New Relic API Key**: Synthetic モニターの作成には `User API Key (NRAK-...)` が必要。License Key とは別。

9. **Terraform State**: ローカル保存を前提としている。チームで共有する場合は S3 バックエンドを追加すること。

10. **EKS クラスターバージョン**: `1.30` を前提としているが、2025年以降に EOF になる可能性あり。`aws eks describe-cluster` で確認すること。
# apmkensho
