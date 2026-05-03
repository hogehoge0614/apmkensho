# ハンズオンガイド — EKS on Fargate + CloudWatch App Signals

> **対象環境:** `eks-fargate-appsignals` (EKS on Fargate, ap-northeast-1)  
> **アクセス:** `make port-forward-fargate` → http://localhost:8081  
> **環境構築・セットアップ手順:** [docs/setup.md](setup.md) を参照  
> **障害対応 Runbook:** [docs/runbook.md](runbook.md) を参照  
> **環境比較:** [docs/environment-comparison.md](environment-comparison.md) を参照

---

## Fargate 環境の特徴と EC2 環境との違い

| 項目 | EKS on EC2 | EKS on Fargate |
|------|-----------|---------------|
| CloudWatch Agent | DaemonSet（各ノードに1つ） | **ADOT Collector Deployment**（同一 namespace 内）|
| OTel エンドポイント | `cloudwatch-agent.amazon-cloudwatch:4316` | `adot-collector.eks-fargate-appsignals:4316` |
| ログ収集 | Fluent Bit DaemonSet | **Fargate 組み込み Fluent Bit**（`aws-observability` ConfigMap） |
| StatsD カスタムメトリクス | ✅ DaemonSet 経由 | ❌ **DaemonSet 非対応のため利用不可** |
| Container Insights | ノード・Pod 両方 | **Pod のみ**（Fargate は仮想ノードのため EC2 ノードメトリクスなし） |
| RUM | ✅ make コマンドで有効化 | ✅ `make fargate-appsignals-enable-rum` で有効化 |
| Application Signals | ✅ | ✅ 同じ機能が利用可能 |

---

## 目次

