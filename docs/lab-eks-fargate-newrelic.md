# ハンズオンガイド — EKS on Fargate + New Relic（APM only）

> **対象環境:** `eks-fargate-newrelic` (EKS on Fargate, ap-northeast-1)  
> **アクセス:** `make port-forward-fargate-newrelic` → http://localhost:8083  
> **環境構築・セットアップ手順:** [docs/setup.md](setup.md) を参照  
> **障害対応 Runbook:** [docs/runbook.md](runbook.md) を参照  
> **環境比較:** [docs/environment-comparison.md](environment-comparison.md) を参照

---

## Fargate × New Relic 環境の制約（重要）

New Relic Infrastructure Agent と Fluent Bit は **DaemonSet** として動作するため、ノードレスアーキテクチャの Fargate では利用できない。このため本環境は **APM トレースのみ** を検証する環境となる。

| 機能 | eks-ec2-newrelic | **eks-fargate-newrelic** | 制約の理由 |
|------|-----------------|--------------------------|-----------|
| APM / 分散トレース | ✅ | ✅ | k8s-agents-operator（init container）は Fargate 対応 |
| サービスマップ | ✅ | ✅ | APM の一部 |
| Errors Inbox | ✅ | ✅ | APM の一部 |
| Transaction Traces | ✅ | ✅ | APM の一部 |
| SLO（Service Levels） | ✅ | ✅ | APM の一部 |
| NR Browser | ✅ | ✅ | JS スニペットはサーバー側に依存しない |
| Kubernetes Explorer | ✅ | ❌ | NR Infrastructure DaemonSet 非対応 |
| ノード/Pod メトリクス | ✅ | ❌ | NR Infrastructure DaemonSet 非対応 |
| NR Logs | ✅ | ❌ | Fluent Bit DaemonSet 非対応 |
| NR Flex カスタムメトリクス | ✅ | ❌ | nri-bundle DaemonSet 非対応 |

> **PoC での活用:** この制約テーブルそのものが「Fargate 採用時のオブザーバビリティ選定」の判断材料になる。EC2 環境と並べて提案資料に使用する。

---

## 目次

