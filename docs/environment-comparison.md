# 環境比較ガイド

## 環境マトリクス

| | CloudWatch App Signals | New Relic APM |
|---|---|---|
| **EKS on EC2** | `eks-ec2-appsignals` | `eks-ec2-newrelic` |
| **EKS on Fargate** | `eks-fargate-appsignals` | `eks-fargate-newrelic` ⚠️ |

> ⚠️ `eks-fargate-newrelic`: APM トレースのみ。Infrastructure Agent (DaemonSet) は Fargate 非対応のためインフラメトリクス・ログ転送は収集されない。詳細は後述。

---

## 各環境のアーキテクチャ

### [1] EKS on EC2 + App Signals（`eks-ec2-appsignals`）

```
Pod (FastAPI)
  ← OTel Python SDK（OTel Operator が init container として自動注入）
  → OTLP :4316 → CloudWatch Agent DaemonSet
  → X-Ray / App Signals / CloudWatch Metrics
```

- **Auto-instrumentation**: `instrumentation.opentelemetry.io/inject-python: "true"` アノテーションで注入（コード変更なし）
- **エージェント**: CloudWatch Agent DaemonSet（各 EC2 ノードに 1 つ）
- **ログ**: Fluent Bit DaemonSet → CloudWatch Logs
- **StatsD**: CloudWatch Agent が UDP 8125 で受信 → CloudWatch Metrics

### [2] EKS on Fargate + App Signals（`eks-fargate-appsignals`）

```
Pod (FastAPI)
  ← OTel Python SDK（OTel Operator が init container として自動注入）
  → OTLP :4316 → ADOT Collector Deployment（同一 namespace 内）
  → X-Ray / App Signals（VPC Endpoint 経由、インターネット不要）
```

- **Auto-instrumentation**: `instrumentation.opentelemetry.io/inject-python: "true"` で注入し、namespace 内の Instrumentation CR で送信先 Collector と sampler を指定
- **エージェント**: DaemonSet 不可 → **ADOT Collector を Deployment として namespace 内に配置**（EC2 DaemonSet と完全に独立）
- **ログ**: Fargate 組み込み Fluent Bit（`aws-observability` ConfigMap）→ CloudWatch Logs
- **StatsD**: DaemonSet がないため未対応

### [3] EKS on EC2 + New Relic（`eks-ec2-newrelic`）

```
Pod (FastAPI)
  ← NR Python Agent（k8s-agents-operator が init container として自動注入）
  → NR Agent → New Relic APM（one.newrelic.com）
```

- **Auto-instrumentation**: `instrumentation.newrelic.com/inject-python: "newrelic"` アノテーションで注入
- **エージェント**: nri-bundle（Helm）— Infrastructure Agent DaemonSet + Prometheus + KSM
- **ログ**: NR Fluent Bit DaemonSet → New Relic Logs
- **分散トレース**: New Relic Distributed Tracing（W3C TraceContext）

### [4] EKS on Fargate + New Relic（`eks-fargate-newrelic`）⚠️

```
Pod (FastAPI)
  ← NR Python Agent（k8s-agents-operator が init container として自動注入）
  → NR Agent → New Relic APM（APM トレースのみ）

  ✗ Infrastructure Agent (DaemonSet) — Fargate 非対応
  ✗ Fluent Bit DaemonSet — Fargate 非対応
```

#### Fargate + New Relic が制限される理由

**DaemonSet は Fargate で動かない。** Fargate は「ノードレス」アーキテクチャで AWS がノードを完全に管理するため、ユーザーは仮想ノードに直接 Pod をスケジュールできない。New Relic の主要コンポーネントは DaemonSet に依存している。

| コンポーネント | デプロイ方式 | Fargate |
|---|---|---|
| **Infrastructure Agent** | DaemonSet | ❌ 非対応 |
| **Fluent Bit（ログ転送）** | DaemonSet | ❌ 非対応 |
| kube-state-metrics | Deployment | ✅ 対応 |
| k8s-agents-operator | Deployment | ✅ 対応 |
| **NR Python APM Agent** | init container | ✅ 対応（APM トレースは取得可能） |

CloudWatch App Signals は AWS VPC Endpoint を活用し **インターネット接続なしで Fargate から直接 App Signals / X-Ray に送信**できる。一方 New Relic の APM エージェントは `collector.newrelic.com`（外部）への HTTPS 通信が必要であり、Fargate 環境では NAT Gateway が必須となる。

