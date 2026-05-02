# ハンズオンガイド — EKS on EC2 + New Relic

> **対象環境:** `eks-ec2-newrelic` (EKS on EC2, ap-northeast-1)  
> **アクセス:** `make port-forward-newrelic` → http://localhost:8082  
> **環境構築・セットアップ手順:** [docs/setup.md](setup.md) を参照  
> **障害対応 Runbook:** [docs/runbook.md](runbook.md) を参照  
> **環境比較:** [docs/environment-comparison.md](environment-comparison.md) を参照

---

## New Relic 環境の特徴

| 機能 | New Relic | CloudWatch 相当 |
|------|-----------|----------------|
| APM / 自動計装 | NR Python Agent (k8s-agents-operator) | App Signals (OTel Operator) |
| 分散トレース | NR Distributed Tracing (W3C TraceContext) | X-Ray |
| サービスマップ | APM Service Map | App Signals Service Map |
| SLO | Service Levels | App Signals SLOs |
| コンテナ監視 | NR Infrastructure / Kubernetes Explorer | Container Insights |
| ログ | NR Logs (Fluent Bit DaemonSet → NR) | CloudWatch Logs |
| Logs in Context | **1クリックでトレースからログへ** | trace_id で手動検索（2ステップ） |
| エラーグルーピング | **Errors Inbox（自動グルーピング）** | 個別トレースを目視 |
| 遅いTX自動検出 | **Transaction Traces（自動キャプチャ）** | 手動フィルタ |
| 外形監視 | CloudWatch Synthetics（PoC 共通）| CloudWatch Synthetics |
| ブラウザ監視 | **NR Browser（`NR_BROWSER_SNIPPET` で注入）** | CloudWatch RUM |
| カスタムメトリクス | NR Flex（デーモンセット経由） | StatsD → CloudWatch |
| アラート | NR Alerts（NRQL で任意条件）| CloudWatch Alarms（ディメンション固定） |

---

## 目次

