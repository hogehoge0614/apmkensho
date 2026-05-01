# 環境比較ガイド

本 PoC では 4 つの環境構成を比較します。

## 環境一覧

| 環境 | ノードタイプ | オブザーバビリティスタック | Namespace |
|------|------------|--------------------------|-----------|
| EC2 + App Signals | EC2 (managed nodegroup) | CloudWatch Application Signals | `demo-ec2` |
| Fargate + App Signals | AWS Fargate | CloudWatch Application Signals | `demo-fargate` |
| EC2 + New Relic | EC2 (managed nodegroup) | New Relic APM Full Stack | `demo-newrelic` |

> Fargate + New Relic: NR Infrastructure Agent (DaemonSet) が Fargate 非対応のため、本 PoC では扱いません。

## アーキテクチャ比較

### EC2 + App Signals

```
Pod (FastAPI)
  ← OTel Python SDK (init container by OTel Operator)
  → OTLP (4316) → CloudWatch Agent DaemonSet
  → X-Ray / App Signals / CloudWatch Metrics
```

- **Auto-instrumentation**: OTel Operator が init container を注入（コード変更なし）
- **エージェント**: DaemonSet（各 EC2 ノードに 1 つ）
- **ログ**: Fluent Bit DaemonSet → CloudWatch Logs
- **StatsD**: CloudWatch Agent が UDP 8125 で受信

### Fargate + App Signals

```
Pod (FastAPI)
  ← OTel Python SDK (init container by OTel Operator)
  → OTLP (4316) → CloudWatch Agent Service (Deployment)
  → X-Ray / App Signals
```

- **Auto-instrumentation**: 同上（OTel Operator がアノテーションで注入）
- **エージェント**: DaemonSet 不可 → Fargate 用の Agent Deployment を別途用意
- **ログ**: Fargate Fluent Bit sidecar (`aws-observability` ConfigMap) → CloudWatch Logs
- **StatsD**: 未対応（DaemonSet なし）

### EC2 + New Relic

```
Pod (FastAPI)
  ← NR Python Agent (init container by k8s-agents-operator)
  → NR Agent → New Relic APM (one.newrelic.com)
```

- **Auto-instrumentation**: k8s-agents-operator が `instrumentation.newrelic.com/inject-python` アノテーションで注入
- **エージェント**: nri-bundle (Helm) — Infrastructure Agent, Prometheus, KSM など
- **ログ**: NR Fluent Bit → New Relic Logs
- **分散トレース**: New Relic Distributed Tracing (W3C TraceContext)

## 機能比較表

| 機能 | EC2 + AppSignals | Fargate + AppSignals | EC2 + NewRelic |
|------|:---:|:---:|:---:|
| APM (自動計装) | ✅ OTel | ✅ OTel | ✅ NR Agent |
| 分散トレース | ✅ X-Ray | ✅ X-Ray | ✅ NR Tracing |
| サービスマップ | ✅ App Signals | ✅ App Signals | ✅ NR Service Map |
| SLO | ✅ App Signals SLO | ✅ | ❌ (NR SLM は別途) |
| ブラウザ監視 | ✅ CloudWatch RUM | ✅ CloudWatch RUM | ✅ NR Browser |
| インフラメトリクス | ✅ Container Insights | ✅ Container Insights | ✅ NR Infrastructure |
| カスタムメトリクス | ✅ StatsD → CW | ❌ (StatsD 非対応) | ✅ NR Flex / Dimensional |
| ログ | ✅ Fluent Bit → CWL | ✅ Fargate Fluent Bit | ✅ NR Logs |
| アラーム | ✅ CloudWatch Alarms | ✅ | ✅ NR Alerts |
| DB クエリ可視化 | ✅ psycopg2 instrumentation | ✅ | ✅ NR Database |

## コスト考慮点

### CloudWatch App Signals
- App Signals: APM データは一定量まで無料、超過は従量課金
- X-Ray: 100万トレース/月まで無料
- Container Insights: ノード/Pod 数に応じた課金
- CloudWatch RUM: セッション数に応じた課金
- Logs: 取り込み量 + 保存量に応じた課金

### New Relic
- Full Stack Observability ライセンス（ユーザー数 + データ量）
- 無料枠: 100GB/月のデータ取り込み、1 ユーザー
- フルユーザー: $99/月〜

## セットアップ手順

### EC2 + App Signals
```bash
make check-prereq
make up
make create-secrets
make build-push
make install-cloudwatch-full
make ec2-appsignals-deploy
make ec2-appsignals-enable-rum
make ec2-appsignals-enable-custom-metrics
make load
```

### Fargate + App Signals
```bash
make install-cloudwatch-full
make fargate-appsignals-deploy
make load
```

### EC2 + New Relic
```bash
# .env に NEW_RELIC_LICENSE_KEY, NEW_RELIC_ACCOUNT_ID を設定
make install-newrelic-full
make ec2-newrelic-deploy
make load
```

## 削除手順

```bash
# 個別環境の削除
make ec2-appsignals-down
make fargate-appsignals-down
make ec2-newrelic-down

# 全リソース削除 (EKS + Terraform)
make down
```