1. [このガイドについて（推奨実施フロー）](#1-このガイドについて推奨実施フロー)
2. [カオスシナリオ クイックリファレンス](#2-カオスシナリオ-クイックリファレンス)
3. [New Relic APM 検証手順](#3-new-relic-apm-検証手順)
4. [シナリオ別 確認ガイド（詳細）](#4-シナリオ別-確認ガイド詳細)
5. [ログ（APM Logs in Context のみ）](#5-ログapm-logs-in-context-のみ)
6. [NR Browser（ブラウザ監視）](#6-nr-browserブラウザ監視)
7. [トランザクションデータ生成](#7-トランザクションデータ生成)
8. [設計チェックリスト](#8-設計チェックリスト)
9. [NR Alerts / Service Levels 設計イメージ](#9-nr-alerts--service-levels-設計イメージ)
10. [EC2 + New Relic 環境との比較まとめ](#10-ec2--new-relic-環境との比較まとめ)

---

## 1. このガイドについて（推奨実施フロー）

### この環境だけを始める手順

共通準備（`make up` / `make create-secrets` / `make build-push`）と `.env` の `NEW_RELIC_LICENSE_KEY` / `NEW_RELIC_ACCOUNT_ID` 設定が完了していれば、この環境だけを単独でデプロイできます。別日に再開する場合は、先に `make check-prereq` と `kubectl config current-context` で接続先を確認してください。

```bash
make install-newrelic-full
make fargate-newrelic-deploy
make fargate-newrelic-verify

FARGATE_NR_LB=$(kubectl get svc netwatch-ui -n eks-fargate-newrelic \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "FARGATE_NR_BASE=http://${FARGATE_NR_LB}" >> .env
source .env

EC2_AS_BASE="" FARGATE_AS_BASE="" EC2_NR_BASE="" \
  ./scripts/load.sh normal-device-detail
```

以降の検証は `FARGATE_NR_BASE` だけを使います。他環境が未構築でも進められます。

### 利用可能な機能

| 機能 | 状態 | 備考 |
|------|------|------|
| APM / 分散トレース | ✅ | |
| サービスマップ | ✅ | |
| SLO（Service Levels） | ✅ | |
| Errors Inbox | ✅ | |
| Transaction Traces | ✅ | |
| NR Browser | ✅ | NR_BROWSER_SNIPPET を Secret に設定済みの場合 |
| Kubernetes Explorer | ❌ | DaemonSet 非対応 |
| NR Logs | ❌ | DaemonSet 非対応 |
| NR Flex カスタムメトリクス | ❌ | DaemonSet 非対応 |

### 推奨実施フロー

```bash
# 事前: port-forward で環境にアクセスできることを確認
make port-forward-fargate-newrelic   # 別ターミナルで実行。http://localhost:8083

source .env

# ① ベースライン確認
./scripts/load.sh normal-device-detail
# → one.newrelic.com > APM で4サービス表示（環境名に eks-fargate-newrelic が含まれる）

# ② Slow Query シナリオ
curl -X POST "${FARGATE_NR_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
./scripts/load.sh slow-query-devices
# → NR APM の Transaction Traces に自動キャプチャされていることを確認
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"

# ③ Error Inject シナリオ
curl -X POST "${FARGATE_NR_BASE}/api/chaos/error-inject?rate=30"
./scripts/load.sh error-inject-devices
# → Errors Inbox でエラーが自動グルーピングされていることを確認
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"

# ④ Alert Storm シナリオ
curl -X POST "${FARGATE_NR_BASE}/api/chaos/alert-storm?enable=true"
./scripts/load.sh alert-storm-alerts
# → NR APM > alert-api の Throughput スパイクを確認
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"

# ⑤ EC2 + NR 環境と並べて比較（両環境稼働時）
make load   # 全環境に同時送信して APM の見え方を比較
```

---

## 2. カオスシナリオ クイックリファレンス

### 操作コマンド

```bash
source .env   # FARGATE_NR_BASE を読み込む

# Slow Query ON（5秒遅延）
curl -X POST "${FARGATE_NR_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"

# Slow Query OFF
curl -X POST "${FARGATE_NR_BASE}/api/chaos/slow-query?enable=false"

# Error Inject ON（30%）
curl -X POST "${FARGATE_NR_BASE}/api/chaos/error-inject?rate=30"

# Error Inject OFF
curl -X POST "${FARGATE_NR_BASE}/api/chaos/error-inject?rate=0"

# Alert Storm 発動
curl -X POST "${FARGATE_NR_BASE}/api/chaos/alert-storm?enable=true"

# 全カオスリセット
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"

# 現在のカオス状態確認
curl -s "${FARGATE_NR_BASE}/api/chaos/state" | python3 -m json.tool
```

> ブラウザから操作する場合は `${FARGATE_NR_BASE}/chaos` のカオスコントロール画面を使用してください。

### シナリオ別 確認先一覧

| シナリオ | 主な確認先 | 期待する見え方 |
|---------|-----------|--------------|
| **正常時** | APM > Services | 4サービス表示、Apdex > 0.9 |
| **Slow Query** | APM > device-api > Transaction Traces | 遅いトランザクションが自動キャプチャ |
| **Error Inject** | Errors Inbox | エラーが自動グルーピング |
| **Error Inject** | APM > device-api > Error rate | 設定確率に比例して上昇 |
| **Alert Storm** | APM > alert-api > Throughput | 急激なスパイク |

> ログ確認は **APM トレース詳細の Logs タブ** から行う（NR Logs の全文検索は利用不可）。

### アラート起点の調査シナリオ

このハンズオンでは、`make load-*` を「負荷テスト」ではなく、障害発生時のトランザクションデータを再現する操作として扱う。運用者は最初に NR Alerts、Synthetics、または APM メトリクスの閾値超過で異常を検知し、その後 New Relic APM で影響範囲と原因を絞り込む。

| シナリオ | 最初の検知 | New Relic APM で見る順序 | 判断したいこと |
|---------|------------|---------------------------|----------------|
| **Slow Query** | Response time / Apdex / Service Level の悪化 | APM Services で `eks-fargate-newrelic` に絞る → `device-api` と `netwatch-ui` の Response time を確認 → Service Map で呼び出し経路を確認 → `device-api` の Transaction Traces / Databases を開く | ユーザー影響は `/devices` 系。根本原因候補は `device-api` の DB 処理遅延。Fargate でも APM トレースは EC2 と同等に使える。 |
| **Error Inject** | Error rate 閾値超過、Errors Inbox の新規グループ | Errors Inbox で新規エラーグループを確認 → Occurrences から代表 trace を開く → Distributed Tracing で最初にエラー化した span を確認 → 必要に応じて `kubectl logs` で該当時刻のログを確認 | 起点は `device-api`。`netwatch-ui` のエラーは下流エラーの伝播。Errors Inbox による分類は使えるが、NR Logs がないためログ深掘りは手順が増える。 |
| **Alert Storm** | `alert-api` Throughput 急増、APM 上のリクエスト数増加 | APM > `alert-api` で Throughput スパイクを確認 → Service Map で `/alerts` 経路の影響を確認 → `kubectl logs` で `alert_storm` を確認 | 起点は `alert-api`。影響が `/alerts` 系に閉じているかは APM で確認できるが、Pod/ログ/インフラの裏取りは EC2 + NR より限定的。 |

Fargate + New Relic では APM、Errors Inbox、Transaction Traces は使えるため、原因 API / 原因サービスの特定は可能。一方で NR Infrastructure と NR Logs がないため、根本原因の裏取りは APM から `kubectl logs` や CloudWatch 側の Fargate ログへ移る運用になる。この差分をハンズオンで確認する。

---

## 3. New Relic APM 検証手順

### NR コンソール URL

| 画面 | URL |
|------|-----|
| APM Services 一覧 | https://one.newrelic.com/nr1-core?filters=domain%3DAPM |
| Distributed Tracing | https://one.newrelic.com/distributed-tracing |
| Errors Inbox | https://one.newrelic.com/errors-inbox |

---

### 3-1. サービス一覧の確認

1. `one.newrelic.com` → 左ナビ **APM & Services**
2. フィルタ欄に `eks-fargate-newrelic` と入力
3. 以下の4エンティティが表示されていることを確認:
   - `netwatch-ui (eks-fargate-newrelic)`
   - `device-api (eks-fargate-newrelic)`
   - `metrics-collector (eks-fargate-newrelic)`
   - `alert-api (eks-fargate-newrelic)`
4. 各サービスの「Response time」「Error rate」「Throughput」を確認

**見えない場合の対処:**
- `make load` を実行してから2〜3分待つ
- `kubectl get pods -n eks-fargate-newrelic` で Pod が Running か確認
- `kubectl describe pod -n eks-fargate-newrelic -l app=netwatch-ui | grep newrelic` で NR init container が注入されているか確認

---

### 3-2. APM Service Map

1. APM > `netwatch-ui (eks-fargate-newrelic)` → **Service Map** タブ
2. 以下の依存グラフを確認:

```
[Browser/External] → netwatch-ui → device-api → metrics-collector
                                 ↘ alert-api
```

3. 各エッジをクリックすると Response time / Error rate / Throughput が表示される
4. Infrastructure の情報（Kubernetes ノードなど）は表示されない（Fargate 制約）

---

### 3-3. Transaction Traces（遅いトランザクションの自動キャプチャ）

NR APM は閾値を超えた遅いトランザクションを **自動的にキャプチャ**する。

1. APM > `device-api (eks-fargate-newrelic)` → **Transaction Traces** タブ
2. Slow Query ON 後に `GET /devices` と `GET /devices/{id}` が自動でリストに追加される
3. トレースをクリック → Trace details ページ:
   - **Trace breakdown:** span 別の時間（DB クエリの段が長い）
   - **DB queries:** 実行された SQL と所要時間
   - **Logs tab:** 表示されるが NR Logs へのデータ転送は未設定のため空になる

---

### 3-4. Distributed Tracing（3ホップトレース）

```bash
source .env
./scripts/load.sh normal-device-detail
```

1. `one.newrelic.com` → 左ナビ **Distributed Tracing**
2. フィルタ: `service.name = "netwatch-ui (eks-fargate-newrelic)"`
3. トレースを選択 → Waterfall ビューで以下を確認:

```
netwatch-ui (eks-fargate-newrelic)
├── HTTP GET /devices/TKY-CORE-001
│   └── device-api (eks-fargate-newrelic)
│       ├── db select (PostgreSQL)
│       └── HTTP GET /metrics/TKY-CORE-001
│           └── metrics-collector (eks-fargate-newrelic)
```

4. EC2 環境（`eks-ec2-newrelic`）のトレースと Waterfall 構造を比較する  
   → トレース構造は同一。APM 計装方式（k8s-agents-operator init container）は Fargate でも同様に動作する

---

### 3-5. Errors Inbox（エラーの自動グルーピング）

```bash
source .env
curl -X POST "${FARGATE_NR_BASE}/api/chaos/error-inject?rate=30"
./scripts/load.sh error-inject-devices
```

1. `one.newrelic.com` → 左ナビ **Errors Inbox**
2. `device-api (eks-fargate-newrelic)` のエラーグループを確認
3. エラーグループをクリック → **Occurrences** タブ:
   - スタックトレース
   - 発生時のリクエスト属性（URL、HTTP ステータス等）
4. **Distributed Tracing** タブ: そのエラーに対応するトレースに1クリックで移動

```bash
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"
```

---

### 3-6. Slow Query 時の見え方

```bash
source .env
curl -X POST "${FARGATE_NR_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
./scripts/load.sh slow-query-devices
```

**[NR APM]**
1. APM > `device-api (eks-fargate-newrelic)` → Summary タブで Response time 悪化を確認
2. Transactions タブで P99 が 5000ms 以上
3. **Transaction Traces タブ:** 遅いトランザクションが自動キャプチャされていることを確認

**[NRQL で確認]**
```sql
-- device-api の P99 レイテンシ推移
SELECT percentile(duration, 99) FROM Transaction
WHERE appName = 'device-api (eks-fargate-newrelic)'
SINCE 30 minutes ago TIMESERIES 1 minute

-- EC2 環境と Fargate 環境を並べて比較
SELECT percentile(duration, 99) FROM Transaction
WHERE appName LIKE '%device-api%'
FACET appName
SINCE 30 minutes ago TIMESERIES 1 minute
```

```bash
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"
```

---

### 3-7. Error Inject 時の見え方

```bash
source .env
curl -X POST "${FARGATE_NR_BASE}/api/chaos/error-inject?rate=30"
./scripts/load.sh error-inject-devices
```

**[NR APM]**
1. APM > `device-api (eks-fargate-newrelic)` → Error rate が約30%に上昇
2. APM > `netwatch-ui (eks-fargate-newrelic)` → Error rate も連動して上昇（エラー伝播）
3. **Errors Inbox** でエラーグループが自動作成されることを確認

**[Distributed Tracing]**
- フィルタ: `service.name = "device-api (eks-fargate-newrelic)" AND error = true`
- エラートレースを選択して span の詳細で `HTTP 500` を確認

```bash
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"
```

---

### 3-8. Alert Storm 時の見え方

```bash
source .env
curl -X POST "${FARGATE_NR_BASE}/api/chaos/alert-storm?enable=true"
./scripts/load.sh alert-storm-alerts
```

**[NR APM]**
1. APM > `alert-api (eks-fargate-newrelic)` → Throughput スパイクを確認
2. Storm は約18秒で完了するため、グラフのスパイクを探す

**[NRQL]**
```sql
SELECT rate(count(*), 1 minute) FROM Transaction
WHERE appName = 'alert-api (eks-fargate-newrelic)'
SINCE 30 minutes ago TIMESERIES 1 minute
```

> ログ全文検索（NR Logs）は利用不可。トレース詳細の Logs タブまたは kubectl logs で確認する。

```bash
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"
```

---

## 4. シナリオ別 確認ガイド（詳細）

### 4-1. 正常時のベースライン

```bash
source .env
./scripts/load.sh normal-device-detail
```

**期待値（NR Fargate）:**

| 観点 | 場所 | 期待値 |
|-----|------|-------|
| netwatch-ui Response time P99 | APM > netwatch-ui | < 1200ms（Fargate Cold Start の影響あり） |
| device-api Response time P99 | APM > device-api | < 700ms |
| 全サービス Error rate | APM > Services | 0% |
| 全サービス Apdex | APM > Services | > 0.9 |

> Fargate は Cold Start の影響で最初のリクエストのレイテンシが高い場合がある。数回トランザクションを送って安定した後の値を記録する。

---

### 4-2. Slow Query 検証

**想定する障害:** DB の応答遅延

```bash
source .env
curl -X POST "${FARGATE_NR_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
./scripts/load.sh slow-query-devices
```

**[NR APM]**
1. APM > `device-api (eks-fargate-newrelic)` → Response time P99 が 5000ms 以上
2. **Transaction Traces** に遅いトランザクションが自動キャプチャされることを確認
3. Trace breakdown で DB クエリの span が長いことを確認

**[Distributed Tracing]**
```
フィルタ: service.name = "device-api (eks-fargate-newrelic)" AND duration > 2
```
- Waterfall で device-api span が 5秒以上、metrics-collector span は短いまま  
  → DB 待ちが原因と判断できる

**学習ポイント（Fargate 固有）:**
- Container Insights（EC2 環境）では「CPU が上がらないのにレイテンシが悪化」という視点で Infrastructure との使い分けを学べる
- Fargate 環境では Infrastructure メトリクスが取れないため、APM の Latency データが **唯一の手掛かり** になる → APM の重要性が EC2 環境より高い

```bash
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"
```

---

### 4-3. Error Inject 検証

**想定する障害:** 依存サービスの断続的なエラー

```bash
source .env
curl -X POST "${FARGATE_NR_BASE}/api/chaos/error-inject?rate=30"
./scripts/load.sh error-inject-devices
```

**[NR APM]**
1. APM > `device-api` → Error rate が約30%に上昇
2. APM > `netwatch-ui` → Error rate も連動して上昇（エラー伝播）
3. **Errors Inbox** でエラーグループが自動作成されることを確認

**[Distributed Tracing]**
```
フィルタ: service.name = "device-api (eks-fargate-newrelic)" AND error = true
```

**学習ポイント（EC2 との比較）:**
- EC2 環境: NR Logs でエラーログを全文検索できる
- Fargate 環境: ログ確認はトレース詳細の Logs タブまたは `kubectl logs` のみ  
  → エラーの根本原因をログから追う際に手順が増える（提案資料の判断材料）

```bash
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"
```

---

### 4-4. Alert Storm 検証

**想定する障害:** イベント洪水・モニタリングシステムへの過負荷

```bash
source .env
curl -X POST "${FARGATE_NR_BASE}/api/chaos/alert-storm?enable=true"
./scripts/load.sh alert-storm-alerts
```

**[NR APM]**
1. APM > `alert-api` → Throughput スパイクを確認（Storm は約18秒）

**[NRQL]**
```sql
SELECT rate(count(*), 1 minute) FROM Transaction
WHERE appName = 'alert-api (eks-fargate-newrelic)'
SINCE 30 minutes ago TIMESERIES 1 minute
```

**学習ポイント（EC2 との比較）:**
- EC2 環境では NR Logs で `message:"alert_storm"` と検索できる
- Fargate 環境では NRQL のトランザクションデータで Throughput スパイクのみ確認
- APM でスパイク検知 → 詳細は `kubectl logs` という2ステップになる

```bash
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"
```

---

## 5. ログ（APM Logs in Context のみ）

### 5-1. NR Logs が利用できない理由

NR の全文ログ収集は **Fluent Bit DaemonSet**（nri-bundle に含まれる）が各ノードでログを収集して NR に転送する仕組みを使用する。DaemonSet は Fargate に対応していないため、`eks-fargate-newrelic` 環境では NR Logs への転送が行われない。

### 5-2. APM トレース詳細の Logs タブ

NR APM の Distributed Tracing では、トレース詳細画面に **Logs タブ** が表示される。EC2 環境では NR Logs からそのトレースに対応するログが1クリックで参照できるが、Fargate 環境ではログデータがないため空になる。

### 5-3. 代替手順（kubectl logs）

```bash
# エラー発生時のログを直接確認
kubectl logs -n eks-fargate-newrelic -l app=device-api --tail=50

# Slow Query ログの確認
kubectl logs -n eks-fargate-newrelic -l app=device-api --tail=100 \
  | grep slow_query

# 直近のエラーログ
kubectl logs -n eks-fargate-newrelic -l app=device-api --tail=100 \
  | python3 -c "import sys,json; [print(json.dumps(json.loads(l), indent=2)) for l in sys.stdin if 'ERROR' in l]" 2>/dev/null
```

### 5-4. EC2 環境との比較（ログ調査コスト）

| 調査シナリオ | EC2 + NR | **Fargate + NR** |
|------------|---------|-----------------|
| エラーログの検索 | NR Logs: `level:ERROR` で即座に検索 | `kubectl logs` + grep |
| トレースとログの紐付け | APM → Logs タブ（1クリック） | `kubectl logs` で trace_id を手動検索 |
| 過去ログの参照 | NR Logs の期間指定で即座 | Pod が再起動済みの場合参照不可 |
| ログの集計・分析 | NRQL でクエリ可能 | 不可 |

> **PoC の活用:** この差分は「Fargate + New Relic を採用した場合のログ調査コスト」として提案資料に明記する。

---

## 6. NR Browser（ブラウザ監視）

NR Browser は CloudWatch RUM に相当する機能で、`NR_BROWSER_SNIPPET` 環境変数（Secret 経由）でスニペットが注入される。Fargate 環境でも EC2 と同様に動作する。

### 6-1. 前提条件

```bash
# NR Browser snippet が Secret に登録されているか確認
kubectl get secret newrelic-secret -n eks-fargate-newrelic -o jsonpath='{.data.browser-snippet}' | base64 -d | head -3
```

出力に `<script type="text/javascript">` が含まれていれば設定済み。

---

### 6-2. NR Browser コンソールの確認

1. `one.newrelic.com` → 左ナビ **Browser**
2. `netwatch-ui (eks-fargate-newrelic)` アプリを選択
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

### 6-3. 検証シナリオ（NR Browser）

**シナリオ 1: Slow Query 時の Page load 悪化確認**
```bash
source .env
curl -X POST "${FARGATE_NR_BASE}/api/chaos/slow-query?enable=true&duration_ms=5000"
```
1. ブラウザで `http://localhost:8083/devices` と `/devices/TKY-CORE-001` を開く
2. NR Browser > Page views で `/devices/{id}` のロード時間悪化を確認
3. APM の Response time P99 と比較（Browser は実ブラウザ時間 / APM はサーバー処理時間）
```bash
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"
```

**シナリオ 2: Error Inject 時の HTTP エラー記録**
```bash
source .env
curl -X POST "${FARGATE_NR_BASE}/api/chaos/error-inject?rate=30"
```
1. ブラウザで `/devices` を数回リロード
2. NR Browser > HTTP Errors で HTTP 500 が記録されているか確認
3. APM の Error rate と照合
```bash
curl -X POST "${FARGATE_NR_BASE}/api/chaos/reset"
```

---

### 6-4. EC2 環境との NR Browser 比較

NR Browser は両環境で同等に動作する。EC2 と Fargate の比較ポイント：

```sql
-- EC2 と Fargate の Page load 時間比較
SELECT average(duration) FROM PageView
WHERE appName LIKE '%netwatch-ui%'
FACET appName
SINCE 1 hour ago TIMESERIES 5 minutes
```

---

## 7. トランザクションデータ生成

`scripts/load.sh` はベンチマーク目的の負荷テストではなく、APM に調査対象のトレース、エラー、レイテンシ、スループット変化を記録させるための補助スクリプトです。

### 使い方

```bash
source .env   # FARGATE_NR_BASE を読み込む

# Fargate NR 環境のみにトランザクションを送る
EC2_AS_BASE="" FARGATE_AS_BASE="" EC2_NR_BASE="" ./scripts/load.sh normal-device-detail

# 全環境に同時送信して比較
make load
```

### NRQL でリアルタイム確認

```sql
-- Fargate NR 4サービスのスループット推移
SELECT rate(count(*), 1 minute) FROM Transaction
WHERE appName LIKE '%(eks-fargate-newrelic)'
FACET appName
SINCE 30 minutes ago TIMESERIES 1 minute

-- EC2 と Fargate の P99 比較（NR 環境のみ）
SELECT percentile(duration, 99) FROM Transaction
WHERE appName LIKE '%device-api%'
FACET appName
SINCE 30 minutes ago TIMESERIES 1 minute
```

---

## 8. 設計チェックリスト

### APM（New Relic APM）

- [ ] 4サービスが APM に表示される（名前に `(eks-fargate-newrelic)` が含まれる）
- [ ] Service Map でサービス間の依存グラフが表示される
- [ ] Apdex スコアが正常時に > 0.9 であることを確認した
- [ ] Slow Query 時に device-api Response time P99 が 5000ms 以上になることを確認した
- [ ] **Transaction Traces に遅いトランザクションが自動キャプチャされることを確認した**
- [ ] Error Inject 時に device-api Error rate が設定値に比例することを確認した
- [ ] エラーが netwatch-ui 側にも伝播することを確認した

### 分散トレース（NR Distributed Tracing）

- [ ] 3ホップトレース（netwatch-ui → device-api → metrics-collector）を確認した
- [ ] Slow Query 時に device-api span が長くなることを確認した
- [ ] Error Inject 時にエラー span が確認できた
- [ ] EC2 環境と同じ Waterfall 構造であることを確認した（APM 計装は同一）

### Errors Inbox

- [ ] **Error Inject 後に Errors Inbox でエラーグループが自動作成されることを確認した**
- [ ] エラーグループから Distributed Tracing へリンクできることを確認した

### ログ（制約の確認）

- [ ] **NR Logs が Fargate 環境では利用できないことを確認した（DaemonSet 制約）**
- [ ] APM トレース詳細の Logs タブが空になることを確認した
- [ ] 代替手段として `kubectl logs` で構造化ログを確認した

### Kubernetes Explorer（制約の確認）

- [ ] **Kubernetes Explorer に `eks-fargate-newrelic` Namespace のデータが表示されないことを確認した**
- [ ] EC2 環境（`eks-ec2-newrelic`）との差分を確認した（提案資料の根拠として使用）

### NR Browser

- [ ] NR Browser コンソールで Page views・Core Web Vitals を確認した
- [ ] Slow Query 時の Page load 時間悪化を Browser で確認した
- [ ] Error Inject 時の HTTP エラーが Browser に記録されることを確認した

### EC2 環境との比較

- [ ] 同一シナリオで EC2 + NR と Fargate + NR の APM メトリクスを NRQL で並べて比較した
- [ ] NR Logs・Kubernetes Explorer・NR Flex がすべて Fargate で利用不可であることを確認した
- [ ] APM（トレース・エラー）は EC2 と同等であることを確認した

---

## 9. NR Alerts / Service Levels 設計イメージ

### Service Levels（SLO）設定例

APM > 対象サービス > Service Levels から作成。Fargate 環境でも同一の操作で設定可能。

#### SLO 例 1: netwatch-ui 可用性 99.9%

```
SLI: Request success rate
条件: HTTP status code < 500
目標: 99.9%
期間: 28日間ローリング
対象: appName = 'netwatch-ui (eks-fargate-newrelic)'
```

#### SLO 例 2: device-api P99 Latency < 2000ms

```
SLI: Response time
条件: duration < 2.0
目標: 99%
期間: 7日間ローリング
対象: appName = 'device-api (eks-fargate-newrelic)'
```

---

### NR Alerts（NRQL ベース）設定例

#### Alert 例 1: device-api Error rate > 5%

```sql
SELECT percentage(count(*), WHERE error = true) FROM Transaction
WHERE appName = 'device-api (eks-fargate-newrelic)'
```
- 条件: `> 5` (%)
- 評価期間: 5分

#### Alert 例 2: Alert Storm 検知（Throughput スパイク）

```sql
SELECT rate(count(*), 1 minute) FROM Transaction
WHERE appName = 'alert-api (eks-fargate-newrelic)'
```
- 条件: `> 10` (req/min)
- 評価期間: 1分

#### Alert 例 3: Apdex スコア < 0.7

```sql
SELECT apdex(duration, t:0.5) FROM Transaction
WHERE appName = 'netwatch-ui (eks-fargate-newrelic)'
```
- 条件: `< 0.7`
- 評価期間: 5分

---

## 10. EC2 + New Relic 環境との比較まとめ

| 観点 | eks-ec2-newrelic | **eks-fargate-newrelic** |
|------|-----------------|--------------------------|
| **APM / 分散トレース** | ✅ | ✅ 同等 |
| **Errors Inbox** | ✅ | ✅ 同等 |
| **Transaction Traces** | ✅ | ✅ 同等 |
| **NR Browser** | ✅ | ✅ 同等 |
| **SLO（Service Levels）** | ✅ | ✅ 同等 |
| **NR Alerts（NRQL）** | ✅ | ✅ 同等 |
| Kubernetes Explorer | ✅ Pod + Node | ❌ 利用不可 |
| Pod / Node メトリクス | ✅ | ❌ 利用不可 |
| NR Logs（全文検索） | ✅ | ❌ 利用不可 |
| Logs in Context | ✅ 1クリック | ❌（ログデータなし） |
| NR Flex カスタムメトリクス | ✅ | ❌ 利用不可 |
| **インフラ調査コスト** | APM → Kubernetes Explorer → Logs | APM + kubectl logs のみ |

### PoC での活用ポイント

1. **APM 機能は EC2 と同等** → Fargate でも NR の APM 強みを体験できる
2. **インフラ・ログ機能は利用不可** → Fargate 採用時は CloudWatch Container Insights（App Signals 環境）との組み合わせを検討するか、NR の DaemonSet 対応を待つ判断材料になる
3. **比較提案への活用** → EC2 採用 vs Fargate 採用のオブザーバビリティ差分を定量的に示せる

---

*このガイドは `eks-fargate-newrelic` 環境専用の検証手順書です。他環境のガイドは [lab-eks-ec2-appsignals.md](lab-eks-ec2-appsignals.md) / [lab-eks-ec2-newrelic.md](lab-eks-ec2-newrelic.md) / [lab-eks-fargate-appsignals.md](lab-eks-fargate-appsignals.md) を参照してください。*
