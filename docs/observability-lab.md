# NetWatch Observability Lab — 環境別ガイド

> **このドキュメントについて:** 4環境の全体像と、環境ごとの入口を記載したガイドです。各環境は個別ラボファイルだけで検証を進められるようにしています。
>
> **環境構築・セットアップ手順:** [docs/setup.md](setup.md)  
> **障害対応 Runbook:** [docs/runbook.md](runbook.md)  
> **環境比較（詳細）:** [docs/environment-comparison.md](environment-comparison.md)

---

## 目次

1. [4環境マトリクス](#1-4環境マトリクス)
2. [各環境の個別ラボ](#2-各環境の個別ラボ)
3. [共通カオスシナリオ クイックリファレンス](#3-共通カオスシナリオ-クイックリファレンス)
4. [環境間比較の実施手順](#4-環境間比較の実施手順)
5. [CloudWatch RUM 検証（EC2 + App Signals）](#5-cloudwatch-rum-検証ec2--app-signals)
6. [カスタムメトリクス検証（EC2 + App Signals）](#6-カスタムメトリクス検証ec2--app-signals)
7. [NR Browser 検証（EC2 + New Relic）](#7-nr-browser-検証ec2--new-relic)
8. [カスタムメトリクス検証（EC2 + New Relic / NR Flex）](#8-カスタムメトリクス検証ec2--new-relic--nr-flex)
9. [環境別 利用可能機能まとめ](#9-環境別-利用可能機能まとめ)

---

## 1. 4環境マトリクス

| 環境 | アクセス | Namespace | 特徴 |
|------|---------|-----------|------|
| **EKS on EC2 + App Signals** | `make port-forward-ec2` → :8080 | `eks-ec2-appsignals` | フル機能 (APM / ログ / RUM / StatsD) |
| **EKS on EC2 + New Relic** | `make port-forward-newrelic` → :8082 | `eks-ec2-newrelic` | フル機能 (APM / ログ / Browser / Flex) |
| **EKS on Fargate + App Signals** | `make port-forward-fargate` → :8081 | `eks-fargate-appsignals` | Pod メトリクスのみ、StatsD 利用不可 |
| **EKS on Fargate + New Relic** | `make port-forward-fargate-newrelic` → :8083 | `eks-fargate-newrelic` | **APM のみ**（インフラ・ログ・Flex 利用不可） |

---

## 2. 各環境の個別ラボ

詳細な手順・チェックリスト・Alarm/SLO 設計例は以下の各ファイルを参照。共通準備（`make up` / `make create-secrets` / `make build-push`）が完了していれば、各ラボは単独で開始できます。

| ラボ | 対象環境 | ファイル |
|------|---------|---------|
| **EKS on EC2 + CloudWatch App Signals** | eks-ec2-appsignals | [lab-eks-ec2-appsignals.md](lab-eks-ec2-appsignals.md) |
| **EKS on EC2 + New Relic** | eks-ec2-newrelic | [lab-eks-ec2-newrelic.md](lab-eks-ec2-newrelic.md) |
| **EKS on Fargate + CloudWatch App Signals** | eks-fargate-appsignals | [lab-eks-fargate-appsignals.md](lab-eks-fargate-appsignals.md) |
| **EKS on Fargate + New Relic（APM only）** | eks-fargate-newrelic | [lab-eks-fargate-newrelic.md](lab-eks-fargate-newrelic.md) |

---

## 3. 共通カオスシナリオ クイックリファレンス

全4環境で共通のカオス API が使用できる。`BASE` を各環境のエンドポイントに置き換えて実行する。

```bash
source .env
# BASE を使いたい環境のエンドポイントに置き換える
# EC2 App Signals: BASE=${EC2_AS_BASE}
# EC2 New Relic:   BASE=${EC2_NR_BASE}
# Fargate AS:      BASE=${FARGATE_AS_BASE}
# Fargate NR:      BASE=${FARGATE_NR_BASE}

# Slow Query ON（5秒遅延）
curl -X POST "${BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"

# Error Inject ON（30%）
curl -X POST "${BASE}/api/chaos/error-inject?rate=30"

# Alert Storm
curl -X POST "${BASE}/api/chaos/alert-storm?enable=true"

# 全カオスリセット
curl -X POST "${BASE}/api/chaos/reset"

# カオス状態確認
curl -s "${BASE}/api/chaos/state" | python3 -m json.tool
```

### シナリオ別 学習ポイント

| シナリオ | CloudWatch App Signals | New Relic |
|---------|----------------------|-----------|
| **Slow Query** | X-Ray Traces で device-api span が長い。Logs Insights で `slow_query` 検索 | Transaction Traces に自動キャプチャ。Databases タブで DB クエリ時間を確認 |
| **Error Inject** | App Signals Fault rate。X-Ray `fault = true` フィルタで手動検索 | Errors Inbox で自動グルーピング。エラー伝播も Service Map で確認 |
| **Alert Storm** | App Signals > alert-api Throughput スパイク。Logs Insights でボリューム集計 | APM > alert-api Throughput。NR Logs で `message:"alert_storm"` 検索（EC2 のみ） |

---

## 4. 環境間比較の実施手順

全環境に同時に負荷をかけて、同一シナリオ下での各ツールの見え方を比較する。

```bash
source .env

# ① 全環境同時負荷（最も効率的な比較方法）
make load

# ② 特定シナリオの比較
# 全環境で同時に Slow Query を発動 → 各コンソールを並べて確認
curl -X POST "${EC2_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
curl -X POST "${EC2_NR_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
curl -X POST "${FARGATE_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
curl -X POST "${FARGATE_NR_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
make load
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"
curl -X POST "${EC2_NR_BASE}/api/chaos/reset"
curl -X POST "${FARGATE_AS_BASE}/api/chaos/reset"
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"
```

### 比較のための並列確認先

| 観点 | CloudWatch (EC2) | New Relic (EC2) |
|-----|-----------------|----------------|
| サービスマップ | App Signals > Service Map | APM > netwatch-ui > Service Map |
| レイテンシ P99 | App Signals > device-api > Latency | APM > device-api > Transactions |
| エラー | App Signals > Fault rate | Errors Inbox |
| ログ検索 | Logs Insights（CFQL） | NR Logs（全文検索） |
| トレース | X-Ray Traces（フィルタ手動） | Distributed Tracing（Errors Inbox から1クリック） |
| コンテナ監視 | Container Insights | Kubernetes Explorer |

---

## 5. CloudWatch RUM 検証（EC2 + App Signals）

CloudWatch RUM は実ブラウザのページロード・エラー・HTTP リクエストを収集する実ユーザー監視サービス。

### 5-1. 有効化

```bash
# Terraform から値を取得して .env に設定
terraform -chdir=infra/terraform output rum_app_monitor_id
terraform -chdir=infra/terraform output cognito_identity_pool_id

# .env に追記
# CW_RUM_APP_MONITOR_ID=<UUID>
# CW_RUM_IDENTITY_POOL_ID=ap-northeast-1:<UUID>
# CW_RUM_REGION=ap-northeast-1

# EC2 App Signals 環境に RUM を有効化
make ec2-appsignals-enable-rum
```

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#rum:appMonitorList

### 5-2. 動作確認

1. ブラウザで `http://localhost:8080/rum-test` を開く
2. ステータスが **ENABLED** / `✓ AwsRumClient 初期化済み` であることを確認
3. `/rum-test` の各ボタンでテレメトリを発生させる:

| ボタン | RUM コンソールの確認先 |
|--------|---------------------|
| JavaScript エラー | Errors タブ → JavaScript errors |
| HTTP エラー (404) | HTTP requests タブ → Status codes |
| カスタムイベント | Events タブ |
| リロード | Performance タブ → Page load steps |

### 5-3. 検証シナリオ

**シナリオ A: Slow Query 時の Page load 悪化確認**
```bash
source .env
curl -X POST "${EC2_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
```
1. ブラウザで `http://localhost:8080/devices` と `/devices/TKY-CORE-001` を開く
2. RUM > Performance > Page Loads で遅延が反映されているか確認
3. App Signals の Latency P99 と比較  
   → **RUM は実ブラウザ時間 / App Signals はサーバー処理時間**（両方の観点が必要な理由）
```bash
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"
```

**シナリオ B: Error Inject 時の HTTP エラー記録**
```bash
source .env
curl -X POST "${EC2_AS_BASE}/api/chaos/error-inject?rate=30"
```
1. ブラウザで `/devices` を数回リロード
2. RUM > HTTP requests > Status codes で HTTP 500 を確認
3. App Signals の Fault rate と照合
```bash
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"
```

**シナリオ C: X-Ray との連携確認**
1. ブラウザで `/devices/TKY-CORE-001` を開く
2. RUM > User sessions → セッションを選択
3. HTTP リクエスト行の **View in X-Ray** リンクをクリック
4. ブラウザ → netwatch-ui → device-api → metrics-collector の3ホップトレースを確認

### 5-4. RUM で見るべき項目

| 項目 | 場所 | PoC での確認ポイント |
|-----|------|-------------------|
| Page load 時間（ページ別） | Performance > Page Loads | `/devices/{id}` が Slow Query 時に悪化するか |
| Core Web Vitals | Performance > Page load steps | LCP / FID / CLS の計測値 |
| JS Error 件数 | Errors > JS Errors | `/rum-test` ボタンで記録されるか |
| HTTP Request エラー | HTTP requests > Status codes | Error Inject 時に HTTP 500 が記録されるか |
| X-Ray 連携 | User sessions → View in X-Ray | ブラウザ起点の分散トレースが確認できるか |

---

## 6. カスタムメトリクス検証（EC2 + App Signals）

アプリが StatsD プロトコルで送信するメトリクスを CloudWatch Agent（DaemonSet）が受信して CloudWatch Metrics に転送する。

> **制約:** StatsD は DaemonSet（HostPort 8125）を使用するため **EC2 環境のみ**。Fargate 環境では利用不可。

### 6-1. アーキテクチャ

```
App Pod
  → socket.sendto(UDP:8125) → STATSD_HOST (Node IP / Downward API)
  → CloudWatch Agent DaemonSet（各 EC2 ノード）
  → CloudWatch Metrics (namespace: NetwatchPoC/Custom)
```

### 6-2. 有効化

```bash
make ec2-appsignals-enable-custom-metrics
make load   # メトリクスを溜める
```

### 6-3. 実装済みメトリクス一覧

| サービス | メトリクス名 | タイプ | 説明 |
|---------|------------|--------|------|
| netwatch-ui | `netwatch.ui.page.dashboard_ms` | timing | ダッシュボード表示レイテンシ |
| netwatch-ui | `netwatch.ui.page.devices_ms` | timing | 機器一覧表示レイテンシ |
| netwatch-ui | `netwatch.ui.page.device_detail_ms` | timing | 機器詳細表示レイテンシ |
| netwatch-ui | `netwatch.ui.page.views` | counter | ページビュー数 |
| netwatch-ui | `netwatch.ui.error.count` | counter | 500 エラー発生数 |
| device-api | `netwatch.device.list_ms` | timing | デバイス一覧取得レイテンシ (DB込み) |
| device-api | `netwatch.device.list_count` | counter | 取得デバイス数 |
| device-api | `netwatch.device.detail_ms` | timing | デバイス詳細取得レイテンシ |
| alert-api | `netwatch.alert.list_ms` | timing | アラート一覧取得レイテンシ |
| alert-api | `netwatch.alert.list_count` | counter | 取得アラート数 |

### 6-4. CloudWatch コンソールで確認

**コンソール URL:**  
CloudWatch → Metrics → All metrics → Custom namespaces → `NetwatchPoC/Custom`

```bash
# CLI で確認
aws cloudwatch list-metrics \
  --namespace NetwatchPoC/Custom \
  --region ap-northeast-1

# 特定メトリクスの値を取得（直近10分）
aws cloudwatch get-metric-statistics \
  --namespace NetwatchPoC/Custom \
  --metric-name netwatch.ui.page.views \
  --statistics Sum \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --region ap-northeast-1
```

### 6-5. 検証シナリオ

**Slow Query との組み合わせ**
```bash
source .env
curl -X POST "${EC2_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
make load
```
1. CloudWatch Metrics で `netwatch.device.list_ms` の値が上昇することを確認
2. App Signals の device-api Latency P99 と比較  
   → **StatsD メトリクス（アプリ視点）** と **App Signals（OTel 自動計装）** の値がほぼ一致することを確認
3. **差分の意味:** StatsD はアプリコードで明示的に計測した時間 / App Signals は OTel が自動計装した時間

```bash
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"
```

**カスタムメトリクスでアラーム設定**
```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "device-api-slow-query-custom" \
  --namespace "NetwatchPoC/Custom" \
  --metric-name "netwatch.device.list_ms" \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 500 \
  --comparison-operator GreaterThanThreshold \
  --alarm-description "device-api DB query latency > 500ms (custom)" \
  --region ap-northeast-1
```

---

## 7. NR Browser 検証（EC2 + New Relic）

NR Browser は CloudWatch RUM に相当するサービスで、`NR_BROWSER_SNIPPET` 環境変数（Secret 経由）でスニペットが注入される。

> Fargate + New Relic 環境でも NR Browser は利用可能。Fargate 固有の手順は [lab-eks-fargate-newrelic.md](lab-eks-fargate-newrelic.md) を参照。

### 7-1. 前提確認

```bash
kubectl get secret newrelic-secret -n eks-ec2-newrelic \
  -o jsonpath='{.data.browser-snippet}' | base64 -d | head -3
```

`<script type="text/javascript">` が含まれていれば設定済み。

### 7-2. コンソールの確認

1. `one.newrelic.com` → 左ナビ **Browser**
2. `netwatch-ui (eks-ec2-newrelic)` を選択

| タブ | 確認内容 |
|------|---------|
| Summary | Page views・JS errors・Core Web Vitals |
| Page views | ページ別のロード時間・スループット |
| Core Web Vitals | LCP / FID / CLS の分布 |
| JS Errors | JavaScript エラー一覧 |
| HTTP Errors | 4xx/5xx リクエスト一覧 |
| Session traces | セッション単位のイベントタイムライン |

### 7-3. 検証シナリオ

**シナリオ A: Slow Query 時の Page load 悪化**
```bash
source .env
curl -X POST "${EC2_NR_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
```
1. ブラウザで `http://localhost:8082/devices` と `/devices/TKY-CORE-001` を開く
2. NR Browser > Page views でロード時間悪化を確認
3. APM の Response time P99 と比較
```bash
curl -X POST "${EC2_NR_BASE}/api/chaos/reset"
```

**シナリオ B: Error Inject 時の HTTP エラー記録**
```bash
source .env
curl -X POST "${EC2_NR_BASE}/api/chaos/error-inject?rate=30"
```
1. ブラウザで `/devices` を数回リロード
2. NR Browser > HTTP Errors で HTTP 500 を確認
3. APM の Error rate と照合
```bash
curl -X POST "${EC2_NR_BASE}/api/chaos/reset"
```

### 7-4. NR Browser vs CloudWatch RUM 比較

| 観点 | NR Browser | CloudWatch RUM |
|-----|-----------|---------------|
| 設定方法 | k8s Secret 経由でスニペット注入 | 環境変数 + Cognito Identity Pool |
| Core Web Vitals | ✅ LCP / FID / CLS | ✅ LCP / FID / CLS |
| Session traces | ✅ | ✅ |
| APM との連携 | APM 同一画面から Browser へ移動可 | App Signals → RUM は別途ナビゲート |
| NRQL でクエリ | ✅ PageView / JavaScriptError テーブル | ❌ CloudWatch Metrics のみ |
| X-Ray / DT 連携 | ✅ Session traces からトレースへ | ✅ User sessions から X-Ray へ |

---

## 8. カスタムメトリクス検証（EC2 + New Relic / NR Flex）

NR Flex は設定ファイルベースでカスタムメトリクスを収集する仕組みで、DaemonSet の nri-bundle に含まれる。CloudWatch StatsD カスタムメトリクスに相当する。

> **制約:** nri-bundle は DaemonSet のため **EC2 環境のみ**。Fargate 環境では利用不可。

### 8-1. 確認

```bash
# nri-bundle DaemonSet が動いているか確認
kubectl get pods -n newrelic -l app.kubernetes.io/name=nri-bundle
```

### 8-2. NRQL でカスタムメトリクスを確認

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

### 8-3. StatsD（CloudWatch）vs NR Flex 比較

| 観点 | CloudWatch StatsD | NR Flex |
|-----|-----------------|---------|
| 収集方式 | App → UDP 8125 → CW Agent | Flex 設定で HTTP エンドポイントをポーリング |
| コード変更 | アプリに `socket.sendto` を追加 | Flex YAML で設定、アプリ変更不要 |
| クエリ | CloudWatch Metrics + Alarms | NRQL（SQL ライクで自由度高） |
| Fargate 対応 | ❌ | ❌ |

---

## 9. 環境別 利用可能機能まとめ

| 機能 | EC2 + App Signals | EC2 + NR | Fargate + App Signals | Fargate + NR |
|-----|:----------------:|:--------:|:---------------------:|:------------:|
| APM / 分散トレース | ✅ | ✅ | ✅ | ✅ |
| サービスマップ | ✅ | ✅ | ✅ | ✅ |
| SLO 管理 | ✅ | ✅ | ✅ | ✅ |
| エラー自動グルーピング | — | ✅ Errors Inbox | — | ✅ Errors Inbox |
| 遅いTX自動キャプチャ | — | ✅ Transaction Traces | — | ✅ Transaction Traces |
| コンテナ監視（ノード） | ✅ Container Insights | ✅ K8s Explorer | ❌ | ❌ |
| コンテナ監視（Pod） | ✅ Container Insights | ✅ K8s Explorer | ✅（Pod のみ） | ❌ |
| ログ | ✅ CloudWatch Logs | ✅ NR Logs | ✅ CloudWatch Logs | ❌ |
| Logs in Context | 2ステップ（trace_id手動） | ✅ 1クリック | 2ステップ | ❌ |
| ブラウザ監視 | ✅ CloudWatch RUM | ✅ NR Browser | ✅ CloudWatch RUM | ✅ NR Browser |
| カスタムメトリクス | ✅ StatsD | ✅ NR Flex | ❌ | ❌ |
| 外形監視 | ✅ Synthetics | ✅ Synthetics（共通） | ✅ Synthetics（共通） | ✅ Synthetics（共通） |
| NRQL / 任意クエリ | — | ✅ | — | ✅ |
| アラート条件の柔軟性 | CW Alarms（ディメンション固定） | NRQL（任意条件） | CW Alarms | NRQL（任意条件） |

### 環境選択の判断フロー

```
Fargate 採用を検討している？
  ├─ YES → App Signals が主オプション（インフラ + ログ + APM 全対応）
  │         New Relic は APM のみ（インフラ・ログは CW 側で補完が必要）
  └─ NO（EC2）→ 両ツールがフル機能で比較検証可能
                 APM の操作性・ログ連携・エラー分析を4環境横断で比較する
```

---

*各環境の詳細なハンズオン手順・チェックリスト・Alarm/SLO 設計例は各ラボファイルを参照してください。*