---

## 機能比較表

| 機能 | EC2 + AppSignals | Fargate + AppSignals | EC2 + NewRelic | Fargate + NewRelic |
|------|:---:|:---:|:---:|:---:|
| APM（自動計装） | ✅ OTel | ✅ OTel | ✅ NR Agent | ✅ NR Agent |
| 分散トレース | ✅ X-Ray | ✅ X-Ray | ✅ NR Tracing | ✅ NR Tracing |
| サービスマップ | ✅ App Signals | ✅ App Signals | ✅ NR Service Map | ✅ NR Service Map |
| SLO | ✅ App Signals SLO | ✅ | ❌（NR SLM は別途） | ❌ |
| ブラウザ監視 | ✅ CloudWatch RUM | ✅ CloudWatch RUM | ✅ NR Browser | ✅ NR Browser |
| インフラメトリクス | ✅ Container Insights | ✅ Container Insights | ✅ NR Infrastructure | ❌ DaemonSet 非対応 |
| カスタムメトリクス | ✅ StatsD → CW | ❌ DaemonSet なし | ✅ NR Flex | ❌ DaemonSet なし |
| ログ | ✅ Fluent Bit DaemonSet | ✅ Fargate Fluent Bit | ✅ NR Logs DaemonSet | ❌ DaemonSet 非対応 |
| アラーム | ✅ CloudWatch Alarms | ✅ | ✅ NR Alerts | ✅ NR Alerts |
| DB クエリ可視化 | ✅ psycopg2 計装 | ✅ | ✅ NR Database | ✅ NR Database |

---

## APM ツール比較（EC2 環境での機能差）

| 機能 | CloudWatch App Signals | New Relic APM |
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
| **遅いTX自動検出** | 手動フィルタ | Transaction Traces（自動キャプチャ） |
| **Apdex** | なし | あり（0–1スコア） |
| **アラート柔軟性** | メトリクスアラーム（ディメンション固定） | NRQL で任意条件を直接アラート化 |
| **コスト構造** | AWS 従量課金 | NR サブスクリプション |

---

## アラート起点の障害調査で比較する観点

この PoC の `make load-*` は、性能試験ではなく APM 調査に必要なトランザクションデータを発生させるための操作として扱う。ハンズオンでは、最初にエラーメッセージ、ログ件数、レイテンシ、エラー率、スループットなどのアラートで異常を検知し、その後 APM で「どの API / サービスが原因で、どの画面や上流サービスに影響しているか」を特定する。

| 構成 | 影響範囲特定 | 根本原因の特定 | ハンズオンで確認する制約 |
|------|--------------|----------------|--------------------------|
| EC2 + App Signals | Service Map / Services / X-Ray で可能 | X-Ray + CloudWatch Logs + Container Insights で裏取り | エラーの自動グルーピングや遅いトランザクションの自動抽出は弱く、手動フィルタが多い |
| Fargate + App Signals | EC2 と同様に Application Signals で可能 | X-Ray + Fargate Logs + Pod メトリクスで裏取り | DaemonSet / StatsD / ノードメトリクスが使えず、APM 中心の切り分けになる |
| EC2 + New Relic | Service Map / APM Summary / Distributed Tracing で可能 | Errors Inbox / Transaction Traces / Logs in Context / Kubernetes Explorer で裏取り | アラートからエラーグループ、代表 trace、関連ログまでの導線が短い |
| Fargate + New Relic | APM / Service Map / Errors Inbox で可能 | Transaction Traces と `kubectl logs` または CloudWatch 側ログで裏取り | NR Infrastructure / NR Logs がないため、APM 外に移る調査が増える |

---

## コスト考慮点

### CloudWatch App Signals
- App Signals: APM データは一定量まで無料、超過は従量課金
- X-Ray: 100万トレース/月まで無料
- Container Insights: ノード/Pod 数に応じた課金
- CloudWatch RUM: セッション数に応じた課金
- Logs: 取り込み量 + 保存量に応じた課金

### New Relic
- Full Stack Observability ライセンス（ユーザー数 + データ量）
- 無料枠: 100GB/月のデータ取り込み、1 フルユーザー
- フルユーザー: $99/月〜