1. [このガイドについて（推奨実施フロー）](#1-このガイドについて推奨実施フロー)
2. [カオスシナリオ クイックリファレンス](#2-カオスシナリオ-クイックリファレンス)
3. [New Relic APM 検証手順](#3-new-relic-apm-検証手順)
4. [インフラ・コンテナ（NR Infrastructure / Kubernetes）](#4-インフラコンテナnr-infrastructure--kubernetes)
5. [シナリオ別 確認ガイド（詳細）](#5-シナリオ別-確認ガイド詳細)
6. [ログ（NR Logs + Logs in Context）](#6-ログnr-logs--logs-in-context)
7. [NR Browser（ブラウザ監視）](#7-nr-browserブラウザ監視)
8. [カスタムメトリクス（NR Flex）](#8-カスタムメトリクスnr-flex)
9. [負荷テストガイド](#9-負荷テストガイド)
10. [設計チェックリスト](#10-設計チェックリスト)
11. [NR Alerts / Service Levels 設計イメージ](#11-nr-alerts--service-levels-設計イメージ)

---

## 1. このガイドについて（推奨実施フロー）

### 利用可能な機能

| 機能 | 状態 |
|------|------|
| APM / 分散トレース | ✅ |
| サービスマップ | ✅ |
| SLO（Service Levels） | ✅ |
| Kubernetes / コンテナ監視 | ✅ |
| ログ + Logs in Context | ✅ |
| Errors Inbox | ✅ |
| Transaction Traces | ✅ |
| NR Browser | ✅（NR_BROWSER_SNIPPET を Secret に設定済みの場合） |
| NR Flex カスタムメトリクス | ✅ |

### 推奨実施フロー

```bash
# 事前: port-forward で環境にアクセスできることを確認
make port-forward-newrelic   # 別ターミナルで実行。http://localhost:8082

source .env

# ① ベースライン確認
./scripts/load.sh normal-device-detail
# → one.newrelic.com > APM で4サービス表示

# ② Slow Query シナリオ
curl -X POST "${EC2_NR_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
./scripts/load.sh slow-query-devices
# → NR APM の Transaction Traces に自動キャプチャされていることを確認
curl -X POST "${EC2_NR_BASE}/api/chaos/reset"

# ③ Error Inject シナリオ
curl -X POST "${EC2_NR_BASE}/api/chaos/error-inject?rate=30"
./scripts/load.sh error-inject-devices
# → Errors Inbox でエラーが自動グルーピングされていることを確認
curl -X POST "${EC2_NR_BASE}/api/chaos/reset"

# ④ Alert Storm シナリオ
curl -X POST "${EC2_NR_BASE}/api/chaos/alert-storm?enable=true"
./scripts/load.sh alert-storm-alerts
# → NR APM > alert-api の Throughput スパイクを確認
curl -X POST "${EC2_NR_BASE}/api/chaos/reset"

# ⑤ Logs in Context の確認
# NR APM > トレース詳細 > Logs タブ → 1クリックでそのリクエストのログへ
```

---

## 2. カオスシナリオ クイックリファレンス

### 操作コマンド

```bash
source .env   # EC2_NR_BASE を読み込む

# Slow Query ON（5秒遅延）
curl -X POST "${EC2_NR_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"

# Slow Query OFF
curl -X POST "${EC2_NR_BASE}/api/chaos/slow-query?enable=false"

# Error Inject ON（30%）
curl -X POST "${EC2_NR_BASE}/api/chaos/error-inject?rate=30"

# Error Inject OFF
curl -X POST "${EC2_NR_BASE}/api/chaos/error-inject?rate=0"

# Alert Storm 発動
curl -X POST "${EC2_NR_BASE}/api/chaos/alert-storm?enable=true"

# 全カオスリセット
curl -X POST "${EC2_NR_BASE}/api/chaos/reset"

# 現在のカオス状態確認
curl -s "${EC2_NR_BASE}/api/chaos/state" | python3 -m json.tool
```

> ブラウザから操作する場合は `${EC2_NR_BASE}/chaos` のカオスコントロール画面を使用してください。

### シナリオ別 確認先一覧（NR）

| シナリオ | 主な確認先 | 期待する見え方 |
|---------|-----------|--------------|
| **正常時** | APM > Services | 4サービス表示、Apdex > 0.9 |
| **Slow Query** | APM > device-api > Transaction Traces | 遅いトランザクションが自動キャプチャ |
| **Slow Query** | APM > device-api > Databases | DB クエリ時間の悪化 |
| **Error Inject** | Errors Inbox | エラーが自動グルーピング |
| **Error Inject** | APM > device-api > Error rate | 設定確率に比例して上昇 |
| **Alert Storm** | APM > alert-api > Throughput | 急激なスパイク |
| **Alert Storm** | NR Logs | alert_storm ログのボリューム急増 |

---

## 3. New Relic APM 検証手順

### NR コンソール URL

| 画面 | URL |
|------|-----|
| APM Services 一覧 | https://one.newrelic.com/nr1-core?filters=domain%3DAPM |
| Kubernetes Explorer | https://one.newrelic.com/kubernetes-plugin |
| Distributed Tracing | https://one.newrelic.com/distributed-tracing |
| Errors Inbox | https://one.newrelic.com/errors-inbox |
| Logs | https://one.newrelic.com/logger |
| Alerts | https://one.newrelic.com/alerts-ai |

---

### 3-1. サービス一覧の確認

1. `one.newrelic.com` → 左ナビ **APM & Services**
2. フィルタ欄に `eks-ec2-newrelic` と入力
3. 以下の4エンティティが表示されていることを確認:
   - `netwatch-ui (eks-ec2-newrelic)`
   - `device-api (eks-ec2-newrelic)`
   - `metrics-collector (eks-ec2-newrelic)`
   - `alert-api (eks-ec2-newrelic)`
4. 各サービスの「Response time」「Error rate」「Throughput」を確認

**見えない場合の対処:**
- `make load` を実行してから2〜3分待つ
- `kubectl get pods -n eks-ec2-newrelic` で Pod が Running か確認
- `kubectl describe pod -n eks-ec2-newrelic -l app=netwatch-ui | grep newrelic` で NR init container が注入されているか確認

---

### 3-2. APM Service Map

1. APM > `netwatch-ui (eks-ec2-newrelic)` → **Service Map** タブ
2. 以下の依存グラフを確認:

```
[Browser/External] → netwatch-ui → device-api → metrics-collector
                                 ↘ alert-api
```

3. 各エッジをクリックすると Response time / Error rate / Throughput が表示される
4. 黒い矢印=正常、赤い矢印=エラー、橙=警告

---

### 3-3. Service Detail（APM Summary）

**netwatch-ui:**
- Summary タブ: Response time・Throughput・Error rate のグラフ
- Transactions タブ: エンドポイント別のレイテンシ・スループット
- **Apdex スコア:** 1.0 に近いほど良い（Slow Query 時に低下する）

**device-api:**
- Databases タブ: DB クエリの実行時間・頻度（Slow Query 時に悪化する）
- **Transaction Traces タブ:** 自動キャプチャされた遅いトランザクションの詳細

---

### 3-4. Transaction Traces（遅いトランザクションの自動キャプチャ）

NR APM は閾値を超えた遅いトランザクションを **自動的にキャプチャ**する（手動フィルタ不要）。

1. APM > `device-api (eks-ec2-newrelic)` → **Transaction Traces** タブ
2. Slow Query ON 後に `GET /devices` と `GET /devices/{id}` が自動でリストに追加される
3. トレースをクリック → Trace details ページ:
   - **Trace breakdown:** span 別の時間（DB クエリの段が長い）
   - **DB queries:** 実行された SQL と所要時間
   - **Logs tab:** そのリクエストのアプリログへのリンク（Logs in Context）

**CloudWatch App Signals との違い:**
- App Signals: X-Ray Traces を手動フィルタで探す必要がある
- NR: 閾値超過のトランザクションが自動リストアップされる

---

### 3-5. Distributed Tracing（3ホップトレース）

```
事前: ./scripts/load.sh normal-device-detail
```

1. `one.newrelic.com` → 左ナビ **Distributed Tracing**
2. フィルタ: `service.name = "netwatch-ui (eks-ec2-newrelic)"`
3. トレースを選択 → Waterfall ビューで以下を確認:

```
netwatch-ui (eks-ec2-newrelic)
├── HTTP GET /devices/TKY-CORE-001
│   └── device-api (eks-ec2-newrelic)
│       ├── db select (PostgreSQL)
│       └── HTTP GET /metrics/TKY-CORE-001
│           └── metrics-collector (eks-ec2-newrelic)
```

4. 各 span のデュレーションを確認
5. 異常 span は赤くハイライト（Error Inject 時）

---

### 3-6. Errors Inbox（エラーの自動グルーピング）

Error Inject ON 後に Errors Inbox を確認すると、エラーが自動でグルーピングされる。

1. `one.newrelic.com` → 左ナビ **Errors Inbox**
2. `device-api (eks-ec2-newrelic)` のエラーグループを確認:
   - エラーの種類・発生頻度・最初の発生日時
   - 「Assign」ボタンでチームメンバーにアサイン可能
3. エラーグループをクリック → **Occurrences** タブ:
   - スタックトレース
   - 発生時のリクエスト属性（URL、HTTP ステータス等）
4. **Distributed Tracing** タブ: そのエラーに対応するトレースに1クリックで移動

**CloudWatch App Signals との違い:**
- App Signals: X-Ray Traces を `fault = true` フィルタで手動検索する
- NR: エラーが自動グルーピングされ、発生傾向・影響度が一覧で把握できる

---

### 3-7. Slow Query 時の見え方

```bash
source .env
curl -X POST "${EC2_NR_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
./scripts/load.sh slow-query-devices
```

**[NR APM]**
1. APM > `device-api (eks-ec2-newrelic)` → Summary タブで Response time 悪化を確認
2. Transactions タブで `WebTransaction/Flask/GET /devices` の P99 が 5000ms 以上
3. **Databases タブ:** DB クエリ時間の急増を確認
4. **Transaction Traces タブ:** 遅いトランザクションが自動キャプチャされていることを確認

**[NRQL で確認]**
```sql
-- device-api の P99 レイテンシ推移
SELECT percentile(duration, 99) FROM Transaction
WHERE appName = 'device-api (eks-ec2-newrelic)'
SINCE 30 minutes ago TIMESERIES 1 minute

-- DB クエリ時間
SELECT average(databaseDuration) FROM Transaction
WHERE appName = 'device-api (eks-ec2-newrelic)'
SINCE 30 minutes ago TIMESERIES 1 minute
```

**学習ポイント（CloudWatch との比較）:**
- NR: DB クエリ時間が APM の Databases タブに自動集計される
- CW: DB クエリ時間を見るには Logs Insights でアプリログを検索する必要がある

```bash
curl -X POST "${EC2_NR_BASE}/api/chaos/reset"
```

---

### 3-8. Error Inject 時の見え方

```bash
source .env
curl -X POST "${EC2_NR_BASE}/api/chaos/error-inject?rate=30"
./scripts/load.sh error-inject-devices
```

**[NR APM]**
1. APM > `device-api (eks-ec2-newrelic)` → Error rate が約30%に上昇
2. APM > `netwatch-ui (eks-ec2-newrelic)` → Error rate も連動して上昇（エラー伝播）
3. **Errors Inbox** でエラーグループが自動作成されることを確認

**[Distributed Tracing]**
- フィルタ: `service.name = "device-api (eks-ec2-newrelic)" AND error = true`
- エラートレースを選択して span の詳細で `HTTP 500` を確認

```bash
curl -X POST "${EC2_NR_BASE}/api/chaos/reset"
```

---

### 3-9. Alert Storm 時の見え方

```bash
source .env
curl -X POST "${EC2_NR_BASE}/api/chaos/alert-storm?enable=true"
./scripts/load.sh alert-storm-alerts
```

**[NR APM]**
1. APM > `alert-api (eks-ec2-newrelic)` → Throughput スパイクを確認
2. Storm は約18秒で完了するため、グラフのスパイクを探す

**[NR Logs]**
```
フィルタ: message:"alert_storm"
```
ログボリューム急増を Time Picker で確認。

```bash
curl -X POST "${EC2_NR_BASE}/api/chaos/reset"
```

---

## 4. インフラ・コンテナ（NR Infrastructure / Kubernetes）

### 4-1. Kubernetes Explorer

1. `one.newrelic.com` → 左ナビ **Kubernetes**
2. クラスター `obs-poc` を選択
3. **Namespaces** タブ → `eks-ec2-newrelic` を選択

**確認できるもの:**
- Pod 一覧と状態（Running / Pending / Failed）
- Pod 別の CPU / Memory 使用率
- イベント（OOM Kill、再起動など）

---

### 4-2. Node / Pod メトリクス

**EC2 ノード全体:**
1. Kubernetes Explorer → **Nodes** タブ
2. ノード別の CPU / Memory を確認（CloudWatch Container Insights の EC2 ノードビューに相当）

**Pod 別:**
1. Kubernetes Explorer → `eks-ec2-newrelic` Namespace → **Pods** タブ

| Pod | 正常時 CPU | 正常時 Memory |
|-----|----------|-------------|
| netwatch-ui | < 10% | < 100MB |
| device-api | < 15% | < 150MB |
| metrics-collector | < 5% | < 80MB |
| alert-api | < 5% | < 80MB |

---

### 4-3. シナリオ別確認表（NR Infrastructure）

| シナリオ | 確認メトリクス | 場所 |
|---------|-------------|------|
| **Slow Query** | device-api Pod CPU | Kubernetes > eks-ec2-newrelic > Pods（変化少） |
| **Error Inject** | device-api Error rate | APM > device-api |
| **Alert Storm** | alert-api CPU / Memory | Kubernetes > eks-ec2-newrelic > Pods |

**NRQL でインフラメトリクスを確認:**
```sql
-- Pod CPU 使用率推移
SELECT average(cpuUsedCores) FROM K8sContainerSample
WHERE namespaceName = 'eks-ec2-newrelic'
FACET containerName
SINCE 30 minutes ago TIMESERIES 1 minute

-- Pod Memory 使用量
SELECT average(memoryUsedBytes) / 1024 / 1024 AS 'Memory (MB)' FROM K8sContainerSample
WHERE namespaceName = 'eks-ec2-newrelic'
FACET containerName
SINCE 30 minutes ago TIMESERIES 1 minute
```

---

## 5. シナリオ別 確認ガイド（詳細）

### 5-1. 正常時のベースライン

```bash
source .env
./scripts/load.sh normal-device-detail
```

**期待値（NR）:**

| 観点 | 場所 | 期待値 |
|-----|------|-------|
| netwatch-ui Response time P99 | APM > netwatch-ui | < 1000ms |
| device-api Response time P99 | APM > device-api | < 600ms |
| 全サービス Error rate | APM > Services | 0% |
| 全サービス Apdex | APM > Services | > 0.9 |

---

### 5-2. 正常時の Apdex（NR 固有の指標）

**Apdex（Application Performance Index）:** レイテンシに基づくユーザー満足度スコア（0〜1）。
- 1.0 = 全リクエストが満足閾値（T秒）以内
- 0.5〜1.0 = 許容範囲内
- < 0.5 = 要対応

```sql
-- 直近30分の Apdex 推移
SELECT apdex(duration, t:0.5) FROM Transaction
WHERE appName LIKE '%(eks-ec2-newrelic)'
FACET appName
SINCE 30 minutes ago TIMESERIES 1 minute
```

> **CloudWatch との違い:** CloudWatch App Signals に Apdex 相当の指標はない。Latency P99 を代替として使用する。

---

## 6. ログ（NR Logs + Logs in Context）

### 6-1. NR Logs の基本操作

1. `one.newrelic.com` → 左ナビ **Logs**
2. 検索バー: `namespace:eks-ec2-newrelic`
3. 時間範囲: Last 30 minutes

**よく使うフィルタ:**

```
# エラーログ
level:ERROR

# Slow Query ログ
message:"slow_query"

# Alert Storm ログ
message:"alert_storm"

# 特定サービスのログ
service.name:"device-api (eks-ec2-newrelic)"
```

---

### 6-2. Logs in Context（APM トレースからログへ）

**CloudWatch の最大の違い:** NR はトレース詳細から1クリックでそのリクエストのアプリログに移動できる。

1. APM > `device-api (eks-ec2-newrelic)` → Distributed Tracing タブ
2. Error Inject ON 時のエラートレースを選択
3. span をクリック → **Logs** タブ
4. そのトレースの `trace.id` に一致するログが自動フィルタされて表示される

**CloudWatch の対応操作（比較のため確認):**
1. X-Ray でトレースを見つけて `trace_id` をコピー
2. CloudWatch Logs Insights を開いて手動でクエリを実行:
   ```sql
   fields @timestamp, @message
   | filter @message like "1-xxxxxxxx-xxxxxxxxxxxxxxxxxxxx"
   ```

---

### 6-3. NRQL でログを集計

```sql
-- サービス別エラーログ件数
SELECT count(*) FROM Log
WHERE namespace = 'eks-ec2-newrelic' AND level = 'ERROR'
FACET service.name
SINCE 30 minutes ago TIMESERIES 1 minute

-- Alert Storm のログボリューム
SELECT count(*) FROM Log
WHERE namespace = 'eks-ec2-newrelic'
AND message LIKE '%alert_storm%'
SINCE 1 hour ago TIMESERIES 1 minute

-- Slow Query ログの確認
SELECT timestamp, message, service.name FROM Log
WHERE namespace = 'eks-ec2-newrelic'
AND message LIKE '%slow_query%'
SINCE 30 minutes ago LIMIT 20
```

---

## 7. NR Browser（ブラウザ監視）

NR Browser は CloudWatch RUM に相当するサービスで、実ユーザーのブラウザセッションを監視する。  
`netwatch-ui` Deployment の `NR_BROWSER_SNIPPET` 環境変数（Secret 経由）でスニペットが注入される。

### 7-1. 前提条件

```bash
# NR Browser snippet が Secret に登録されているか確認
kubectl get secret newrelic-secret -n eks-ec2-newrelic -o jsonpath='{.data.browser-snippet}' | base64 -d | head -3
```

出力に `<script type="text/javascript">` が含まれていれば設定済み。

### 7-2. NR Browser コンソールの確認

1. `one.newrelic.com` → 左ナビ **Browser**
2. `netwatch-ui (eks-ec2-newrelic)` アプリを選択
3. 各タブを確認:

| タブ | 確認内容 |
|------|---------|
| Summary | Page views・JS errors・Core Web Vitals の概要 |
| Page views | ページ別のロード時間・スループット |
| Core Web Vitals | LCP / FID / CLS の分布と傾向 |
| JS Errors | JavaScript エラーの一覧・スタックトレース |
| HTTP Errors | 4xx/5xx エラーのリクエスト一覧 |
| Session traces | セッション単位のイベントタイムライン |

---

### 7-3. 検証シナリオ（NR Browser）

**シナリオ 1: Slow Query 時の Page load 悪化確認**
```bash
source .env
curl -X POST "${EC2_NR_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
```
1. ブラウザで `http://localhost:8082/devices` と `/devices/TKY-CORE-001` を開く
2. NR Browser > Page views で `/devices/{id}` のロード時間悪化を確認
3. APM の Response time P99 と比較（Browser は実ブラウザ時間 / APM はサーバー処理時間）
```bash
curl -X POST "${EC2_NR_BASE}/api/chaos/reset"
```

**シナリオ 2: Error Inject 時の HTTP エラー記録**
```bash
source .env
curl -X POST "${EC2_NR_BASE}/api/chaos/error-inject?rate=30"
```
1. ブラウザで `/devices` を数回リロード
2. NR Browser > HTTP Errors で HTTP 500 が記録されているか確認
3. APM の Error rate と照合
```bash
curl -X POST "${EC2_NR_BASE}/api/chaos/reset"
```

**シナリオ 3: Distributed Tracing との連携**
1. ブラウザで `http://localhost:8082/devices/TKY-CORE-001` を開く
2. NR Browser > Session traces → セッションを選択
3. HTTPリクエスト行から Distributed Tracing へのリンクをクリック（対応している場合）

---

### 7-4. NR Browser vs CloudWatch RUM 比較

| 観点 | NR Browser | CloudWatch RUM |
|-----|-----------|---------------|
| 設定方法 | k8s Secret 経由でスニペット注入 | 環境変数 + Cognito Identity Pool |
| Core Web Vitals | ✅ LCP / FID / CLS | ✅ LCP / FID / CLS |
| Session traces | ✅ | ✅ |
| APM との連携 | APM 同一画面から Browser へ移動可 | App Signals → RUM は別途ナビゲート |
| NRQL でクエリ | ✅ PageView / JavaScriptError テーブル | ❌ CloudWatch Metrics のみ |

---

## 8. カスタムメトリクス（NR Flex）

NR Flex は設定ファイルベースでカスタムメトリクスを収集する仕組みで、DaemonSet の nri-bundle に含まれる。  
CloudWatch の StatsD カスタムメトリクスに相当する。

### 8-1. NR Flex の確認

```bash
# nri-bundle DaemonSet が動いているか確認
kubectl get pods -n newrelic -l app.kubernetes.io/name=nri-bundle
```

### 8-2. カスタムメトリクスの確認

NR Flex でアプリの HTTP エンドポイントをポーリングしてメトリクスを収集する場合、  
以下の NRQL でカスタムメトリクスを確認できる:

```sql
-- Flex で収集したカスタムメトリクス一覧
SELECT uniques(metricName) FROM Metric
WHERE instrumentation.name = 'nri-flex'
SINCE 1 hour ago

-- device-api のカスタムレイテンシ
SELECT average(netwatch.device.list_ms) FROM Metric
WHERE clusterName = 'obs-poc'
SINCE 30 minutes ago TIMESERIES 1 minute
```

---

## 9. 負荷テストガイド

### 使い方

```bash
source .env   # EC2_NR_BASE を読み込む

# NR 環境のみに負荷をかける
EC2_AS_BASE="" FARGATE_AS_BASE="" ./scripts/load.sh normal-device-detail

# 全環境に同時に負荷をかける（CW と NR を並行して比較）
make load
```

### NRQL でリアルタイム確認

負荷生成中に以下のクエリを NR に貼り付けると、リアルタイムで変化を確認できる:

```sql
-- 4サービスのスループット推移
SELECT rate(count(*), 1 minute) FROM Transaction
WHERE appName LIKE '%(eks-ec2-newrelic)'
FACET appName
SINCE 30 minutes ago TIMESERIES 1 minute

-- 4サービスの P99 レイテンシ比較
SELECT percentile(duration, 99) FROM Transaction
WHERE appName LIKE '%(eks-ec2-newrelic)'
FACET appName
SINCE 30 minutes ago TIMESERIES 1 minute
```

---

## 10. 設計チェックリスト

### APM（New Relic APM）

- [ ] 4サービスが APM に表示される（名前に `(eks-ec2-newrelic)` が含まれる）
- [ ] Service Map でサービス間の依存グラフが表示される
- [ ] 各サービスの Apdex スコアが正常時に > 0.9 であることを確認した
- [ ] Slow Query 時に device-api Response time P99 が 5000ms 以上になることを確認した
- [ ] **Transaction Traces に遅いトランザクションが自動キャプチャされることを確認した**
- [ ] Error Inject 時に device-api Error rate が設定値に比例することを確認した
- [ ] エラーが netwatch-ui 側にも伝播することを確認した

### 分散トレース（NR Distributed Tracing）

- [ ] 3ホップトレース（netwatch-ui → device-api → metrics-collector）を確認した
- [ ] Slow Query 時に device-api span が長くなることを確認した
- [ ] Error Inject 時にエラー span が確認できた

### インフラ・コンテナ（NR Infrastructure / Kubernetes）

- [ ] Kubernetes Explorer で `eks-ec2-newrelic` Namespace の Pod 一覧を確認した
- [ ] Pod 別 CPU / Memory を確認した
- [ ] Slow Query 時に device-api の CPU が上がらないことを確認した（I/O待ち）

### ログ（NR Logs）

- [ ] NR Logs で `namespace:eks-ec2-newrelic` のログを確認した
- [ ] Slow Query / Error Inject ログを検索できた
- [ ] **Logs in Context: APM トレース詳細からログに1クリックで移動できることを確認した**

### Errors Inbox

- [ ] **Error Inject 後に Errors Inbox でエラーグループが自動作成されることを確認した**
- [ ] エラーグループから Distributed Tracing へリンクできることを確認した

### NR Browser

- [ ] NR Browser コンソールで Page views・Core Web Vitals を確認した
- [ ] Slow Query 時の Page load 時間悪化を Browser で確認した
- [ ] Error Inject 時の HTTP エラーが Browser に記録されることを確認した

---

## 11. NR Alerts / Service Levels 設計イメージ

### Service Levels（SLO）設定例

NR の Service Levels は APM > 対象サービス > Service Levels から作成。

#### SLO 例 1: netwatch-ui 可用性 99.9%

```
SLI: Request success rate
条件: HTTP status code < 500
目標: 99.9%
期間: 28日間ローリング
```

#### SLO 例 2: device-api P99 Latency < 2000ms

```
SLI: Response time
条件: duration < 2.0
目標: 99%
期間: 7日間ローリング
```

---

### NR Alerts（NRQL ベース）設定例

NR のアラートは NRQL で任意の条件を直接記述できる。CloudWatch Alarms のディメンション固定の制約がない。

#### Alert 例 1: device-api Error rate > 5%

```sql
SELECT percentage(count(*), WHERE error = true) FROM Transaction
WHERE appName = 'device-api (eks-ec2-newrelic)'
```
- 条件: `> 5` (%)
- 評価期間: 5分
- 違反クローズ: 5分間条件を下回ったら

#### Alert 例 2: Apdex スコア < 0.7

```sql
SELECT apdex(duration, t:0.5) FROM Transaction
WHERE appName = 'netwatch-ui (eks-ec2-newrelic)'
```
- 条件: `< 0.7`
- 評価期間: 5分

#### Alert 例 3: Alert Storm 検知（Throughput スパイク）

```sql
SELECT rate(count(*), 1 minute) FROM Transaction
WHERE appName = 'alert-api (eks-ec2-newrelic)'
```
- 条件: `> 10` (req/min) ← 通常 < 1 なので Storm は明確に検知可能
- 評価期間: 1分

#### Alert 例 4: Pod 再起動検知（NRQL）

```sql
SELECT sum(restartCount) FROM K8sContainerSample
WHERE namespaceName = 'eks-ec2-newrelic'
```
- 条件: `> 0`
- 評価期間: 5分

---

### CloudWatch Alarms との比較

| 観点 | NR Alerts | CloudWatch Alarms |
|-----|-----------|-----------------|
| 条件記述 | NRQL（SQL ライク・自由度高） | ディメンション + 統計関数（固定形式） |
| 複合条件 | WHERE 句で任意に組み合わせ | 複数 Alarm + Composite Alarm が必要 |
| エラー rate | `percentage(count, WHERE error=true)` | Fault メトリクス + RequestCount の割り算が必要 |
| 通知 | Slack / Email / PagerDuty など | SNS 経由 |

---

*このガイドは `eks-ec2-newrelic` 環境専用の検証手順書です。他環境のガイドは [lab-eks-ec2-appsignals.md](lab-eks-ec2-appsignals.md) / [lab-eks-fargate-appsignals.md](lab-eks-fargate-appsignals.md) / [lab-eks-fargate-newrelic.md](lab-eks-fargate-newrelic.md) を参照してください。*
