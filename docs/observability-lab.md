# NetWatch Observability Lab ガイド

> **対象環境:** NetWatch PoC (EKS on EC2, ap-northeast-1)  
> **Namespace:** `demo-ec2`  
> **最終更新:** 2026-04-30

---

## 目次

1. [この検証環境の目的](#1-この検証環境の目的)
2. [現在のアーキテクチャ](#2-現在のアーキテクチャ)
3. [既存サービス一覧](#3-既存サービス一覧)
4. [既存カオスシナリオ一覧](#4-既存カオスシナリオ一覧)
5. [Application Signals 検証手順](#5-application-signals-検証手順)
6. [CloudWatch Metrics / Container Insights 確認手順](#6-cloudwatch-metrics--container-insights-確認手順)
7. [シナリオ別メトリクス確認ガイド（詳細）](#7-シナリオ別メトリクス確認ガイド詳細)
8. [CloudWatch Synthetics 外形監視](#8-cloudwatch-synthetics-外形監視)
9. [CloudWatch RUM 後日検証手順](#9-cloudwatch-rum-後日検証手順)
10. [負荷テストガイド（scripts/load.sh）](#10-負荷テストガイドscriptsloadsh)
11. [設計チェックリスト](#11-設計チェックリスト)
12. [Alarm / SLO 設計イメージ](#12-alarm--slo-設計イメージ)
13. [コスト管理と削除手順](#13-コスト管理と削除手順)

---

## 1. この検証環境の目的

NetWatch は、大手キャリアがネットワーク機器を監視する想定システムを模したAPM学習用PoCである。実際のサービス構成（UI→API→DB）を再現しており、AWS CloudWatch の各種オブザーバビリティ機能を一通り体験するためのサンドボックスとして機能する。

### 学習目的の全体像

| 目的 | 対応する機能 | 習得できること |
|------|------------|---------------|
| APMの基本を身につける | Application Signals | サービスマップ・レイテンシ・エラー率・SLO定義・トレース読み方 |
| インフラ・コンテナ監視を学ぶ | CloudWatch Metrics / Container Insights | EKSノード・Pod のCPU/Memory・ネットワーク・再起動回数 |
| アプリログの活用を学ぶ | CloudWatch Logs | 構造化JSON ログのクエリ・障害原因特定 |
| 外形監視を体験する | CloudWatch Synthetics | ユーザー視点のエンドポイント死活・応答時間監視 |
| 実ユーザー体感を測る | CloudWatch RUM（後日実装） | ページロード時間・Apdex・JSエラー・セッション分析 |
| 障害の一次切り分けを練習する | 全ツール組み合わせ | Tier1（外形）→ Tier2（APM/メトリクス）→ Tier3（ログ）の流れ |

### Tier別一次切り分けの考え方

```
Tier 1 (外形監視)    : Synthetics Canary が FAIL → サービス全体に影響あり
Tier 2 (APM/メトリクス): Application Signals でどのサービス・オペレーションが遅い/エラーか特定
Tier 3 (ログ)        : CloudWatch Logs でエラーの根本原因（スタックトレース・SQL遅延）を確認
```

実案件ではこの流れを繰り返す。このPoC でシナリオを通じてその手順を体で覚えることが目的である。

---

## 2. 現在のアーキテクチャ

### サービス構成図

```
[Browser]
  -> netwatch-ui (FastAPI + Jinja2 + Tailwind CSS, port 8080, LoadBalancer)
      -> device-api (FastAPI + PostgreSQL, port 8000, ClusterIP)
      |       -> RDS PostgreSQL (db.t3.micro)
      |       -> metrics-collector (FastAPI, port 8000, ClusterIP)
      -> alert-api (FastAPI, in-memory, port 8000, ClusterIP)

[Observability Stack]
  -> Application Signals  (APM・サービスマップ・SLO)
  -> X-Ray                (分散トレース・スパン詳細)
  -> CloudWatch Logs      (JSON構造化ログ / /obs-poc/demo-ec2/application)
  -> CloudWatch Metrics / Container Insights  (EKS・Node・Pod メトリクス)
  -> CloudWatch Synthetics (外形監視 / 5分ごとに4エンドポイントをチェック)
  -> CloudWatch RUM        (後日: 実ユーザー体感 / CW_RUM_SNIPPET 設置済み)
```

### AWSインフラ

| コンポーネント | 仕様 |
|-------------|------|
| EKS Cluster | `obs-poc` / ap-northeast-1 / EC2 t3.small × 2 |
| Namespace | `demo-ec2` |
| EKS Add-on | `amazon-cloudwatch-observability` (OTel Operator + ADOT + Fluent Bit) |
| RDS | PostgreSQL / db.t3.micro / Multi-AZ なし |
| Application Signals | 自動計装（コード変更なし）|
| X-Ray | ADOT Collector 経由でトレース送信 |
| Fluent Bit | Pod ログを `/obs-poc/demo-ec2/application` へ転送 |

### トレース構造

#### 3ホップトレース（機器詳細取得）

```
[Browser] GET /devices/TKY-CORE-001
  └─ netwatch-ui  (Span 1: HTTPリクエスト受信 → downstream呼び出し)
       └─ device-api  (Span 2: DB参照 + metrics-collector 呼び出し)
            ├─ RDS PostgreSQL  (DB クエリ / トレース外)
            └─ metrics-collector  (Span 3: メトリクス取得)
```

#### 2ホップトレース（アラート一覧取得）

```
[Browser] GET /alerts
  └─ netwatch-ui  (Span 1: HTTPリクエスト受信 → downstream呼び出し)
       └─ alert-api  (Span 2: in-memory アラート返却)
```

3ホップトレースは Application Signals の Service Map で3段の依存グラフとして可視化される。X-Ray の Trace 詳細では各 span の duration を個別に確認できる。Slow Query シナリオでは Span 2（device-api）の duration が顕著に伸びるため、どの tier で遅延が発生したかを視覚的に特定できる。

---

## 3. 既存サービス一覧

| サービス名 | 役割 | 主要API | Application Signalsでの見え方 | メトリクス確認観点 | ログ確認観点 |
|-----------|------|--------|------------------------------|-----------------|------------|
| **netwatch-ui** | ブラウザ向けUI / APIゲートウェイ | `GET /` `GET /devices` `GET /devices/{id}` `GET /alerts` `GET /chaos` | Services 一覧に `netwatch-ui` として表示。Latency は UI→downstream 全体の応答時間。Service Map の最上流ノード | Pod CPU/Memory・リクエスト数・P99 レイテンシ | `event: request_start` `event: request_end` / リクエストごとのログ |
| **device-api** | 機器情報の CRUD / RDS 参照 | `GET /devices` `GET /devices/{id}` `POST /chaos/*` | Services 一覧に `device-api` として表示。RDS クエリ遅延は Span duration に反映される | DB コネクションプール・エラー率・レイテンシ | `event: slow_query` `event: error_injected` / SQL ログ |
| **metrics-collector** | 各機器のリアルタイムメトリクス生成 | `GET /metrics/{device_id}` | Services 一覧に `metrics-collector` として表示。device-api からの呼び出しとして Service Map に現れる | CPU/Memory（Pod 軽量）・レスポンスタイム | `event: metrics_fetched` / 機器IDと値のログ |
| **alert-api** | アラート管理（in-memory） | `GET /alerts` `POST /alerts/{id}/resolve` `POST /chaos/alert-storm` | Services 一覧に `alert-api` として表示。Alert Storm 時にスループット急増 | リクエスト数急増・メモリ使用量（Storm 時に増加） | `event: alert_storm` `event: chaos_alert_storm_start/stop` |

---

## 4. 既存カオスシナリオ一覧

| シナリオ名 | 操作対象 | 発動方法 | 期待される影響 | Application Signalsで見る場所 | CloudWatch Metrics/CIで見る場所 | Logsで見る場所 | 運用上の意味 |
|-----------|---------|---------|--------------|----------------------------|-------------------------------|--------------|------------|
| **Slow Query** | device-api | `/chaos` 画面で「Slow Query ON」、またはAPI `POST /chaos/slow-query?enable=true&duration_ms=5000` | `/devices` と `/devices/{id}` のレスポンスが5秒程度遅延。netwatch-ui 側のレイテンシも悪化 | Application Signals > device-api > Operations > Latency P99 悪化 / Trace で device-api span が長くなる | Container Insights で device-api Pod CPU は変化なし（I/O待ち）。Latency メトリクス `p99` 急上昇 | `/obs-poc/demo-ec2/application` で `event: slow_query` を検索 | DBの索引漏れ・フルスキャン・ロック待ちの再現 |
| **Error Inject** | device-api | `/chaos` 画面で「Error Inject ON (30%/50%)」、またはAPI `POST /chaos/error-inject?rate=30` | 指定確率で `HTTP 500` を返す。netwatch-ui でもエラーが伝播し Error rate 上昇 | Application Signals > device-api > Error rate 上昇 / Traces でエラートレースを確認 / netwatch-ui にもエラーが伝播 | Application Signals Metrics の `Error` カウント増加 | `/obs-poc/demo-ec2/application` で `event: error_injected` を検索 | 依存サービス障害の影響伝播・エラーバジェット消費の体験 |
| **Alert Storm** | alert-api | `/chaos` 画面で「Alert Storm ON」、またはAPI `POST /chaos/alert-storm?enable=true` | 60件のアラートが0.3秒間隔で生成される（約18秒で完了）。alert-api のスループット急増 | Application Signals > alert-api > Throughput 急増 / Trace 数増加 | Container Insights > alert-api Pod > Network I/O・CPU 一時上昇 | `/obs-poc/demo-ec2/application` で `event: alert_storm` を検索。ログボリューム急増を確認 | イベント洪水（アラートストーム）時のオブザーバビリティ挙動の確認 |

---

## 5. Application Signals 検証手順

### 前提: ポートフォワード起動

```bash
make port-forward-ec2
# -> netwatch-ui が http://localhost:8080 でアクセス可能になる
```

---

### 5-1. サービス一覧の確認

**目的:** 4サービスが全て自動検出されているか確認する。

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:services

**手順:**
1. 上記 URL を開く
2. 「Services」タブが開いていることを確認
3. 以下の4サービスが表示されていることを確認:
   - `netwatch-ui`
   - `device-api`
   - `metrics-collector`
   - `alert-api`
4. 各サービスの「P99 Latency」「Error rate」「Request count」列を確認
5. Environment 列が `demo-ec2` であることを確認

**見えない場合の対処:**
- まだトラフィックが流れていない場合は `make load` を実行してから数分待つ
- `kubectl get pods -n demo-ec2` でPodが Running かを確認
- OTel Operator が注入されているか: `kubectl describe pod <netwatch-ui-pod> -n demo-ec2 | grep -i otel`

---

### 5-2. Service Map（3段の依存グラフ）

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:map

**手順:**
1. 上記 URL を開く
2. Map 上に以下のノードが表示されていることを確認:
   ```
   [Internet/Client] → netwatch-ui → device-api → metrics-collector
                                  ↘ alert-api
   ```
3. 各エッジ（矢印）にホバーすると「Latency P99」「Error rate」「Request count」が表示される
4. `netwatch-ui → device-api → metrics-collector` の3段構造を確認（3ホップトレース）
5. `netwatch-ui → alert-api` の2段構造を確認（2ホップトレース）

**確認ポイント:**
- ノードの色でヘルス状態（緑=正常、黄=警告、赤=エラー）を確認
- 右上の時間範囲を「Last 1 hour」に設定する

---

### 5-3. Service Detail（各サービスの詳細）

**コンソール URL のパターン:**  
Services 一覧 → 対象サービス名をクリック

#### netwatch-ui の確認
- 「Operations」タブでエンドポイント別のメトリクスを確認:
  - `GET /` (ダッシュボード)
  - `GET /devices` (機器一覧)
  - `GET /devices/{device_id}` (機器詳細 / 3ホップの起点)
  - `GET /alerts` (アラート一覧)
- 「Dependencies」タブで `device-api` と `alert-api` が下流として表示されることを確認

#### device-api の確認
- 「Operations」タブで:
  - `GET /devices` (機器一覧)
  - `GET /devices/{device_id}` (機器詳細)
  - `POST /chaos/*` (カオス制御)
- 「Dependencies」タブで `metrics-collector` が下流として表示されることを確認

#### metrics-collector の確認
- 「Operations」タブで `GET /metrics/{device_id}` を確認
- このサービスは device-api からのみ呼ばれる（外部公開なし）

#### alert-api の確認
- 「Operations」タブで `GET /alerts` を確認
- Alert Storm 中は Throughput が急増する

---

### 5-4. Operation別 Latency (P50/P90/P99)

**手順:**
1. Services 一覧 → `device-api` をクリック
2. 「Operations」タブを開く
3. `GET /devices/{device_id}` 行をクリック
4. Latency グラフで P50 / P90 / P99 の各パーセンタイルを確認
5. 「Add to dashboard」で CloudWatch ダッシュボードに追加できる

**正常時の目安:**
| Operation | P50 | P90 | P99 |
|-----------|-----|-----|-----|
| GET /devices | < 100ms | < 200ms | < 500ms |
| GET /devices/{id} | < 150ms | < 300ms | < 600ms |
| GET /alerts | < 50ms | < 100ms | < 200ms |

---

### 5-5. Error rate / Fault rate

**補足用語:**
- **Error rate:** クライアントエラー（4xx）の割合
- **Fault rate:** サーバーエラー（5xx）の割合。Error Inject シナリオで上昇する

**手順:**
1. Services 一覧 → `device-api` をクリック
2. 「Overview」タブの「Fault rate」グラフを確認
3. Error Inject ON 時は Fault rate が `rate × 100%`（例: 30%設定 → 約30%）になる
4. `netwatch-ui` の Fault rate も上昇していることを確認（依存サービスの障害が伝播）

---

### 5-6. Throughput（スループット）

**手順:**
1. Services 一覧 → `alert-api` をクリック
2. 「Overview」タブの「Request count」グラフを確認
3. Alert Storm 実行時（60件を0.3秒間隔で生成）にリクエスト数が急増することを確認
4. 通常時との差分をグラフで比較する

---

### 5-7. Trace 一覧・Trace 詳細

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#xray:traces/query

**手順:**
1. 上記 URL を開く
2. 「Filter expression」に以下を入力してトレースを絞り込む:
   ```
   service("netwatch-ui")
   ```
3. トレース一覧が表示される（URL・Status・Duration・Service 数）
4. Duration が長いトレースをクリックして詳細を開く
5. Trace Map（Gantt チャート）で各サービスの span を確認

**エラートレースを探す場合:**
```
service("device-api") AND fault = true
```

**遅いトレースを探す場合:**
```
service("device-api") AND duration > 2
```

---

### 5-8. 3ホップトレースの読み方

**前提:** `./scripts/load.sh normal-device-detail` を実行してトレースを生成する

**手順:**
1. X-Ray Traces でトレース一覧を開く
2. `GET /devices/TKY-CORE-001` に対応するトレースをクリック
3. Trace Map で以下の span 構造を確認:

```
netwatch-ui (全体duration)
├── HTTP GET /devices/TKY-CORE-001        ... Span A
│   └── device-api (Span B)
│       ├── SELECT FROM devices WHERE ... (DBクエリ)
│       └── HTTP GET /metrics/TKY-CORE-001
│           └── metrics-collector (Span C)
```

4. 各 span の「Start time」と「Duration」を確認
5. Span B の duration が長い場合 → DB または metrics-collector に問題あり
6. Span C の duration が長い場合 → metrics-collector 自体に問題あり

---

### 5-9. Slow Query 時の見え方

**事前準備:**
```bash
# カオス画面で Slow Query ON、またはAPIで直接有効化
curl -X POST "http://localhost:8080/chaos" -d "service=device-api&chaos=slow_query&enable=true"
# その後負荷をかける
./scripts/load.sh slow-query-devices
```

**Application Signals での確認:**
1. Services → `device-api` → Operations タブ
2. `GET /devices` と `GET /devices/{device_id}` の P99 Latency が5秒以上になることを確認
3. X-Ray Traces で遅いトレースをクリック
4. **Trace Map で `device-api` の span duration が顕著に伸びている（5秒以上）ことを確認**
5. `netwatch-ui` の span duration も `device-api` の遅延分だけ伸びていることを確認
6. `metrics-collector` の span duration は変わらないことを確認（DBが原因であることが分かる）

**注目ポイント:**
- `device-api` の span 内に `slow_query` タグが付与されている場合がある
- Service Map で `device-api` ノードの色が黄色に変わることがある（閾値次第）

---

### 5-10. Error Inject 時の見え方

**事前準備:**
```bash
# カオス画面で Error Inject 30% ON
curl -X POST "http://localhost:8080/chaos" -d "service=device-api&chaos=error_inject&rate=30"
./scripts/load.sh error-inject-devices
```

**Application Signals での確認:**
1. Services → `device-api`
2. Overview タブの「Fault rate」グラフで約30%のエラー率上昇を確認
3. Services → `netwatch-ui`
4. **netwatch-ui 側にも Fault rate 上昇が伝播していることを確認**（依存サービス障害の連鎖）
5. X-Ray Traces でフィルタ:
   ```
   service("device-api") AND fault = true
   ```
6. エラートレースをクリックして Trace Map で確認
7. エラーのある span には赤色マーカーが付く
8. span の「Annotations」や「Metadata」で `HTTP Status Code: 500` を確認

---

### 5-11. Alert Storm 時の見え方

**事前準備:**
```bash
curl -X POST "http://localhost:8080/chaos" -d "service=alert-api&chaos=alert_storm&enable=true"
./scripts/load.sh alert-storm-alerts
```

**Application Signals での確認:**
1. Services → `alert-api`
2. Overview タブの「Request count」グラフで急増を確認
3. Storm は約18秒（60件 × 0.3秒間隔）で完了するため、グラフのスパイクを探す
4. Throughput: 通常 < 1 req/s → Storm 中: ~3-5 req/s
5. Latency は変化が少ない（in-memory処理のため）

---

## 6. CloudWatch Metrics / Container Insights 確認手順

### 推奨確認順序

```
1. Container Insights (EKS全体・Node・Pod の状態を俯瞰)
       ↓
2. Application Signals Metrics (どのサービスのどのオペレーションに問題か)
       ↓
3. X-Ray Traces (問題のあるリクエストのトレース詳細)
       ↓
4. CloudWatch Logs (根本原因のログを確認)
```

---

### 6-1. Container Insights の確認

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#container-insights:performance

#### EKS Cluster 全体の確認

1. 上記 URL を開く
2. ドロップダウンで「EKS Clusters」→ `obs-poc` を選択
3. 確認項目:
   - **Node CPU 使用率:** t3.small は 2vCPU。全体で60%超えたら注意
   - **Node Memory 使用率:** t3.small は 2GB。全体で80%超えたら注意
   - **Pod 数:** 正常時は namespace `demo-ec2` に4 Pod が Running

#### Node の詳細確認

1. 「EKS Nodes」ビューに切り替え
2. 各ノード（Node 1 / Node 2）の CPU・Memory を確認
3. 特定ノードへの Pod 偏りがないか確認

#### Pod CPU / Memory の確認

1. 「EKS Pods」ビューに切り替え
2. Namespace: `demo-ec2` でフィルタ
3. 各 Pod のメトリクスを確認:

| Pod | 正常時 CPU | 正常時 Memory | 異常時の兆候 |
|-----|----------|-------------|------------|
| netwatch-ui | < 10% | < 100MB | Error Inject 時に若干上昇 |
| device-api | < 15% | < 150MB | Slow Query 時はI/O待ちのため変化少 |
| metrics-collector | < 5% | < 80MB | Alert Storm 時に若干上昇 |
| alert-api | < 5% | < 80MB | Alert Storm 時にメモリ一時上昇 |

#### Pod Network I/O

1. Pod 詳細 → 「Network」タブ
2. Alert Storm 時に alert-api の送受信バイト数が増加することを確認

#### Pod 再起動回数

1. 「EKS Pods」ビューで「Restart count」列を確認
2. OOM Kill や Liveness Probe 失敗時に増加する
3. 異常な再起動がある場合は Logs で確認

---

### 6-2. Application Signals Metrics の確認

CloudWatch Metrics から直接参照する方法:

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#metricsV2

**Namespace:** `ApplicationSignals/OperationMetrics`

**主要メトリクス:**

| メトリクス名 | ディメンション | 説明 |
|------------|-------------|------|
| `Latency` | Service, Operation, Environment | レイテンシ（統計: p50/p90/p99 を使用）|
| `Error` | Service, Operation, Environment | 4xx エラーカウント |
| `Fault` | Service, Operation, Environment | 5xx エラーカウント |
| `RequestCount` | Service, Operation, Environment | リクエスト数 |

**メトリクス検索手順:**
1. CloudWatch Metrics を開く
2. 「ApplicationSignals/OperationMetrics」名前空間を選択
3. ディメンションで `Environment = demo-ec2` でフィルタ
4. 対象サービス（例: `device-api`）のメトリクスを選択
5. グラフ設定で統計を「p99」に変更

---

### 6-3. シナリオ別確認表

| シナリオ | 確認メトリクス | 場所 | 期待される変化 |
|---------|-------------|------|--------------|
| **正常時** | Pod CPU/Memory | Container Insights > EKS Pods | 低く安定 |
| **正常時** | device-api Latency P99 | Application Signals > device-api | < 500ms |
| **正常時** | Fault rate | Application Signals > 全サービス | 0% |
| **Slow Query** | device-api Latency P99 | Application Signals > device-api > Latency | 5000ms 以上 |
| **Slow Query** | device-api CPU | Container Insights > device-api Pod | 変化少（I/O待ち）|
| **Slow Query** | slow_query ログ | CloudWatch Logs > /obs-poc/demo-ec2/application | `event: slow_query` が出現 |
| **Error Inject** | device-api Fault rate | Application Signals > device-api > Fault | 設定確率に比例して上昇 |
| **Error Inject** | netwatch-ui Fault rate | Application Signals > netwatch-ui > Fault | device-api と連動して上昇 |
| **Error Inject** | error_injected ログ | CloudWatch Logs > /obs-poc/demo-ec2/application | `event: error_injected` が出現 |
| **Alert Storm** | alert-api RequestCount | Application Signals > alert-api > RequestCount | 急激なスパイク |
| **Alert Storm** | ログボリューム | CloudWatch Logs > /obs-poc/demo-ec2/application | ログ行数が急増 |
| **Alert Storm** | alert-api Memory | Container Insights > alert-api Pod | 一時的な上昇 |

---

## 7. シナリオ別メトリクス確認ガイド（詳細）

### 7-1. 正常時のベースライン

**目的:** 障害発生時の比較基準を把握する。

**操作:**
```bash
make port-forward-ec2
./scripts/load.sh normal-device-detail
# 複数回実行して安定したベースラインを取得する
```

**見るもの・期待値:**

| 観点 | 場所 | 期待値 |
|-----|------|-------|
| netwatch-ui P99 Latency | Application Signals > netwatch-ui | < 1000ms |
| device-api P99 Latency | Application Signals > device-api | < 600ms |
| metrics-collector P99 Latency | Application Signals > metrics-collector | < 200ms |
| alert-api P99 Latency | Application Signals > alert-api | < 200ms |
| 全サービス Fault rate | Application Signals > Services 一覧 | 0% |
| netwatch-ui Pod CPU | Container Insights > EKS Pods | < 10% |
| device-api Pod CPU | Container Insights > EKS Pods | < 15% |
| 3ホップトレース全体 duration | X-Ray Traces | < 1000ms |

**ベースライン記録の推奨:**
最初の検証前に正常時のスクリーンショットを撮っておくと、異常時との比較が容易になる。

---

### 7-2. Slow Query 時

**想定する障害:** DB のインデックス漏れ・フルスキャン・ロック待ちによる応答遅延

**操作手順:**
```bash
# Step 1: カオス画面で Slow Query を有効化
# ブラウザで http://localhost:8080/chaos を開き「Slow Query ON」をクリック
# または直接APIで:
curl -X POST "http://device-api:8000/chaos/slow-query?enable=true&duration_ms=5000"

# Step 2: 負荷を生成
./scripts/load.sh slow-query-devices
```

**確認手順:**

**[Application Signals]**
1. Services → `device-api` → Overview
2. Latency P99 が 5000ms 以上になることを確認
3. Operations タブで `GET /devices` と `GET /devices/{device_id}` の両方が遅いことを確認
4. Services → `netwatch-ui` → Operations タブ
5. `/devices` と `/devices/{id}` のレイテンシも上昇していることを確認（エンドツーエンドの遅延伝播）

**[X-Ray Traces]**
1. X-Ray Traces を開く: https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#xray:traces/query
2. フィルタ: `service("device-api") AND duration > 2`
3. 遅いトレースをクリック
4. Trace Map で **device-api の span が5秒以上** になっていることを確認
5. `metrics-collector` の span は短いまま（DB待ちが原因と分かる）

**[CloudWatch Logs]**
1. CloudWatch Logs Insights を開く
2. Log group: `/obs-poc/demo-ec2/application`
3. 以下のクエリを実行:
```sql
fields @timestamp, @message
| filter @message like "slow_query"
| sort @timestamp desc
| limit 20
```
4. `event: slow_query`、`sleep_ms: 5000`、`endpoint: /devices` のログが確認できる

**[Container Insights]**
1. Container Insights > EKS Pods > `device-api`
2. CPU 使用率は低いまま（sleep 中のため）
3. ネットワーク I/O も低いまま
4. **これがポイント: メトリクス上は「CPU 問題なし」なのにレイテンシが悪化 → ログを見るとDB遅延と判明**

**注目ポイント（運用練習）:**
- Container Insights だけ見ていると問題に気づきにくい（CPUは正常）
- Application Signals の Latency 悪化を検知してから、Trace → Logs の順に深掘りする流れを練習する

---

### 7-3. Error Inject 時

**想定する障害:** 依存サービスの断続的なエラー・エラーバジェット消費

**操作手順:**
```bash
# Step 1: Error Inject 30% を有効化
# ブラウザで http://localhost:8080/chaos を開き「Error Inject 30% ON」をクリック
# または:
curl -X POST "http://device-api:8000/chaos/error-inject?rate=30"

# Step 2: 負荷を生成
./scripts/load.sh error-inject-devices

# より激しい状態を見たい場合（50%エラー）:
curl -X POST "http://device-api:8000/chaos/error-inject?rate=50"
```

**確認手順:**

**[Application Signals Error rate]**
1. Services → `device-api` → Overview
2. 「Fault rate」グラフで約30%のエラー率を確認（HTTP 500）
3. Services → `netwatch-ui` → Overview
4. **netwatch-ui の Fault rate も上昇していることを確認（エラー伝播）**

**[X-Ray Traces]**
1. X-Ray Traces: フィルタ `service("device-api") AND fault = true`
2. エラートレースを選択
3. Trace Map で赤くなっている span（device-api span）を確認
4. span の詳細で `HTTP 500` `"Database query failed (chaos: error injection active)"` を確認
5. netwatch-ui の span も赤くなっていることを確認

**[CloudWatch Logs]**
```sql
fields @timestamp, @message
| filter @message like "error_injected"
| sort @timestamp desc
| limit 30
```
出力例:
```json
{"event": "error_injected", "endpoint": "/devices", "error_rate": 30}
```

**注目ポイント（運用練習）:**
- `error_injected` ログが device-api に集中しているが、netwatch-ui にはエラーログが出ない場合がある
- Application Signals では **netwatch-ui 側の Fault rate も上昇**している → 上流サービスから見た影響を確認できる
- Trace を見ることで「どのサービスが起点のエラーか」を特定する手順を練習する

---

### 7-4. Alert Storm 時

**想定する障害:** イベント洪水・モニタリングシステム自体への過負荷

**操作手順:**
```bash
# Step 1: Alert Storm を起動
# ブラウザで http://localhost:8080/chaos を開き「Alert Storm ON」をクリック
# または:
curl -X POST "http://alert-api:8000/chaos/alert-storm?enable=true"

# Step 2: 負荷を生成（Storm 起動後すぐに実行）
./scripts/load.sh alert-storm-alerts
```

**確認手順:**

**[Application Signals]**
1. Services → `alert-api` → Overview
2. RequestCount / Throughput グラフで急増スパイクを確認
3. Storm は約18秒で完了するため、1分足で見ると目立つスパイクになる
4. Latency は大きく変化しない（in-memory のため）

**[CloudWatch Logs — ボリューム急増]**
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
1. Container Insights > EKS Pods > `alert-api`
2. Alert Storm 中に CPU・Memory が一時的に上昇することを確認
3. Storm 終了後に正常に戻ることを確認（Pod 再起動がないことを確認）

---

## 8. CloudWatch Synthetics 外形監視

### 8-1. Canary の仕様

このPoC では1つの Canary（`obs-poc-health-check`）で4エンドポイントをチェックする。

| エンドポイント | チェック内容 | 期待ステータス | キーワード |
|-------------|-----------|-------------|---------|
| `/` | ダッシュボード表示 | HTTP 200 | `NetWatch` |
| `/devices` | 機器一覧表示 | HTTP 200 | `devices` |
| `/devices/TKY-CORE-001` | 機器詳細（3ホップトレース起点） | HTTP 200 | `TKY-CORE-001` |
| `/alerts` | アラート一覧表示 | HTTP 200 | `alerts` |

- **実行環境:** AWS Lambda（マネージド）
- **実行頻度:** rate(5 minutes)（5分ごと）
- **タイムアウト:** 30秒
- **アーティファクト保存:** S3バケット `obs-poc-synthetics-<account_id>`（3日間保持）

---

### 8-2. Canary 管理手順

#### Canary の有効化

```bash
# Canary の起動（PoC 実施時のみ起動してコスト節約）
aws synthetics start-canary \
  --name obs-poc-health-check \
  --region ap-northeast-1

# 状態確認
aws synthetics get-canary \
  --name obs-poc-health-check \
  --region ap-northeast-1 \
  --query 'Canary.Status.State'
```

#### Canary の停止

```bash
# PoC 終了後や不要時は必ず停止する（課金対象）
aws synthetics stop-canary \
  --name obs-poc-health-check \
  --region ap-northeast-1
```

#### Canary 結果確認（コンソール）

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#synthetics:canary/list

1. 上記 URL を開く
2. `obs-poc-health-check` をクリック
3. 「Availability」タブで成功率グラフを確認
4. 「Duration」タブで応答時間グラフを確認
5. 特定の実行をクリックして各エンドポイントの詳細ログを確認

#### S3 のログ確認

```bash
# 最新の実行結果を確認
aws s3 ls s3://obs-poc-synthetics-$(aws sts get-caller-identity --query Account --output text)/canary-results/ \
  --region ap-northeast-1

# 直近の HAR ファイルをダウンロード（HTTP ログ）
aws s3 cp s3://obs-poc-synthetics-<account_id>/canary-results/<latest>/ . --recursive
```

---

### 8-3. Alarm 設定（Canary 失敗アラート）

#### コンソールからの手動作成

1. CloudWatch → Alarms → Create Alarm
2. 「Select metric」→ `CloudWatch Synthetics` → `obs-poc-health-check` → `SuccessPercent`
3. 設定:
   - Threshold type: Static
   - Whenever SuccessPercent is: `Lower than 100`
   - Evaluation period: 1 out of 1 data points
4. SNS 通知設定（任意）

#### Terraform でのAlarm定義例

```hcl
resource "aws_cloudwatch_metric_alarm" "canary_failed" {
  alarm_name          = "obs-poc-canary-failed"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "SuccessPercent"
  namespace           = "CloudWatchSynthetics"
  period              = 300
  statistic           = "Average"
  threshold           = 100
  alarm_description   = "Synthetics canary check failed"

  dimensions = {
    CanaryName = "obs-poc-health-check"
  }
}
```

---

### 8-4. シナリオ別の Canary 挙動

| シナリオ | Canary の挙動 | 確認方法 |
|---------|-------------|---------|
| **正常時** | 全エンドポイントが 5分ごとに GREEN（PASS） | Synthetics コンソール > Availability 100% |
| **Slow Query** | HTTP 200 は返るが Duration（応答時間）が悪化（5秒程度） | Duration タブで通常時との差を確認 |
| **Error Inject 30%** | 30%の確率で HTTP 500 → Canary FAIL → Alarm 発火 | Availability が低下 / Alarm が ALARM 状態に |
| **Error Inject 50%** | 高確率で FAIL。連続FAIL で Alarm 発火がほぼ確実 | Alarm コンソールで確認 |
| **Alert Storm** | アラート一覧（`/alerts`）は正常返却のため PASS | Duration はわずかに上昇する可能性あり |

**重要な学習ポイント:**
- Slow Query は「応答は返っている（HTTP 200）」ので Canary の成否は PASS になる
- **ユーザーが遅さを感じていても Canary は PASS** → Application Signals の Latency メトリクスで検知が必要
- Error Inject は HTTP 500 を返すため Canary が FAIL → Alarm が鳴る → これは検知できる

---

### 8-5. Canary vs Application Signals の使い分け

| 観点 | Synthetics | Application Signals |
|-----|-----------|-------------------|
| 視点 | 外部ユーザー視点 | サービス内部視点 |
| 検知できること | エンドポイントの死活・応答時間 | どのサービス・オペレーションが原因か |
| Slow Query の検知 | Duration 悪化（成否は PASS）| Latency P99 悪化として明確に検知 |
| Error Inject の検知 | FAIL（HTTP 500）→ Alarm | Fault rate 上昇・トレースでエラー span 確認 |
| 料金体系 | 実行回数課金（0.0012 USD/回） | スパン数課金 |
| 主な用途 | 24/365 外形死活監視・SLA計測 | 障害のドリルダウン・根本原因特定 |

**推奨運用フロー:**
```
Synthetics FAIL (Alarm)
  → Application Signals でどのサービスが原因か特定
  → X-Ray Traces でどのリクエストでエラーが発生しているか特定
  → CloudWatch Logs でエラーの詳細を確認
```

---

## 9. CloudWatch RUM 後日検証手順

> **現状:** Terraform リソース（`aws_rum_app_monitor.poc`）は作成済み。netwatch-ui の `base.html` に `{{ cw_rum_snippet | safe }}` が設置済み。`CW_RUM_SNIPPET` 環境変数を Pod に渡すことで即座に有効化できる。

---

### 9-1. App Monitor の確認

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#rum:overview

Terraform で作成済みの App Monitor:
- **名前:** `obs-poc-rum`
- **Domain:** `localhost`（後日 LoadBalancer DNS に変更）
- **Telemetries:** `errors`, `performance`, `http`
- **Session sample rate:** 100% (1.0)
- **X-Ray 統合:** 有効

---

### 9-2. RUM Snippet の取得と Pod への適用

**Step 1: App Monitor から Snippet を取得**
```bash
# App Monitor ID を確認
aws rum list-app-monitors \
  --region ap-northeast-1 \
  --query 'AppMonitorSummaryList[?Name==`obs-poc-rum`].Id' \
  --output text

# Snippet の取得（コンソールから「Code Snippet」をコピーでもよい）
# CloudWatch RUM コンソール → obs-poc-rum → JavaScript Snippet
```

**Step 2: K8s Secret または ConfigMap に保存**
```bash
# Snippet を環境変数として設定
# helm-values の netwatch-ui の env に CW_RUM_SNIPPET を追加

# 例: k8s/ec2/netwatch-ui.yaml に追加
# env:
#   - name: CW_RUM_SNIPPET
#     value: "<script>...</script>"
```

**Step 3: デプロイ（既存の Deployment を更新）**
```bash
kubectl set env deployment/netwatch-ui \
  -n demo-ec2 \
  CW_RUM_SNIPPET='<script>...RUM snippet here...</script>'
```

**Step 4: 動作確認**
1. ブラウザで `http://localhost:8080` を開く
2. 開発者ツール → Network タブ で `dataplane.rum.ap-northeast-1.amazonaws.com` へのリクエストを確認
3. CloudWatch RUM コンソールで数分後にセッションデータが表示されることを確認

---

### 9-3. base.html のスニペット設置場所

`/Users/hoge/Library/Mobile Documents/com~apple~CloudDocs/apm-kensho/obs-poc/apps/netwatch-ui/templates/base.html` の `<head>` タグ内 **15行目** に設置済み:

```html
<head>
  <meta charset="UTF-8">
  ...
  {{ cw_rum_snippet | safe }}   <!-- ← ここ（15行目） -->
  {{ nr_browser_snippet | safe }}
</head>
```

`CW_RUM_SNIPPET` 環境変数を netwatch-ui Pod に渡すだけで有効化される。コード変更は不要。

---

### 9-4. RUM で見るべき項目

**コンソール URL:**  
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#rum:overview

| 項目 | 場所 | 見るポイント |
|-----|------|-----------|
| Page load 時間（ページ別）| RUM > Performance > Page Loads | `/devices/{id}` が遅い → Slow Query の影響が反映されているか |
| Apdex スコア | RUM > Performance > Apdex | 0.9以上が目標。Slow Query 時に低下するか |
| JS Error 件数・内容 | RUM > Errors > JS Errors | `/chaos` 画面の「JSエラー発生」ボタンで記録されるか |
| HTTP Request エラー | RUM > Errors > HTTP Errors | Error Inject 時に XHR/Fetch の 500 エラーが記録されるか |
| Session 数・ユーザー数 | RUM > Overview | スクリプト実行中のセッション数 |
| Browser / Device 分布 | RUM > Browsers | テスト環境なので Chrome のみになるはず |

---

### 9-5. 検証シナリオ（RUM）

#### シナリオ 1: ページロードの記録確認
1. ブラウザで `http://localhost:8080` を開く
2. RUM コンソールで「Page Load」が記録されるか確認（1-2分後に反映）
3. `/devices` → `/devices/TKY-CORE-001` → `/alerts` の順にアクセスして各ページのロード時間を比較

#### シナリオ 2: Slow Query 時の Page load 悪化確認
1. Slow Query ON（5秒遅延）
2. ブラウザで `/devices` と `/devices/TKY-CORE-001` を開く
3. RUM の Page load 時間グラフで遅延が反映されているか確認
4. Application Signals の Latency P99 と比較（RUM は実ブラウザ時間 / App Signals はサーバー処理時間）

#### シナリオ 3: JS エラーの記録確認
1. ブラウザで `http://localhost:8080/chaos` を開く
2. 「JS エラー発生」ボタン（chaos 画面）をクリック
3. RUM コンソール > Errors > JS Errors でエラーが記録されていることを確認

#### シナリオ 4: 404 ページの記録
1. ブラウザで `http://localhost:8080/not-found` にアクセス
2. RUM でこのアクセスが記録されているか確認

#### シナリオ 5: Error Inject 時の HTTP エラー記録
1. Error Inject 30% ON
2. ブラウザで `/devices` を数回リロード
3. RUM > Errors > HTTP Errors で HTTP 500 が記録されているか確認
4. Application Signals の Fault rate と照合

---

### 9-6. Application Signals との連携

RUM の HTTP エラーと Application Signals のサービスエラーを時刻で突き合わせる:

1. **RUM でエラーを確認:** RUM コンソール > HTTP Errors > タイムスタンプをメモ
2. **Application Signals で照合:** Services → `device-api` → 同じ時刻の Fault rate を確認
3. **X-Ray Traces で確認:** エラー発生時刻付近のトレースを検索:
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

この「RUM（ユーザー視点）→ App Signals（サービス視点）→ Traces（リクエスト視点）→ Logs（コード視点）」の連携が、フルスタックオブザーバビリティの真価である。

---

## 10. 負荷テストガイド（scripts/load.sh）

### 前提

```bash
# ポートフォワード起動（別ターミナルで）
make port-forward-ec2
# EC2 パスが http://localhost:8080 で使用可能になる

# または環境変数で URL を指定
export EC2_BASE="http://<LoadBalancer-DNS>"
```

### 全シナリオ説明

```bash
# ──────────────────────────────────────────────
# 1. 正常時ベースライン（3ホップトレース生成）
# netwatch-ui → device-api → metrics-collector の3ホップを生成
./scripts/load.sh normal-device-detail

# 2. ダッシュボードのみ（1ホップ）
./scripts/load.sh normal-dashboard

# 3. 機器一覧（各エリア・ステータス別）
./scripts/load.sh normal-devices

# 4. アラート一覧（2ホップ）
./scripts/load.sh normal-alerts

# ──────────────────────────────────────────────
# 5. Slow Query 検証（事前に Chaos 画面で Slow Query ON）
./scripts/load.sh slow-query-devices

# 6. Error Inject 検証（事前に Chaos 画面で Error Inject ON）
./scripts/load.sh error-inject-devices

# 7. Alert Storm 後のアラート一覧（事前に Alert Storm ON）
./scripts/load.sh alert-storm-alerts

# ──────────────────────────────────────────────
# 8. ユーザー回遊シナリオ（/ → /devices → /devices/TKY-CORE-001 → /alerts → /chaos）
./scripts/load.sh mixed-user-flow

# 9. 全シナリオ（デフォルト / ROUNDS 回繰り返し）
./scripts/load.sh
# または
make load
```

### 繰り返し回数・間隔の調整

```bash
# 10回繰り返す（デフォルト: 3回）
ROUNDS=10 ./scripts/load.sh normal-device-detail

# リクエスト間隔を0.5秒に（デフォルト: 1秒）
DELAY=0.5 ./scripts/load.sh normal-devices

# 両方指定
ROUNDS=20 DELAY=0.3 ./scripts/load.sh error-inject-devices
```

### 負荷実行後に見るべき画面一覧

| 確認画面 | URL | 何を見るか |
|---------|-----|----------|
| Application Signals Services | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:services | 4サービスの Latency・Error・Throughput |
| Service Map | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:map | 依存関係・ヘルスステータス |
| X-Ray Traces | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#xray:traces/query | トレース一覧・遅延・エラー |
| Container Insights | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#container-insights:performance | Pod CPU/Memory/再起動 |
| CloudWatch Logs Insights | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#logsV2:logs-insights | アプリログのクエリ |
| Synthetics Canary | https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#synthetics:canary/list | 外形監視の成否・Duration |

### PoC 全体の推奨実施順序

```bash
# 1. 環境起動
make port-forward-ec2

# 2. ベースライン確認
./scripts/load.sh normal-device-detail
# → Application Signals で4サービス表示、Service Map で3段構造を確認

# 3. Slow Query シナリオ
# [カオス画面] Slow Query ON
./scripts/load.sh slow-query-devices
# → Application Signals で device-api Latency P99 急上昇を確認
# → X-Ray で device-api span が長いことを確認
# → Logs で slow_query イベントを確認
# [カオス画面] Slow Query OFF

# 4. Error Inject シナリオ
# [カオス画面] Error Inject 30% ON
./scripts/load.sh error-inject-devices
# → Application Signals で device-api Fault rate ≈30%を確認
# → netwatch-ui にも伝播していることを確認
# [カオス画面] Error Inject OFF

# 5. Alert Storm シナリオ
# [カオス画面] Alert Storm ON
./scripts/load.sh alert-storm-alerts
# → alert-api Throughput 急増を確認
# → Logs でボリューム急増を確認

# 6. Synthetics 確認
aws synthetics start-canary --name obs-poc-health-check --region ap-northeast-1
# Error Inject ON の状態で Canary FAIL を確認
# Error Inject OFF に戻して PASS を確認
aws synthetics stop-canary --name obs-poc-health-check --region ap-northeast-1
```

---

## 11. 設計チェックリスト

以下の全項目を確認し、このPoC で体験できたことをチェックする。

### APM（Application Signals）

- [ ] 4サービスが Application Signals に自動登録されている（netwatch-ui, device-api, metrics-collector, alert-api）
- [ ] Service Map で3段の依存グラフ（netwatch-ui → device-api → metrics-collector）が表示される
- [ ] Service Map で2段の依存グラフ（netwatch-ui → alert-api）が表示される
- [ ] 各サービスの P50 / P90 / P99 Latency がオペレーション別に確認できる
- [ ] Error rate と Fault rate が正常時に 0% であることを確認した
- [ ] Slow Query 時に device-api の Latency P99 が 5000ms 以上になることを確認した
- [ ] Error Inject 時に device-api の Fault rate が設定値に比例することを確認した
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

- [ ] `/obs-poc/demo-ec2/application` で構造化 JSON ログを確認した
- [ ] Logs Insights で `event: slow_query` を検索できた
- [ ] Logs Insights で `event: error_injected` を検索できた
- [ ] Logs Insights で `event: alert_storm` を検索できた

### 外形監視（Synthetics）

- [ ] Canary を起動して正常時の PASS を確認した
- [ ] Error Inject 時に Canary が FAIL になることを確認した
- [ ] Slow Query 時に Canary は PASS だが Duration が悪化することを確認した
- [ ] Canary を停止した（課金防止）

---

## 12. Alarm / SLO 設計イメージ

### Application Signals SLO 設定例

Application Signals のコンソール（Services → 対象サービス → Create SLO）から設定可能。

#### SLO 例 1: netwatch-ui 可用性 SLO 99.9%

| 項目 | 設定値 |
|-----|------|
| SLO 名 | `netwatch-ui-availability-slo` |
| SLI タイプ | Availability |
| 対象サービス | `netwatch-ui` |
| 対象オペレーション | ALL |
| 目標 | 99.9% |
| 期間 | 30日間のローリングウィンドウ |
| エラーバジェット | 43.2分/30日（0.1% × 30日） |

#### SLO 例 2: device-api Latency P99 < 2000ms

| 項目 | 設定値 |
|-----|------|
| SLO 名 | `device-api-latency-slo` |
| SLI タイプ | Latency |
| 対象サービス | `device-api` |
| 目標レイテンシ | 2000ms 以下 |
| 目標達成率 | 99% |
| 期間 | 7日間のローリングウィンドウ |

**注:** Slow Query シナリオを実行すると device-api Latency SLO はすぐにエラーバジェットを消費する。これが「カオスエンジニアリングがSLOに与える影響」の体験になる。

---

### CloudWatch Alarm 設計例

Terraform で定義済みの Alarm（`obs-poc-high-latency-ec2`, `obs-poc-high-error-rate-ec2`）に加えて、以下を手動作成することを推奨する:

#### Alarm 例 1: device-api Error rate > 5%

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "obs-poc-device-api-fault-rate" \
  --alarm-description "device-api Fault rate > 5%" \
  --namespace "ApplicationSignals/OperationMetrics" \
  --metric-name "Fault" \
  --dimensions Name=Service,Value=device-api Name=Environment,Value=demo-ec2 \
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
  --dimensions Name=Service,Value=device-api Name=Environment,Value=demo-ec2 \
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
  --alarm-description "Pod restart detected in demo-ec2" \
  --namespace "ContainerInsights" \
  --metric-name "pod_number_of_container_restarts" \
  --dimensions Name=ClusterName,Value=obs-poc Name=Namespace,Value=demo-ec2 \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 0 \
  --comparison-operator GreaterThanThreshold \
  --region ap-northeast-1
```

---

## 13. コスト管理と削除手順

### 費用概算（月額）

| コンポーネント | 仕様 | 概算月額（USD） |
|-------------|-----|--------------|
| EKS クラスター | EC2 t3.small × 2 ノード | ~$30 |
| EKS コントロールプレーン | 固定 | $72 |
| RDS PostgreSQL | db.t3.micro, Single-AZ | ~$15 |
| Application Signals | スパン数課金（~100万スパン/月） | ~$5 |
| CloudWatch Logs | ログ取り込み・保存（1日保持） | ~$2 |
| CloudWatch Synthetics | 5分ごと × 4エンドポイント × 30日 | ~$1.5 |
| X-Ray Traces | トレース数課金 | ~$1 |
| CloudWatch Metrics | カスタムメトリクス | ~$1 |
| **合計概算** | | **~$130/月** |

> **重要:** EKS コントロールプレーン（$72/月）と EC2 ノードが主要コスト。PoC 終了後は必ず `make down` で削除すること。

---

### Synthetics Canary の停止方法

PoC 終了後や一時停止時は必ず Canary を停止する（実行中のみ課金対象）:

```bash
aws synthetics stop-canary \
  --name obs-poc-health-check \
  --region ap-northeast-1

# 停止確認
aws synthetics get-canary \
  --name obs-poc-health-check \
  --region ap-northeast-1 \
  --query 'Canary.Status.State'
# -> "STOPPED" になればOK
```

---

### make down での完全削除

```bash
# 全リソースの削除（EKS, RDS, Synthetics, CloudWatch, VPCすべて）
make down

# または Terraform 直接実行
cd infra/terraform
terraform destroy -auto-approve
```

**削除前に確認すること:**
1. `aws synthetics stop-canary --name obs-poc-health-check --region ap-northeast-1`（Canary を停止してから削除）
2. `kubectl get pvc -n demo-ec2`（PVC が残っていると削除が詰まる場合がある）
3. RDS スナップショットが必要な場合は事前に手動作成

---

### コスト削減のための Tips

#### PoC 中に実施できるコスト削減

1. **Synthetics Canary の停止**（検証中以外は停止）:
   ```bash
   aws synthetics stop-canary --name obs-poc-health-check --region ap-northeast-1
   ```

2. **CloudWatch Logs の保持期間短縮**（既に1日に設定済み）:
   - `/obs-poc/demo-ec2/application`: 1日保持
   - Container Insights ログ: 1日保持

3. **EKS ノードのスケールダウン**（検証しない時間帯）:
   ```bash
   # ノードを0に（Podは停止するが EKS コントロールプレーンは課金継続）
   aws eks update-nodegroup-config \
     --cluster-name obs-poc \
     --nodegroup-name obs-poc-main \
     --scaling-config minSize=0,maxSize=2,desiredSize=0 \
     --region ap-northeast-1

   # 再開時
   aws eks update-nodegroup-config \
     --cluster-name obs-poc \
     --nodegroup-name obs-poc-main \
     --scaling-config minSize=1,maxSize=2,desiredSize=2 \
     --region ap-northeast-1
   ```

4. **X-Ray サンプリングレートの調整**（高負荷テスト時）:
   - デフォルトでトレースをサンプリングしているため、大量負荷テストでも課金は抑制される

5. **RDS の停止**（長期間使わない場合）:
   ```bash
   aws rds stop-db-instance \
     --db-instance-identifier obs-poc-rds \
     --region ap-northeast-1
   # ※ RDS は停止しても7日後に自動起動する
   ```

#### 完全削除後のコスト確認

```bash
# 削除後に残存リソースがないか確認
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=obs-poc \
  --region ap-northeast-1

# S3 バケットの確認（Synthetics アーティファクト）
aws s3 ls | grep obs-poc
```

---

*このガイドは obs-poc PoC 専用の検証手順書です。本番環境への適用前に各設定値・閾値を環境に合わせて調整してください。*