1. [このガイドについて（推奨実施フロー）](#1-このガイドについて推奨実施フロー)
2. [カオスシナリオ クイックリファレンス](#2-カオスシナリオ-クイックリファレンス)
3. [Application Signals 検証手順](#3-application-signals-検証手順)
4. [Container Insights 確認手順（Fargate 版）](#4-container-insights-確認手順fargate-版)
5. [シナリオ別 確認ガイド（詳細）](#5-シナリオ別-確認ガイド詳細)
6. [CloudWatch Synthetics 外形監視](#6-cloudwatch-synthetics-外形監視)
7. [CloudWatch RUM 検証手順（Fargate 版）](#7-cloudwatch-rum-検証手順fargate-版)
8. [負荷テストガイド](#8-負荷テストガイド)
9. [設計チェックリスト](#9-設計チェックリスト)
10. [Alarm / SLO 設計イメージ](#10-alarm--slo-設計イメージ)

---

## 1. このガイドについて（推奨実施フロー）

### この環境だけを始める手順

共通準備（`make up` / `make create-secrets` / `make build-push`）が完了していれば、この環境だけを単独でデプロイできます。別日に再開する場合は、先に `make check-prereq` と `kubectl config current-context` で接続先を確認してください。

```bash
make install-cloudwatch-full
make fargate-appsignals-deploy
make fargate-appsignals-verify

FARGATE_AS_LB=$(kubectl get svc netwatch-ui -n eks-fargate-appsignals \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "FARGATE_AS_BASE=http://${FARGATE_AS_LB}" >> .env
source .env

EC2_AS_BASE="" EC2_NR_BASE="" FARGATE_NR_BASE="" \
  ./scripts/load.sh normal-device-detail
```

以降の検証は `FARGATE_AS_BASE` だけを使います。他環境が未構築でも進められます。

### 利用可能な機能

| 機能 | 提供サービス | 状態 |
|------|------------|------|
| APM / 分散トレース | Application Signals + X-Ray | ✅ |
| サービスマップ | Application Signals | ✅ |
| SLO管理 | Application Signals SLOs | ✅ |
| コンテナ監視 | Container Insights（Pod のみ） | ✅ |
| ログ | CloudWatch Logs (Fargate 組み込み Fluent Bit) | ✅ |
| 外形監視 | CloudWatch Synthetics | ✅ |
| 実ユーザー監視 | CloudWatch RUM | ✅（要有効化） |
| カスタムメトリクス（StatsD） | — | ❌ DaemonSet 非対応 |

### 推奨実施フロー

```bash
# 事前: port-forward で環境にアクセスできることを確認
make port-forward-fargate   # 別ターミナルで実行。http://localhost:8081

source .env

# ① ベースライン確認
./scripts/load.sh normal-device-detail
# → App Signals で4サービス表示（Environment: eks-fargate-appsignals）

# ② Slow Query シナリオ
curl -X POST "${FARGATE_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
./scripts/load.sh slow-query-devices
curl -X POST "${FARGATE_AS_BASE}/api/chaos/reset"

# ③ Error Inject シナリオ
curl -X POST "${FARGATE_AS_BASE}/api/chaos/error-inject?rate=30"
./scripts/load.sh error-inject-devices
curl -X POST "${FARGATE_AS_BASE}/api/chaos/reset"

# ④ Alert Storm シナリオ
curl -X POST "${FARGATE_AS_BASE}/api/chaos/alert-storm?enable=true"
./scripts/load.sh alert-storm-alerts
curl -X POST "${FARGATE_AS_BASE}/api/chaos/reset"

# ⑤ EC2 環境との比較（両方が稼働中の場合）
make load   # 全環境に同時に負荷をかけてメトリクスを比較
```

---

## 2. カオスシナリオ クイックリファレンス

### 操作コマンド

```bash
source .env   # FARGATE_AS_BASE を読み込む

# Slow Query ON（5秒遅延）
curl -X POST "${FARGATE_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"

# Slow Query OFF
curl -X POST "${FARGATE_AS_BASE}/api/chaos/slow-query?enable=false"

# Error Inject ON（30%）
curl -X POST "${FARGATE_AS_BASE}/api/chaos/error-inject?rate=30"

# Error Inject OFF
curl -X POST "${FARGATE_AS_BASE}/api/chaos/error-inject?rate=0"

# Alert Storm 発動
curl -X POST "${FARGATE_AS_BASE}/api/chaos/alert-storm?enable=true"

# 全カオスリセット
curl -X POST "${FARGATE_AS_BASE}/api/chaos/reset"

# 現在のカオス状態確認
curl -s "${FARGATE_AS_BASE}/api/chaos/state" | python3 -m json.tool
```

> ブラウザから操作する場合は `${FARGATE_AS_BASE}/chaos` のカオスコントロール画面を使用してください。

---

## 3. Application Signals 検証手順

### 前提

```bash
make port-forward-fargate   # 別ターミナルで起動済みであること
source .env
make load                   # トレース・メトリクスが出ていない場合は先に負荷生成
```

---

### 3-1. サービス一覧の確認

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:services

**確認ポイント:**
1. 以下の4サービスが表示されていることを確認:
   - `netwatch-ui`
   - `device-api`
   - `metrics-collector`
   - `alert-api`
2. **Environment 列が `eks-fargate-appsignals` であることを確認**（EC2 環境の `eks-ec2-appsignals` と区別）

> EC2 と Fargate を同時稼働させている場合、同名サービスが2行表示される。Environment 列でフィルタして区別する。

---

### 3-2. Service Map

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:map

**EC2 環境との違い:**
- Fargate Pod は仮想ノード上で動作するため、Map の Pod アイコンに `node-type: fargate` が表示される
- APM の構造（依存グラフ）は EC2 と同一

---

### 3-3. Operation別 Latency（P50 / P90 / P99）

EC2 環境と同じ手順で確認。Environment フィルタを `eks-fargate-appsignals` に変更する。

**正常時の目安（Fargate）:**

| Operation | P50 | P90 | P99 |
|-----------|-----|-----|-----|
| `GET /devices` | < 120ms | < 250ms | < 600ms |
| `GET /devices/{id}` | < 180ms | < 350ms | < 700ms |
| `GET /alerts` | < 60ms | < 120ms | < 250ms |

> Fargate は Cold Start の影響でリクエスト直後のレイテンシが EC2 より高くなる場合がある。

---

### 3-4. Trace 一覧・3ホップトレースの確認

EC2 環境と同じ手順で確認できる。OTel Operator による auto-instrumentation は Fargate でも同様に動作する。

```
フィルタ例（Fargate 環境のトレースのみ）:
service("netwatch-ui") AND annotation.environment = "eks-fargate-appsignals"
```

---

### 3-5. Slow Query / Error Inject / Alert Storm 時の見え方

EC2 環境（[lab-eks-ec2-appsignals.md](lab-eks-ec2-appsignals.md) のセクション 3-8〜3-10）と同様。  
URL を `EC2_AS_BASE` → `FARGATE_AS_BASE` に読み替えて実行する。

---

## 4. Container Insights 確認手順（Fargate 版）

### Fargate における Container Insights の制約

Fargate はノードレスアーキテクチャのため、**EC2 ノードのメトリクス（CPU使用率、ノード数など）は取得できない**。Pod レベルのメトリクスのみ利用可能。

| メトリクス | EC2 環境 | Fargate 環境 |
|-----------|---------|------------|
| ノード CPU / Memory | ✅ | ❌ |
| ノード ネットワーク | ✅ | ❌ |
| Pod CPU / Memory | ✅ | ✅ |
| Pod 再起動回数 | ✅ | ✅ |
| ファイルシステム | ✅ | ❌ |

---

### 4-1. Pod 別メトリクスの確認

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#container-insights:performance

1. ドロップダウンで「EKS Pods」を選択
2. Namespace: `eks-fargate-appsignals` でフィルタ

| Pod | 正常時 CPU | 正常時 Memory |
|-----|----------|-------------|
| netwatch-ui | < 15% | < 120MB |
| device-api | < 20% | < 180MB |
| metrics-collector | < 8% | < 100MB |
| alert-api | < 8% | < 100MB |

> Fargate は各 Pod が独立した VM 上で動作するため、EC2 より若干 CPU / Memory のオーバーヘッドが大きい傾向がある。

---

### 4-2. ログの確認（Fargate 版 Fluent Bit）

Fargate 環境では `aws-observability` Namespace に ConfigMap を配置することで Fargate 組み込みの Fluent Bit がログを CloudWatch に転送する。

**ログロググループ:**
- EC2 環境: `/aws/containerinsights/obs-poc/application`
- Fargate 環境: `/obs-poc/eks-fargate-appsignals/application`（または `/aws/eks/obs-poc/pods`）

**Logs Insights での確認:**
```sql
-- Fargate Pod ログ
fields @timestamp, @message, @logStream
| filter @logStream like "eks-fargate-appsignals"
| sort @timestamp desc
| limit 20
```

---

### 4-3. シナリオ別確認表（Fargate）

| シナリオ | 確認メトリクス | EC2 との比較ポイント |
|---------|-------------|------------------|
| **Slow Query** | device-api Latency P99 | EC2 と同様に上昇。CPU は変化なし（I/O待ち）|
| **Slow Query** | Container Insights Pod CPU | **Fargate は個別ノードが見えない** → APM が主な確認手段 |
| **Error Inject** | device-api Fault rate | EC2 と同様 |
| **Alert Storm** | alert-api Throughput | EC2 と同様のスパイク |

**重要な学習ポイント:**
- Fargate では **インフラ視点の情報（ノード CPU/Memory）が取れない** → APM（Application Signals）の重要性が EC2 より高い
- 障害調査は App Signals → Traces → Logs の流れが特に有効になる

---

## 5. シナリオ別 確認ガイド（詳細）

操作手順は EC2 環境（[lab-eks-ec2-appsignals.md](lab-eks-ec2-appsignals.md) のセクション 5）と同一。  
以下の点を読み替えて実行する:

- `EC2_AS_BASE` → `FARGATE_AS_BASE`
- Namespace `eks-ec2-appsignals` → `eks-fargate-appsignals`
- ポート `8080` → `8081`

### 5-1. 正常時のベースライン

```bash
source .env
./scripts/load.sh normal-device-detail
```

**Fargate 固有の確認:**
- App Signals の Environment フィルタを `eks-fargate-appsignals` に設定
- Container Insights で Pod メトリクスのみ（ノードメトリクスなし）であることを確認

---

### 5-2. Slow Query 検証

```bash
source .env
curl -X POST "${FARGATE_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
./scripts/load.sh slow-query-devices
```

**EC2 との比較（両環境稼働時）:**
- App Signals でそれぞれの Environment の Latency P99 を並べて表示
- Fargate が EC2 より高い場合: Cold Start や Fargate のネットワークレイヤーの影響の可能性

```bash
curl -X POST "${FARGATE_AS_BASE}/api/chaos/reset"
```

---

### 5-3. Error Inject 検証

```bash
source .env
curl -X POST "${FARGATE_AS_BASE}/api/chaos/error-inject?rate=30"
./scripts/load.sh error-inject-devices
curl -X POST "${FARGATE_AS_BASE}/api/chaos/reset"
```

---

### 5-4. Alert Storm 検証

```bash
source .env
curl -X POST "${FARGATE_AS_BASE}/api/chaos/alert-storm?enable=true"
./scripts/load.sh alert-storm-alerts
curl -X POST "${FARGATE_AS_BASE}/api/chaos/reset"
```

---

## 6. CloudWatch Synthetics 外形監視

CloudWatch Synthetics の Canary は EC2/Fargate 環境問わず同一の外部エンドポイントを監視する。  
Canary は LoadBalancer Service の外部 URL を使用する。

### 6-1. Fargate 環境の外部 URL を取得する

```bash
kubectl get svc netwatch-ui -n eks-fargate-appsignals \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

取得した URL を `.env` の `FARGATE_AS_BASE` に設定する（例: `http://<LB-hostname>`）。

### 6-2. Canary 管理手順

EC2 環境と同じ Canary を使用する（同じアプリが別 LoadBalancer で公開されているだけ）。

```bash
aws synthetics start-canary --name obs-poc-health-check --region ap-northeast-1
```

> EC2 と Fargate の両方に Canary を向ける場合は、2つ目の Canary `obs-poc-health-check-fargate` を作成して別々に管理する。

---

### 6-3. Synthetics vs Application Signals

EC2 環境と同じ構造。Slow Query は PASS だが Duration が悪化する点は Fargate でも同様に体験できる。

---

## 7. CloudWatch RUM 検証手順（Fargate 版）

CloudWatch RUM はブラウザ側の JavaScript SDK であるため、Pod が EC2 か Fargate かに関係なく動作する。  
Fargate 環境では専用 make target で `netwatch-ui` に RUM 環境変数を反映する。

### 7-1. 有効化手順

```bash
# Terraform から値を取得
terraform -chdir=infra/terraform output rum_app_monitor_id
terraform -chdir=infra/terraform output cognito_identity_pool_id

# .env に CW_RUM_APP_MONITOR_ID / CW_RUM_IDENTITY_POOL_ID / CW_RUM_REGION を設定後
make fargate-appsignals-enable-rum
```

### 7-2. 動作確認・検証シナリオ

EC2 環境（[lab-eks-ec2-appsignals.md](lab-eks-ec2-appsignals.md) のセクション 7-2〜7-5）と同一。  
ブラウザのアクセス先を `http://localhost:8081/rum-test` に変更する。

---

### 7-3. EC2 との RUM 比較

両環境で RUM を有効化した場合、同じ App Monitor に両環境のデータが混在する。  
User sessions タブでセッションを分類する方法:

- **URL ホストが異なる**（EC2 LoadBalancer と Fargate LoadBalancer の外部 IP/ホスト）
- または App Monitor を環境ごとに別々に作成する（コスト増だが分離が明確）

---

## 8. 負荷テストガイド

### 使い方

```bash
source .env   # FARGATE_AS_BASE を読み込む

# Fargate 環境のみに負荷をかける
EC2_AS_BASE="" ./scripts/load.sh normal-device-detail

# EC2 と Fargate の両方に同時に負荷をかけて比較
make load
```

### 繰り返し回数・間隔の調整

```bash
ROUNDS=10 EC2_AS_BASE="" ./scripts/load.sh normal-device-detail
DELAY=0.5 EC2_AS_BASE="" ./scripts/load.sh error-inject-devices
```

> `EC2_AS_BASE=""` を指定することで、EC2 側をスキップして Fargate のみに送信できる。

### 負荷実行後に見るべき CloudWatch コンソール

| 確認画面 | コンソール URL |
|---------|-------------|
| Application Signals Services | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:services |
| Service Map | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:map |
| X-Ray Traces | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#xray:traces/query |
| Container Insights | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#container-insights:performance |
| Logs Insights | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#logsV2:logs-insights |

---

## 9. 設計チェックリスト

### APM（Application Signals）

- [ ] 4サービスが Application Signals に登録され、Environment が `eks-fargate-appsignals` であることを確認した
- [ ] Service Map で3段の依存グラフが表示される
- [ ] Slow Query 時に device-api Latency P99 が 5000ms 以上になることを確認した
- [ ] Error Inject 時に Fault rate が設定値に比例することを確認した

### 分散トレース（X-Ray）

- [ ] 3ホップトレースを確認した
- [ ] Fargate と EC2 のトレースが同じ構造であることを確認した（計装方式は同一）

### インフラ・コンテナ（Container Insights）

- [ ] Pod 別の CPU / Memory 使用率を確認した
- [ ] **ノードメトリクスが取得できないこと（Fargate 制約）を確認した**
- [ ] Pod の再起動回数が 0 であることを確認した

### ログ（CloudWatch Logs）

- [ ] `eks-fargate-appsignals` のログが CloudWatch Logs に届いていることを確認した
- [ ] Slow Query / Error Inject のログを Logs Insights で確認した

### 外形監視（Synthetics）

- [ ] Canary を起動して正常時の PASS を確認した
- [ ] Error Inject 時に Canary が FAIL になることを確認した
- [ ] Canary を停止した（課金防止）

### CloudWatch RUM

- [ ] Fargate の netwatch-ui に RUM 環境変数を設定した
- [ ] `/rum-test` ページで `✓ AwsRumClient 初期化済み` を確認した
- [ ] RUM データが CloudWatch に届いていることを確認した

### カスタムメトリクス

- [ ] **DaemonSet 非対応のため StatsD カスタムメトリクスは Fargate では利用不可であることを確認した**（設計判断の材料）

### EC2 との比較（両環境稼働時）

- [ ] 同一シナリオで EC2 と Fargate の Latency を比較した
- [ ] Container Insights でノードメトリクスが EC2 にしか存在しないことを確認した

---

## 10. Alarm / SLO 設計イメージ

### Application Signals SLO 設定例

SLO の設定方法は EC2 環境と同一。Environment フィルタを `eks-fargate-appsignals` に変更する。

### CloudWatch Alarm 設計例

#### Alarm 例 1: device-api Fault rate > 5%（Fargate 環境）

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "obs-poc-fargate-device-api-fault-rate" \
  --alarm-description "device-api Fault rate > 5% (Fargate)" \
  --namespace "ApplicationSignals/OperationMetrics" \
  --metric-name "Fault" \
  --dimensions Name=Service,Value=device-api Name=Environment,Value=eks-fargate-appsignals \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --region ap-northeast-1
```

#### Alarm 例 2: device-api Latency P99 > 3000ms（Fargate 環境）

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "obs-poc-fargate-device-api-high-latency" \
  --alarm-description "device-api Latency P99 > 3000ms (Fargate)" \
  --namespace "ApplicationSignals/OperationMetrics" \
  --metric-name "Latency" \
  --dimensions Name=Service,Value=device-api Name=Environment,Value=eks-fargate-appsignals \
  --extended-statistic p99 \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 3000 \
  --comparison-operator GreaterThanThreshold \
  --region ap-northeast-1
```

#### Alarm 例 3: Pod 再起動検知（Fargate 環境）

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "obs-poc-fargate-pod-restart" \
  --alarm-description "Pod restart detected in eks-fargate-appsignals" \
  --namespace "ContainerInsights" \
  --metric-name "pod_number_of_container_restarts" \
  --dimensions Name=ClusterName,Value=obs-poc Name=Namespace,Value=eks-fargate-appsignals \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 0 \
  --comparison-operator GreaterThanThreshold \
  --region ap-northeast-1
```

---

*このガイドは `eks-fargate-appsignals` 環境専用の検証手順書です。他環境のガイドは [lab-eks-ec2-appsignals.md](lab-eks-ec2-appsignals.md) / [lab-eks-ec2-newrelic.md](lab-eks-ec2-newrelic.md) / [lab-eks-fargate-newrelic.md](lab-eks-fargate-newrelic.md) を参照してください。*
