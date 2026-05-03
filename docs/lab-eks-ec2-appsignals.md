# ハンズオンガイド — EKS on EC2 + CloudWatch App Signals

> **対象環境:** `eks-ec2-appsignals` (EKS on EC2, ap-northeast-1)  
> **アクセス:** `make port-forward-ec2` → http://localhost:8080  
> **環境構築・セットアップ手順:** [docs/setup.md](setup.md) を参照  
> **障害対応 Runbook:** [docs/runbook.md](runbook.md) を参照  
> **環境比較:** [docs/environment-comparison.md](environment-comparison.md) を参照

---

## 目次

1. [このガイドについて（推奨実施フロー）](#1-このガイドについて推奨実施フロー)
2. [カオスシナリオ クイックリファレンス](#2-カオスシナリオ-クイックリファレンス)
3. [Application Signals 検証手順](#3-application-signals-検証手順)
4. [Container Insights / CloudWatch Metrics 確認手順](#4-container-insights--cloudwatch-metrics-確認手順)
5. [シナリオ別 確認ガイド（詳細）](#5-シナリオ別-確認ガイド詳細)
6. [CloudWatch Synthetics 外形監視](#6-cloudwatch-synthetics-外形監視)
7. [CloudWatch RUM 検証手順](#7-cloudwatch-rum-検証手順)
8. [カスタムメトリクス（StatsD）検証手順](#8-カスタムメトリクスstatsd検証手順)
9. [負荷テストガイド（scripts/load.sh）](#9-負荷テストガイドscriptsloadsh)
10. [設計チェックリスト](#10-設計チェックリスト)
11. [Alarm / SLO 設計イメージ](#11-alarm--slo-設計イメージ)

---

## 1. このガイドについて（推奨実施フロー）

### 利用可能な機能

| 機能 | 提供サービス | 状態 |
|------|------------|------|
| APM / 分散トレース | Application Signals + X-Ray | ✅ |
| サービスマップ | Application Signals | ✅ |
| SLO管理 | Application Signals SLOs | ✅ |
| コンテナ監視 | Container Insights | ✅ |
| ログ | CloudWatch Logs (Fluent Bit DaemonSet) | ✅ |
| 外形監視 | CloudWatch Synthetics | ✅ |
| 実ユーザー監視 | CloudWatch RUM | ✅ (要有効化) |
| カスタムメトリクス | StatsD → CloudWatch (DaemonSet経由) | ✅ (要有効化) |

### 学習目的の全体像

| 目的 | 対応する機能 | 習得できること |
|------|------------|---------------|
| APMの基本を身につける | Application Signals | サービスマップ・レイテンシ・エラー率・SLO定義・トレース読み方 |
| インフラ・コンテナ監視を学ぶ | Container Insights | EKS ノード・Pod の CPU/Memory・ネットワーク・再起動回数 |
| アプリログの活用を学ぶ | CloudWatch Logs | 構造化 JSON ログのクエリ・障害原因特定 |
| 外形監視を体験する | Synthetics | ユーザー視点のエンドポイント死活・応答時間監視 |
| 実ユーザー体感を測る | CloudWatch RUM | ページロード時間・Core Web Vitals・JS エラー・セッション分析 |
| 独自メトリクスを収集する | カスタムメトリクス (StatsD) | アプリ固有指標の CloudWatch 転送・アラーム設定 |
| 障害の一次切り分けを練習する | 全ツール組み合わせ | Tier1（外形）→ Tier2（APM）→ Tier3（ログ）の流れ |

### Tier 別の一次切り分け

```
Tier 1 (外形監視)    : Synthetics Canary が FAIL → サービス全体に影響あり
Tier 2 (APM)        : Application Signals でどのサービス・オペレーションが問題か特定
Tier 3 (ログ)        : CloudWatch Logs でエラーの根本原因（SQL遅延・スタックトレース）を確認
```

### 推奨実施フロー

```bash
# 事前: port-forward で環境にアクセスできることを確認
make port-forward-ec2   # 別ターミナルで実行。http://localhost:8080

source .env

# ① ベースライン確認（正常時の数値を把握）
./scripts/load.sh normal-device-detail
# → Application Signals で4サービス表示、Service Map で3段構造を確認

# ② Slow Query シナリオ
curl -X POST "${EC2_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
./scripts/load.sh slow-query-devices
# → App Signals で device-api Latency P99 急上昇、X-Ray で device-api span が長い
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"

# ③ Error Inject シナリオ
curl -X POST "${EC2_AS_BASE}/api/chaos/error-inject?rate=30"
./scripts/load.sh error-inject-devices
# → App Signals で device-api Fault rate ≈30%、netwatch-ui にも伝播
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"

# ④ Alert Storm シナリオ
curl -X POST "${EC2_AS_BASE}/api/chaos/alert-storm?enable=true"
./scripts/load.sh alert-storm-alerts
# → alert-api Throughput 急増、Logs でボリューム急増
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"

# ⑤ Synthetics（外形監視と内部監視の組み合わせ）
aws synthetics start-canary --name obs-poc-health-check --region ap-northeast-1
curl -X POST "${EC2_AS_BASE}/api/chaos/error-inject?rate=80"
# → Canary FAIL を確認
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"
aws synthetics stop-canary --name obs-poc-health-check --region ap-northeast-1

# ⑥ RUM（実ユーザー監視）
make ec2-appsignals-enable-rum
# → ブラウザで /rum-test を開き RUM データを確認

# ⑦ カスタムメトリクス（StatsD）
make ec2-appsignals-enable-custom-metrics
make load
# → CloudWatch Metrics > NetwatchPoC/Custom でメトリクスを確認
```

---

## 2. カオスシナリオ クイックリファレンス

### 操作コマンド

```bash
source .env   # EC2_AS_BASE を読み込む

# Slow Query ON（5秒遅延）
curl -X POST "${EC2_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"

# Slow Query OFF
curl -X POST "${EC2_AS_BASE}/api/chaos/slow-query?enable=false&duration_ms=3000"

# Error Inject ON（30%）
curl -X POST "${EC2_AS_BASE}/api/chaos/error-inject?rate=30"

# Error Inject OFF
curl -X POST "${EC2_AS_BASE}/api/chaos/error-inject?rate=0"

# Alert Storm 発動（60件を0.3秒間隔で生成、約18秒で完了）
curl -X POST "${EC2_AS_BASE}/api/chaos/alert-storm?enable=true"

# 全カオスリセット
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"

# 現在のカオス状態確認
curl -s "${EC2_AS_BASE}/api/chaos/state" | python3 -m json.tool
```

> ブラウザから操作する場合は `${EC2_AS_BASE}/chaos` のカオスコントロール画面を使用してください。

### シナリオ別 確認先一覧

| シナリオ | 主な確認先 | 期待する見え方 |
|---------|-----------|--------------|
| **正常時** | App Signals > Services / Service Map | 4サービス表示、3段グラフ、全 Fault rate = 0% |
| **Slow Query** | App Signals > device-api > Latency P99 | 5000ms 以上に急増 |
| **Slow Query** | X-Ray > Traces > device-api span | span duration が 5秒以上 |
| **Slow Query** | Logs Insights: `filter @message like "slow_query"` | `event: slow_query`, `sleep_ms: 5000` |
| **Error Inject** | App Signals > device-api > Fault rate | 設定確率に比例して上昇（例: 30%設定 → 約30%） |
| **Error Inject** | App Signals > netwatch-ui > Fault rate | device-api と連動して上昇（エラー伝播） |
| **Error Inject** | X-Ray > Traces > `fault = true` | エラー span（赤）の詳細で HTTP 500 を確認 |
| **Alert Storm** | App Signals > alert-api > Throughput | 急激なスパイク（通常 < 1 req/s → Storm 中: ~3-5 req/s） |
| **Alert Storm** | Logs Insights: `stats count(*) by bin(1m)` | ログ件数が Storm 中に急増 |

---

## 3. Application Signals 検証手順

### 前提

```bash
make port-forward-ec2   # 別ターミナルで起動済みであること
source .env
make load               # トレース・メトリクスが出ていない場合は先に負荷生成
```

---

### 3-1. サービス一覧の確認

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:services

**手順:**
1. 上記 URL を開く
2. 以下の4サービスが表示されていることを確認:
   - `netwatch-ui`
   - `device-api`
   - `metrics-collector`
   - `alert-api`
3. 各サービスの「P99 Latency」「Error rate」「Request count」列を確認
4. Environment 列が `eks-ec2-appsignals` であることを確認

**見えない場合の対処:**
- `make load` を実行してから2〜3分待つ
- `kubectl get pods -n eks-ec2-appsignals` で Pod が Running か確認
- `kubectl describe pod -n eks-ec2-appsignals -l app=netwatch-ui | grep -i otel` で OTel init container が注入されているか確認

---

### 3-2. Service Map（3段の依存グラフ）

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:map

**確認ポイント:**
```
[Internet/Client] → netwatch-ui → device-api → metrics-collector
                                ↘ alert-api
```

1. 各エッジ（矢印）にホバーすると「Latency P99」「Error rate」「Request count」が表示される
2. ノードの色でヘルス状態を確認（緑=正常、黄=警告、赤=エラー）
3. 右上の時間範囲を「Last 1 hour」に設定する

---

### 3-3. Service Detail（各サービスの詳細）

**netwatch-ui:**
- Operations タブ: `GET /`, `GET /devices`, `GET /devices/{device_id}`, `GET /alerts` の各エンドポイント別メトリクス
- Dependencies タブ: `device-api` と `alert-api` が下流として表示されることを確認

**device-api:**
- Operations タブ: `GET /devices`, `GET /devices/{device_id}`, `POST /chaos/*`
- Dependencies タブ: `metrics-collector` が下流として表示されることを確認

**metrics-collector:**
- Operations タブ: `GET /metrics/{device_id}`（device-api からのみ呼ばれる）

**alert-api:**
- Operations タブ: `GET /alerts`（Alert Storm 中は Throughput が急増する）

---

### 3-4. Operation別 Latency（P50 / P90 / P99）

1. Services → `device-api` → Operations タブ
2. `GET /devices/{device_id}` 行をクリック
3. Latency グラフで P50 / P90 / P99 の各パーセンタイルを確認

**正常時の目安:**

| Operation | P50 | P90 | P99 |
|-----------|-----|-----|-----|
| `GET /devices` | < 100ms | < 200ms | < 500ms |
| `GET /devices/{id}` | < 150ms | < 300ms | < 600ms |
| `GET /alerts` | < 50ms | < 100ms | < 200ms |

---

### 3-5. Error rate / Fault rate

- **Error rate:** クライアントエラー（4xx）の割合
- **Fault rate:** サーバーエラー（5xx）の割合。Error Inject シナリオで上昇する

1. Services → `device-api` → Overview タブの「Fault rate」グラフを確認
2. Error Inject ON 時は Fault rate が設定値に比例する（例: 30% → 約30%）
3. `netwatch-ui` の Fault rate も上昇していることを確認（下流エラーの伝播）

---

### 3-6. Trace 一覧・Trace 詳細

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#xray:traces/query

**フィルタ例:**

```
# 全トレース
service("netwatch-ui")

# エラートレース
service("device-api") AND fault = true

# 遅いトレース（2秒以上）
service("device-api") AND duration > 2
```

---

### 3-7. 3ホップトレースの読み方

**前提:** `./scripts/load.sh normal-device-detail` を実行してトレースを生成する

1. X-Ray Traces でトレース一覧を開く
2. `GET /devices/TKY-CORE-001` に対応するトレースをクリック
3. Trace Map で以下の span 構造を確認:

```
netwatch-ui (全体 duration)
├── HTTP GET /devices/TKY-CORE-001        ... Span A（netwatch-ui）
│   └── device-api (Span B)
│       ├── SELECT FROM devices WHERE ... （DB クエリ、トレース外）
│       └── HTTP GET /metrics/TKY-CORE-001
│           └── metrics-collector (Span C)
```

4. 各 span の「Start time」と「Duration」を確認
5. **Span B の duration が長い場合** → DB または metrics-collector に問題あり
6. **Span C の duration が長い場合** → metrics-collector 自体に問題あり
7. **Slow Query シナリオでは Span B が 5秒以上になり、Span C は短いまま** → DB 起因と判断できる

---

### 3-8. Slow Query 時の見え方

**事前準備:**
```bash
source .env
curl -X POST "${EC2_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
./scripts/load.sh slow-query-devices
```

**Application Signals での確認:**
1. Services → `device-api` → Operations タブ
2. `GET /devices` と `GET /devices/{device_id}` の P99 Latency が 5000ms 以上になることを確認
3. Services → `netwatch-ui` → Operations タブ
4. `/devices` と `/devices/{id}` のレイテンシも上昇していることを確認（エンドツーエンドの遅延伝播）

**注目ポイント:**
- Service Map で `device-api` ノードの色が変化するか確認
- Trace Map で device-api span は長いが、metrics-collector span は短いまま → DB 待ちが原因と特定できる

---

### 3-9. Error Inject 時の見え方

**事前準備:**
```bash
source .env
curl -X POST "${EC2_AS_BASE}/api/chaos/error-inject?rate=30"
./scripts/load.sh error-inject-devices
```

**Application Signals での確認:**
1. Services → `device-api` → Overview タブの「Fault rate」グラフで約30%のエラー率を確認
2. Services → `netwatch-ui` → Overview タブで **Fault rate が device-api に連動して上昇** することを確認（エラー伝播）
3. X-Ray Traces: `service("device-api") AND fault = true`
4. エラートレースをクリックして span の詳細で `HTTP 500` を確認

---

### 3-10. Alert Storm 時の見え方

**事前準備:**
```bash
source .env
curl -X POST "${EC2_AS_BASE}/api/chaos/alert-storm?enable=true"
./scripts/load.sh alert-storm-alerts
```

**Application Signals での確認:**
1. Services → `alert-api` → Overview タブの「Request count」グラフで急増を確認
2. Storm は約18秒（60件 × 0.3秒間隔）で完了するため、グラフのスパイクを探す
3. Throughput: 通常 < 1 req/s → Storm 中: ~3-5 req/s
4. Latency は変化が少ない（in-memory 処理のため）

---

## 4. Container Insights / CloudWatch Metrics 確認手順

### 推奨確認順序

```
1. Container Insights（EKS全体・Node・Pod の状態を俯瞰）
       ↓
2. Application Signals Metrics（どのサービスのどのオペレーションに問題か）
       ↓
3. X-Ray Traces（問題のあるリクエストのトレース詳細）
       ↓
4. CloudWatch Logs（根本原因のログを確認）
```

---

### 4-1. Container Insights の確認

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#container-insights:performance

**EKS Cluster 全体:**
1. ドロップダウンで「EKS Clusters」→ `obs-poc` を選択
2. Node CPU 使用率（t3.small は 2vCPU。全体で60%超えたら注意）
3. Node Memory 使用率（t3.small は 2GB。全体で80%超えたら注意）

**Pod 別:**
1. 「EKS Pods」ビューに切り替え
2. Namespace: `eks-ec2-appsignals` でフィルタ

| Pod | 正常時 CPU | 正常時 Memory | 異常時の兆候 |
|-----|----------|-------------|------------|
| netwatch-ui | < 10% | < 100MB | Error Inject 時に若干上昇 |
| device-api | < 15% | < 150MB | Slow Query 時は I/O 待ちのため変化少 |
| metrics-collector | < 5% | < 80MB | — |
| alert-api | < 5% | < 80MB | Alert Storm 時にメモリ一時上昇 |

**Pod 再起動回数:**
- 「EKS Pods」ビューで「Restart count」列を確認
- 0 であることを確認（OOM Kill や Liveness Probe 失敗時に増加）

---

### 4-2. Application Signals Metrics（CloudWatch Metrics から直接参照）

**Namespace:** `ApplicationSignals/OperationMetrics`

| メトリクス名 | ディメンション | 説明 |
|------------|-------------|------|
| `Latency` | Service, Operation, Environment | レイテンシ（統計: p50/p90/p99 を使用）|
| `Error` | Service, Operation, Environment | 4xx エラーカウント |
| `Fault` | Service, Operation, Environment | 5xx エラーカウント |
| `RequestCount` | Service, Operation, Environment | リクエスト数 |

---

### 4-3. シナリオ別確認表

| シナリオ | 確認メトリクス | 場所 | 期待される変化 |
|---------|-------------|------|--------------|
| **正常時** | device-api Latency P99 | App Signals > device-api | < 500ms |
| **正常時** | 全サービス Fault rate | App Signals > Services | 0% |
| **Slow Query** | device-api Latency P99 | App Signals > device-api | 5000ms 以上 |
| **Slow Query** | device-api CPU | Container Insights > EKS Pods | 変化少（I/O待ち）← ポイント |
| **Error Inject** | device-api Fault rate | App Signals > device-api | 設定確率に比例 |
| **Error Inject** | netwatch-ui Fault rate | App Signals > netwatch-ui | device-api と連動 |
| **Alert Storm** | alert-api RequestCount | App Signals > alert-api | 急激なスパイク |
| **Alert Storm** | alert-api Memory | Container Insights | 一時的な上昇 |

---

## 5. シナリオ別 確認ガイド（詳細）

### 5-1. 正常時のベースライン

**目的:** 障害発生時の比較基準を把握する。最初の検証前にスクリーンショットを撮っておくと比較が容易になる。

```bash
source .env
./scripts/load.sh normal-device-detail
```

**期待値:**

| 観点 | 場所 | 期待値 |
|-----|------|-------|
| netwatch-ui P99 Latency | App Signals > netwatch-ui | < 1000ms |
| device-api P99 Latency | App Signals > device-api | < 600ms |
| metrics-collector P99 Latency | App Signals > metrics-collector | < 200ms |
| alert-api P99 Latency | App Signals > alert-api | < 200ms |
| 全サービス Fault rate | App Signals > Services | 0% |
| 3ホップトレース全体 duration | X-Ray Traces | < 1000ms |

---

### 5-2. Slow Query 検証

**想定する障害:** DB のインデックス漏れ・フルスキャン・ロック待ちによる応答遅延

```bash
source .env
curl -X POST "${EC2_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
./scripts/load.sh slow-query-devices
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"
```

**[Application Signals]**
1. Services → `device-api` → Latency P99 が 5000ms 以上
2. Operations タブで `GET /devices` と `GET /devices/{device_id}` 両方が遅いことを確認
3. Services → `netwatch-ui` → レイテンシも上昇（エンドツーエンドの遅延伝播）

**[X-Ray Traces]**
```
フィルタ: service("device-api") AND duration > 2
```
- Trace Map で device-api span が 5秒以上になっていることを確認
- metrics-collector span は短いまま → DB 待ちが原因と判断できる

**[CloudWatch Logs Insights]**
```sql
fields @timestamp, @message
| filter @message like "slow_query"
| sort @timestamp desc
| limit 20
```
`event: slow_query`, `sleep_ms: 5000`, `endpoint: /devices` のログを確認。

**[Container Insights]**
- device-api Pod の CPU が**低いまま**であることを確認
- **学習ポイント:** CPU は正常なのにレイテンシが悪化 → Container Insights だけでは検知できない。Application Signals の Latency から入り Trace → Logs で原因を特定する流れを体験する

---

### 5-3. Error Inject 検証

**想定する障害:** 依存サービスの断続的なエラー・エラーバジェット消費

```bash
source .env
curl -X POST "${EC2_AS_BASE}/api/chaos/error-inject?rate=30"
./scripts/load.sh error-inject-devices
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"
```

**[Application Signals]**
1. Services → `device-api` → Fault rate が約30%に上昇
2. Services → `netwatch-ui` → Fault rate も上昇（エラー伝播）

**[X-Ray Traces]**
```
フィルタ: service("device-api") AND fault = true
```
- エラートレースを選択して Trace Map で赤い span を確認
- span の詳細で `HTTP 500` を確認

**[CloudWatch Logs Insights]**
```sql
fields @timestamp, @message
| filter @message like "error_injected"
| sort @timestamp desc
| limit 30
```
`event: error_injected`, `error_rate: 30` のログを確認。

**学習ポイント:**
- `error_injected` ログは device-api に集中するが、netwatch-ui の Fault rate も上昇 → Application Signals で **上流サービスから見た影響** を確認できる
- Trace を見ることで「どのサービスが起点のエラーか」を特定する手順を体験する

---

### 5-4. Alert Storm 検証

**想定する障害:** イベント洪水・モニタリングシステム自体への過負荷

```bash
source .env
curl -X POST "${EC2_AS_BASE}/api/chaos/alert-storm?enable=true"
./scripts/load.sh alert-storm-alerts
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"
```

**[Application Signals]**
1. Services → `alert-api` → Overview タブの RequestCount / Throughput で急増スパイクを確認
2. Storm は約18秒で完了するため、1分足で見ると目立つスパイクになる

**[CloudWatch Logs Insights — ボリューム急増]**
```sql
fields @timestamp, @message
| filter @message like "alert_storm"
| stats count(*) by bin(1m)
```
1分ごとのログ件数が Storm 中に急増することを確認。

```sql
fields @timestamp, @message
| filter @message like "chaos_alert_storm"
| sort @timestamp asc
| limit 10
```
`chaos_alert_storm_start` → `alert_storm` × 60件 → `chaos_alert_storm_stop` の流れを確認。

**[Container Insights]**
- Container Insights > EKS Pods > `alert-api`
- Alert Storm 中に CPU・Memory が一時的に上昇し、Storm 終了後に正常に戻ることを確認
- Pod 再起動が発生していないことを確認

---

### 5-5. 3ホップトレースの確認

**目的:** 分散トレースの親子関係（netwatch-ui → device-api → metrics-collector）を理解する

```bash
source .env
./scripts/load.sh normal-device-detail
```

**X-Ray での確認:**
1. X-Ray > Traces を開く
2. フィルタ: `service("netwatch-ui") AND url CONTAINS "/devices/"`
3. トレースを1件開く → Trace Map で3段のスパンを確認
4. span 別の duration を確認：どのホップで時間がかかっているか

---

## 6. CloudWatch Synthetics 外形監視

### 6-1. Canary の仕様

1本の Canary（`obs-poc-health-check`）が4エンドポイントを順番にチェックします。

| エンドポイント | チェック内容 | 期待ステータス | キーワード |
|-------------|-----------|-------------|---------|
| `/` | ダッシュボード表示 | HTTP 200 | `NetWatch` |
| `/devices` | 機器一覧表示 | HTTP 200 | `devices` |
| `/devices/TKY-CORE-001` | 機器詳細（3ホップトレース起点） | HTTP 200 | `TKY-CORE-001` |
| `/alerts` | アラート一覧表示 | HTTP 200 | `alerts` |

- **実行頻度:** rate(5 minutes)（デフォルト停止）
- **アーティファクト保存:** S3バケット `obs-poc-synthetics-<account_id>`

---

### 6-2. Canary 管理手順

```bash
# 開始（PoC 実施時のみ。コスト節約のため不要時は停止）
aws synthetics start-canary --name obs-poc-health-check --region ap-northeast-1

# 状態確認
aws synthetics get-canary \
  --name obs-poc-health-check --region ap-northeast-1 \
  --query 'Canary.Status.State'

# 停止（必ず停止してから撤収）
aws synthetics stop-canary --name obs-poc-health-check --region ap-northeast-1

# 最新実行結果
aws synthetics get-canary-runs \
  --name obs-poc-health-check --region ap-northeast-1 \
  --query 'CanaryRuns[0]'
```

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#synthetics:canary/list

---

### 6-3. シナリオ別の Canary 挙動

| カオス状態 | Canary の挙動 | 学習ポイント |
|-----------|-------------|-----------|
| **正常時** | 全エンドポイントが PASS | Availability 100% を確認 |
| **Slow Query (5秒)** | HTTP 200 → **PASS だが Duration が悪化** | 遅くても死活は PASS → Latency は App Signals で検知 |
| **Error Inject 30%** | 確率的に FAIL / PASS が混在 | SuccessPercent が 100% 未満に |
| **Error Inject 50%+** | 高確率で FAIL → Alarm 発火 | Alarm コンソールで ALARM 状態を確認 |
| **Alert Storm** | `/alerts` は HTTP 200 → **PASS** | アラート洪水は Canary では検知できない |

**重要な学習ポイント:**
- Slow Query は「HTTP 200 が返る」ので Canary は PASS。**ユーザーが遅さを感じていても Canary は PASS** → Application Signals の Latency メトリクスで検知が必要
- この組み合わせが「外形監視 + APM」を使う理由

---

### 6-4. Synthetics vs Application Signals の使い分け

| 観点 | Synthetics | Application Signals |
|-----|-----------|-------------------|
| 視点 | 外部ユーザー視点 | サービス内部視点 |
| 最初に見る場面 | 問題があるかどうかを確認 | 問題の原因を特定 |
| Slow Query 検知 | Duration 悪化（PASS） | Latency P99 悪化として明確に検知 |
| Error Inject 検知 | FAIL（HTTP 500）→ Alarm | Fault rate 上昇・Trace でエラー span 確認 |
| 主な用途 | 24/365 外形死活・SLA 計測 | 障害のドリルダウン・根本原因特定 |

---

## 7. CloudWatch RUM 検証手順

CloudWatch RUM（Real User Monitoring）は、実際のブラウザセッションのパフォーマンス・エラー・HTTP リクエストを収集するサービスです。

### アーキテクチャ

```
Browser
  → JS snippet (AwsRumClient) が自動ロード
  → ページロード / エラー / fetch を検知
  → Cognito Identity Pool で認証（匿名）
  → CloudWatch RUM データプレーン (dataplane.rum.ap-northeast-1.amazonaws.com)
  → CloudWatch RUM コンソール
```

---

### 7-1. 有効化手順

```bash
# Terraform から値を取得
terraform -chdir=infra/terraform output rum_app_monitor_id
terraform -chdir=infra/terraform output cognito_identity_pool_id

# .env に追記
# CW_RUM_APP_MONITOR_ID=<UUID>
# CW_RUM_IDENTITY_POOL_ID=ap-northeast-1:<UUID>
# CW_RUM_REGION=ap-northeast-1

# RUM 有効化（netwatch-ui をロールアウト再起動）
make ec2-appsignals-enable-rum
```

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#rum:appMonitorList

---

### 7-2. 動作確認

1. ブラウザで `http://localhost:8080/rum-test` を開く（サイドバーの **RUM Test** リンク）
2. ステータスが **ENABLED** / `✓ AwsRumClient 初期化済み` であることを確認
3. 各ボタンでテレメトリを発生させ、CloudWatch RUM コンソールで確認:

| ボタン | 発生するテレメトリ | RUM コンソールの確認先 |
|--------|-----------------|---------------------|
| JavaScript エラー | `window.onerror` | Errors タブ → JavaScript errors |
| HTTP エラー (404) | `fetch /api/devices/NONEXISTENT` | HTTP requests タブ → Status codes |
| カスタムイベント | `cwr('recordEvent', ...)` | Events タブ |
| リロード | LCP / FID / CLS | Performance タブ → Page load steps |

---

### 7-3. CloudWatch RUM コンソールで見るべき項目

**Performance タブ:**
- **Page load steps**: DNS lookup / TCP connection / TLS / TTFB / FCP / LCP の分解
- Core Web Vitals（LCP / FID / CLS）の分布
- ページ別の応答時間（`/devices/{id}` が Slow Query 時に悪化するか確認）

**Errors タブ:**
- JavaScript errors: スタックトレース付きで記録される
- HTTP errors: 4xx/5xx レスポンスの一覧

**HTTP requests タブ:**
- 各エンドポイントへのリクエスト数・エラー率・レイテンシ

**User sessions タブ:**
- セッション単位のイベントタイムライン
- X-Ray トレースへのリンク（`enableXRay: true` の効果）

---

### 7-4. 検証シナリオ（RUM）

**シナリオ 1: Slow Query 時の Page load 悪化確認**
```bash
source .env
curl -X POST "${EC2_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
```
1. ブラウザで `http://localhost:8080/devices` と `/devices/TKY-CORE-001` を開く
2. RUM の Page load 時間グラフで遅延が反映されているか確認
3. Application Signals の Latency P99 と比較（RUM は実ブラウザ時間 / App Signals はサーバー処理時間）
```bash
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"
```

**シナリオ 2: Error Inject 時の HTTP エラー記録**
```bash
source .env
curl -X POST "${EC2_AS_BASE}/api/chaos/error-inject?rate=30"
```
1. ブラウザで `/devices` を数回リロード
2. RUM > HTTP requests > Status codes で HTTP 500 が記録されているか確認
3. Application Signals の Fault rate と照合
```bash
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"
```

**シナリオ 3: X-Ray との連携確認**
1. ブラウザで `http://localhost:8080/devices/TKY-CORE-001` を開く
2. RUM コンソール > User sessions → セッションを選択
3. HTTP リクエスト行の「View in X-Ray」リンクをクリック
4. ブラウザ → netwatch-ui → device-api → metrics-collector の 3 ホップトレースを確認

---

### 7-5. RUM → App Signals → Traces → Logs の連携フロー

RUM（ユーザー視点）→ App Signals（サービス視点）→ Traces（リクエスト視点）→ Logs（コード視点）:

1. **RUM でエラーを確認:** HTTP Errors のタイムスタンプをメモ
2. **App Signals で照合:** Services → `device-api` → 同じ時刻の Fault rate を確認
3. **X-Ray Traces で確認:**
   ```
   service("device-api") AND fault = true
   ```
4. **ログで根本原因確認:**
   ```sql
   fields @timestamp, @message
   | filter @timestamp between <RUMエラー時刻 - 30s> and <RUMエラー時刻 + 30s>
   | filter @message like "error"
   | sort @timestamp asc
   ```

---

### 7-6. トラブルシューティング（RUM）

| 症状 | 確認箇所 |
|------|---------|
| `✗ AwsRumClient 未検出` | ブラウザの Network タブで `cwr.js` のロードを確認 |
| CORS エラー | Cognito Identity Pool の認証プロバイダーに RUM のドメインが含まれているか |
| RUM データが届かない | CloudWatch コンソールで App Monitor の Status が Active か確認 |
| `CW_RUM_APP_MONITOR_ID` 未設定 | `kubectl exec deploy/netwatch-ui -n eks-ec2-appsignals -- env \| grep CW_RUM` |

---

## 8. カスタムメトリクス（StatsD）検証手順

アプリケーションが StatsD プロトコルで送信するメトリクスを CloudWatch Agent（DaemonSet）が受信し、CloudWatch Metrics に転送します。

### アーキテクチャ

```
App Pod
  → socket.sendto(UDP:8125) → STATSD_HOST (Node IP)
  → CloudWatch Agent (DaemonSet, 各 EC2 ノードに1つ)
  → CloudWatch Metrics (namespace: NetwatchPoC/Custom)
  → CloudWatch コンソール / アラーム / ダッシュボード
```

> **Fargate では利用不可:** DaemonSet は Fargate で動作しないため、StatsD 経由のカスタムメトリクスは EC2 環境専用です。

---

### 8-1. 実装済みメトリクス一覧

**netwatch-ui (`netwatch.ui.*`)**

| メトリクス | タイプ | 説明 |
|------------|--------|------|
| `page.dashboard_ms` | timing | ダッシュボード表示レイテンシ |
| `page.devices_ms` | timing | 機器一覧表示レイテンシ |
| `page.device_detail_ms` | timing | 機器詳細表示レイテンシ |
| `page.alerts_ms` | timing | アラート一覧表示レイテンシ |
| `page.views` | counter | ページビュー数 |
| `error.count` | counter | 500 エラー発生数 |

**device-api (`netwatch.device.*`)**

| メトリクス | タイプ | 説明 |
|------------|--------|------|
| `list_ms` | timing | デバイス一覧取得レイテンシ (DB込み) |
| `list_count` | counter | 取得デバイス数 |
| `detail_ms` | timing | デバイス詳細取得レイテンシ |

**alert-api (`netwatch.alert.*`)**

| メトリクス | タイプ | 説明 |
|------------|--------|------|
| `list_ms` | timing | アラート一覧取得レイテンシ |
| `list_count` | counter | 取得アラート数 |

---

### 8-2. 有効化手順

```bash
make ec2-appsignals-enable-custom-metrics
```

これにより:
1. CloudWatch Agent に StatsD リスナー (UDP 8125) の設定を追加
2. Agent を再起動してポートを開放

**確認:**
```bash
# Agent が StatsD を開放しているか確認
kubectl exec -n amazon-cloudwatch \
  $(kubectl get pods -n amazon-cloudwatch -l app.kubernetes.io/name=cloudwatch-agent -o jsonpath='{.items[0].metadata.name}') \
  -- ss -ulnp | grep 8125
```

---

### 8-3. テスト送信

```bash
# netwatch-ui pod から STATSD_HOST と PORT を確認
kubectl exec deploy/netwatch-ui -n eks-ec2-appsignals -- env | grep STATSD

# 手動で UDP パケットを送信してテスト
kubectl exec -n eks-ec2-appsignals deploy/netwatch-ui -- python3 -c "
import socket, os
host = os.getenv('STATSD_HOST', 'localhost')
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b'netwatch.ui.test_counter:1|c', (host, 8125))
s.sendto(b'netwatch.ui.test_timing:150|ms', (host, 8125))
print(f'Sent to {host}:8125')
"
```

---

### 8-4. CloudWatch Metrics での確認

```bash
# CLI でメトリクス一覧
aws cloudwatch list-metrics \
  --namespace NetwatchPoC/Custom \
  --region ap-northeast-1

# 直近10分の値を取得
aws cloudwatch get-metric-statistics \
  --namespace NetwatchPoC/Custom \
  --metric-name netwatch.ui.page.views \
  --statistics Sum \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --region ap-northeast-1
```

**コンソール:** CloudWatch → **Metrics → All metrics → Custom namespaces → NetwatchPoC/Custom**

---

### 8-5. Chaos との組み合わせ

**Slow Query + カスタムメトリクスの比較:**

```bash
source .env

# Slow Query ON
curl -X POST "${EC2_AS_BASE}/api/chaos/slow-query?enable=true&duration_ms=3000"

# 負荷生成
ROUNDS=5 ./scripts/load.sh slow-query-devices

# CloudWatch Metrics で netwatch.device.list_ms の値が上昇することを確認
aws cloudwatch get-metric-statistics \
  --namespace NetwatchPoC/Custom \
  --metric-name "netwatch.device.list_ms" \
  --statistics Average Maximum \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --region ap-northeast-1

curl -X POST "${EC2_AS_BASE}/api/chaos/reset"
```

**学習ポイント:**
- `netwatch.device.list_ms`（StatsD: アプリ側計測）と App Signals Latency P99（OTel: フレームワーク側計測）を並べて比較
- 両者が同様の傾向を示すことを確認 → どちらの計装を使うかの判断材料になる

---

### 8-6. トラブルシューティング（カスタムメトリクス）

| 症状 | 確認箇所 |
|------|---------|
| メトリクスが届かない | `kubectl get pods -n amazon-cloudwatch` で Agent が Running か確認 |
| `STATSD_HOST` が `localhost` になっている | Pod spec の `status.hostIP` fieldRef が設定されているか確認 |
| Agent が StatsD ポートを開放していない | `kubectl exec -n amazon-cloudwatch <cw-agent-pod> -- ss -ulnp \| grep 8125` |
| CloudWatchAgent CR が見つからない | `enable-custom-metrics.sh` の ConfigMap fallback が実行されているか確認 |

---

## 9. 負荷テストガイド（scripts/load.sh）

### 使い方

```bash
source .env   # EC2_AS_BASE を読み込む

# ── 正常時 ──────────────────────────────────────────────────────
make load                               # 全シナリオ（デフォルト）
./scripts/load.sh normal-device-detail  # 機器詳細 7件（3ホップトレース生成）
./scripts/load.sh normal-devices        # 機器一覧（フィルタ各種）
./scripts/load.sh normal-alerts         # アラート一覧
./scripts/load.sh normal-dashboard      # ダッシュボードのみ
./scripts/load.sh mixed-user-flow       # 回遊シナリオ（/ → /devices → /devices/id → /alerts → /chaos）

# ── カオス検証（事前にカオスを ON にしてから実行）────────────────
./scripts/load.sh slow-query-devices    # Slow Query 検証用
./scripts/load.sh error-inject-devices  # Error Inject 検証用
./scripts/load.sh alert-storm-alerts    # Alert Storm 検証用
```

### 繰り返し回数・間隔の調整

```bash
ROUNDS=10 ./scripts/load.sh normal-device-detail        # 10回繰り返す（デフォルト: 3回）
DELAY=0.5 ./scripts/load.sh normal-devices              # リクエスト間隔 0.5秒（デフォルト: 1秒）
ROUNDS=20 DELAY=0.3 ./scripts/load.sh error-inject-devices
```

### 負荷実行後に見るべき CloudWatch コンソール

| 確認画面 | コンソール URL |
|---------|-------------|
| Application Signals Services | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:services |
| Service Map | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:map |
| X-Ray Traces | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#xray:traces/query |
| Container Insights | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#container-insights:performance |
| Logs Insights | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#logsV2:logs-insights |
| Synthetics Canary | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#synthetics:canary/list |
| RUM | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#rum:appMonitorList |
| Custom Metrics | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#metricsV2?namespace=NetwatchPoC/Custom |

### よく使う Logs Insights クエリ

```sql
-- エラーログ集計
fields @timestamp, @message
| filter @message like "ERROR"
| sort @timestamp desc
| limit 50

-- Slow Query 検知
fields @timestamp, @message
| filter @message like "slow_query"
| sort @timestamp desc

-- サービス別ログ件数（Alert Storm 確認）
fields @timestamp, @message
| stats count(*) as cnt by bin(1m)
| sort @timestamp asc

-- trace_id でのログ絞り込み（X-Ray トレースと突き合わせ）
fields @timestamp, @message
| filter @message like "1-xxxxxxxx-xxxxxxxxxxxxxxxxxxxx"
```

> **ヒント:** X-Ray でトレースを見つけたら trace_id をコピーして上記クエリで実行すると、そのトレースに対応するアプリログを即座に特定できます。

---

## 10. 設計チェックリスト

以下の全項目を確認し、この PoC で体験できたことをチェックする。

### APM（Application Signals）

- [ ] 4サービスが Application Signals に自動登録されている（netwatch-ui, device-api, metrics-collector, alert-api）
- [ ] Service Map で3段の依存グラフ（netwatch-ui → device-api → metrics-collector）が表示される
- [ ] Service Map で2段の依存グラフ（netwatch-ui → alert-api）が表示される
- [ ] 各サービスの P50 / P90 / P99 Latency がオペレーション別に確認できる
- [ ] 正常時に Error rate / Fault rate が 0% であることを確認した
- [ ] Slow Query 時に device-api Latency P99 が 5000ms 以上になることを確認した
- [ ] Error Inject 時に device-api Fault rate が設定値に比例することを確認した
- [ ] エラーが netwatch-ui 側にも伝播（Fault rate 上昇）することを確認した

### 分散トレース（X-Ray）

- [ ] 3ホップトレース（netwatch-ui → device-api → metrics-collector）のトレースマップを確認した
- [ ] Slow Query 時に device-api span が長くなることをトレースマップで確認した
- [ ] Error Inject 時にエラー span が赤くなることを確認した
- [ ] トレースフィルタ（`service()`, `fault = true`, `duration > N`）を使った絞り込みを試した

### インフラ・コンテナ（Container Insights）

- [ ] EKS Cluster 全体の CPU / Memory 使用率を確認した
- [ ] Pod 別の CPU / Memory 使用率を確認した
- [ ] Slow Query 時に device-api Pod の CPU が上がらないこと（I/O待ち）を確認した
- [ ] Pod の再起動回数が 0 であることを確認した

### ログ（CloudWatch Logs）

- [ ] `/aws/containerinsights/obs-poc/application` で構造化 JSON ログを確認した
- [ ] Logs Insights で `event: slow_query` を検索できた
- [ ] Logs Insights で `event: error_injected` を検索できた
- [ ] Logs Insights で `event: alert_storm` を検索できた

### 外形監視（Synthetics）

- [ ] Canary を起動して正常時の PASS を確認した
- [ ] Error Inject 時に Canary が FAIL になることを確認した
- [ ] Slow Query 時に Canary は PASS だが Duration が悪化することを確認した（外形監視の限界）
- [ ] Canary を停止した（課金防止）

### CloudWatch RUM

- [ ] `make ec2-appsignals-enable-rum` で RUM を有効化した
- [ ] `/rum-test` ページで `✓ AwsRumClient 初期化済み` を確認した
- [ ] JS エラー / HTTP エラー / カスタムイベントを発生させ RUM コンソールで記録を確認した
- [ ] Slow Query シナリオで RUM の Page load 時間悪化と App Signals Latency P99 を比較した
- [ ] User sessions → View in X-Ray で RUM から X-Ray トレースへのリンクを確認した

### カスタムメトリクス（StatsD）

- [ ] `make ec2-appsignals-enable-custom-metrics` で StatsD を有効化した
- [ ] CloudWatch Metrics > `NetwatchPoC/Custom` namespace でメトリクスが届いていることを確認した
- [ ] 手動 UDP 送信テストで Agent に到達することを確認した
- [ ] Slow Query 中に `netwatch.device.list_ms` が上昇することを確認した
- [ ] StatsD メトリクスと App Signals Latency の値を並べて比較した
- [ ] カスタムメトリクスに対するアラームを1つ作成した

---

## 11. Alarm / SLO 設計イメージ

### Application Signals SLO 設定例

Application Signals のコンソール（Services → 対象サービス → Create SLO）から設定可能。

#### SLO 例 1: netwatch-ui 可用性 SLO 99.9%

| 項目 | 設定値 |
|-----|------|
| SLO 名 | `netwatch-ui-availability-slo` |
| SLI タイプ | Availability |
| 対象サービス | `netwatch-ui` |
| 目標 | 99.9% |
| 期間 | 30日間のローリングウィンドウ |
| エラーバジェット | 43.2分/30日 |

#### SLO 例 2: device-api Latency P99 < 2000ms

| 項目 | 設定値 |
|-----|------|
| SLO 名 | `device-api-latency-slo` |
| SLI タイプ | Latency |
| 対象サービス | `device-api` |
| 目標レイテンシ | 2000ms 以下 |
| 目標達成率 | 99% |
| 期間 | 7日間のローリングウィンドウ |

> **注:** Slow Query シナリオを実行すると device-api Latency SLO はすぐにエラーバジェットを消費する。これが「カオスエンジニアリングが SLO に与える影響」の体験になる。

---

### CloudWatch Alarm 設計例

#### Alarm 例 1: device-api Fault rate > 5%

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "obs-poc-device-api-fault-rate" \
  --alarm-description "device-api Fault rate > 5%" \
  --namespace "ApplicationSignals/OperationMetrics" \
  --metric-name "Fault" \
  --dimensions Name=Service,Value=device-api Name=Environment,Value=eks-ec2-appsignals \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --region ap-northeast-1
```

#### Alarm 例 2: Canary 失敗アラート

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "obs-poc-canary-failed" \
  --alarm-description "Synthetics canary FAIL" \
  --namespace "CloudWatchSynthetics" \
  --metric-name "SuccessPercent" \
  --dimensions Name=CanaryName,Value=obs-poc-health-check \
  --statistic Average \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 100 \
  --comparison-operator LessThanThreshold \
  --region ap-northeast-1
```

#### Alarm 例 3: device-api Latency P99 > 3000ms

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "obs-poc-device-api-high-latency" \
  --alarm-description "device-api Latency P99 > 3000ms" \
  --namespace "ApplicationSignals/OperationMetrics" \
  --metric-name "Latency" \
  --dimensions Name=Service,Value=device-api Name=Environment,Value=eks-ec2-appsignals \
  --extended-statistic p99 \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 3000 \
  --comparison-operator GreaterThanThreshold \
  --region ap-northeast-1
```

#### Alarm 例 4: Pod 再起動検知

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "obs-poc-pod-restart" \
  --alarm-description "Pod restart detected in eks-ec2-appsignals" \
  --namespace "ContainerInsights" \
  --metric-name "pod_number_of_container_restarts" \
  --dimensions Name=ClusterName,Value=obs-poc Name=Namespace,Value=eks-ec2-appsignals \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 0 \
  --comparison-operator GreaterThanThreshold \
  --region ap-northeast-1
```

#### Alarm 例 5: カスタムメトリクス — device-api DB クエリ遅延

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "obs-poc-device-api-slow-query-custom" \
  --alarm-description "device-api DB query latency > 500ms (StatsD)" \
  --namespace "NetwatchPoC/Custom" \
  --metric-name "netwatch.device.list_ms" \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 500 \
  --comparison-operator GreaterThanThreshold \
  --region ap-northeast-1
```

---

*このガイドは `eks-ec2-appsignals` 環境専用の検証手順書です。他環境のガイドは [lab-eks-fargate-appsignals.md](lab-eks-fargate-appsignals.md) / [lab-eks-ec2-newrelic.md](lab-eks-ec2-newrelic.md) / [lab-eks-fargate-newrelic.md](lab-eks-fargate-newrelic.md) を参照してください。*
