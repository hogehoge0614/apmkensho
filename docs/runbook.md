# NetWatch 運用 Runbook

> 対象システム: NetWatch（ネットワーク機器監視 PoC）  
> 対象環境: `eks-ec2-appsignals` / `eks-fargate-appsignals` / `eks-ec2-newrelic` / `eks-fargate-newrelic`  
> EKS クラスター: `obs-poc` / リージョン: `ap-northeast-1`  
> 最終更新: 2026-04-30

---

## サービス構成早見表

| サービス名 | 役割 | 公開方式 | ポート |
|---|---|---|---|
| netwatch-ui | Web UI（FastAPI + Jinja2） | LoadBalancer | 8080 |
| device-api | 機器情報 API（RDS PostgreSQL） | ClusterIP | 8000 |
| metrics-collector | メトリクス収集 API | ClusterIP | 8000 |
| alert-api | アラート管理 API（インメモリ） | ClusterIP | 8000 |

---

## ハンズオンでの使い方

この Runbook は「異常を先に検知し、APM で影響範囲と原因を絞り込む」流れを練習するためのものです。`make load-*` は負荷テストではなく、APM に調査対象のトランザクションを記録させるための再現操作として使います。

| シナリオ | 最初のアラート例 | APM で特定すること | 根本原因の裏取り |
|----------|------------------|--------------------|------------------|
| Slow Query | Latency P99 閾値超過、SLO / Service Level 悪化 | `device-api` の DB 処理が遅く、`netwatch-ui` に波及していること | App Signals は X-Ray + Logs、New Relic は Transaction Traces / Databases |
| Error Inject | 5xx エラー率閾値超過、ERROR ログ増加、Canary FAIL | 500 の起点が `device-api` で、`netwatch-ui` は下流エラーを受けていること | App Signals は fault trace + Logs、New Relic は Errors Inbox + trace + Logs in Context |
| Alert Storm | `alert-api` の Throughput / RequestCount / ログ量 / CPU 急増 | 急増の中心が `alert-api` で、影響が `/alerts` 系に閉じているか | EC2 はログ/インフラ監視まで同一ツールで確認しやすく、Fargate は APM と Pod/Fargate ログ中心 |

各環境の具体的な画面遷移は、対応する `docs/lab-*.md` の「アラート起点の調査シナリオ」を参照してください。

---

## 1. Tier1 対応手順

### 1.1 異常検知（アラートを受け取ったとき）

以下のいずれかのアラートを受信した場合に本手順を開始する。

**アラート発生元**

- **CloudWatch Synthetics Canary が FAIL**  
  Canary 名: `obs-poc-health-check`  
  監視対象エンドポイント: `/`、`/devices`、`/devices/TKY-CORE-001`、`/alerts`

- **CloudWatch Alarm 発火**  
  エラー率の閾値超過、またはレイテンシの閾値超過

---

### 1.2 Tier1 確認手順

#### Step 1: アラート内容の確認

受信したアラート通知（メール / SNS / Slack 等）から以下を記録する。

- 発生時刻（JST）
- 対象 URL
- Alarm 名
- Alarm の状態遷移（OK → ALARM）

---

#### Step 2: Synthetics Canary のステータス確認

**コンソール URL:**  
`https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#synthetics:canary/detail/obs-poc-health-check`

確認項目:

1. Canary ステータスが **FAILED** になっているか確認する
2. 「最近の実行」の一覧で、どのエンドポイントが失敗しているかを確認する
3. 失敗した実行の詳細を開き、**スクリーンショット**と**HAR ファイル**を確認する
4. エラーメッセージ（HTTP ステータスコード、タイムアウト等）を記録する

---

#### Step 3: CloudWatch Metrics / Container Insights で大きな異常を確認

**コンソール URL（Container Insights）:**  
`https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#container-insights:performance`

確認項目:

- **Pod 再起動**がないか（`container_restart_count` が増加していないか）
- **Node の CPU 使用率**が異常に高くないか（通常の 2 倍以上）
- **Node のメモリ使用率**が高騰していないか（80% 超）
- EKS クラスター: `obs-poc`、ネームスペース: `eks-ec2-appsignals` でフィルタリングする

---

#### Step 4: Application Signals で対象サービスを確認

**コンソール URL（Application Signals）:**  
`https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:services`

確認項目:

1. 4 サービス（`netwatch-ui`、`device-api`、`metrics-collector`、`alert-api`）のうち、ステータスが赤くなっているサービスを特定する
2. **エラー率**が上昇しているサービスを記録する
3. **レイテンシ（P99）**が通常より悪化しているサービスを記録する
4. **SLO 違反**が発生していないか確認する

---

#### Step 5: Tier2 へ連携

以下のテンプレートを使用して Tier2 に情報を渡す。

---

### 1.3 Tier1 が Tier2 に渡す情報テンプレート

```
【Tier1 → Tier2 連携情報】
発生時刻: YYYY-MM-DD HH:MM:SS JST
対象URL: http://
Alarm名: 
Canary状態: PASS / FAIL
  失敗エンドポイント: 
エラー率: %
レイテンシ（P99）: ms
影響サービス（推定）: 
影響範囲: （例: /devices エンドポイント全体、特定ユーザーのみ等）
Pod再起動: あり / なし
Node異常: あり / なし
備考:
スクリーンショット: [添付]
```

---

## 2. Tier2 対応手順

### 2.1 サービスマップで全体把握

#### Step 1: Application Signals > Service Map を開く

**コンソール URL:**  
`https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#application-signals:service-map`

時刻範囲を「アラート発生時刻の前後 30 分」に設定する。

---

#### Step 2: 赤いノード・赤いエッジを確認

- **赤いノード**: そのサービス自体でエラーまたはレイテンシ悪化が発生している
- **赤いエッジ**: サービス間の呼び出しでエラーまたはレイテンシ悪化が発生している
- どのサービスが起点になっているか（上流 → 下流の方向で確認）

---

#### Step 3: Service Detail を開く

異常が検出されたサービスのノードをクリックして **Service Detail** を開く。

---

#### Step 4: Operation 別の Latency / Error rate を確認

- **P90 / P99** が通常より悪化している Operation を特定する
- 通常の目安:
  - `GET /devices`: P99 < 500ms
  - `GET /devices/{id}`: P99 < 500ms
  - `GET /alerts`: P99 < 200ms
- P99 が 1 秒を超えている場合は Slow Query 系の問題を疑う
- Error rate が 1% を超えている場合は Error Inject 系の問題を疑う

---

#### Step 5: Trace を開く

1. **X-Ray コンソール URL:**  
   `https://ap-northeast-1.console.aws.amazon.com/xray/home?region=ap-northeast-1#/traces`

2. フィルター条件を設定する:
   ```
   service(id(name: "device-api", type: "AWS::EKS::Container"))
   ```
   または対象サービス名と時刻範囲でフィルタリング

3. **Sort by: Duration（降順）** にして遅い Trace を上位から確認する

4. Trace 詳細で各 span の duration を確認する:
   - どの span が全体の duration の大半を占めているか
   - 異常に長い span はどのサービスのどの処理か

5. エラーが発生している span の場合:
   - エラーの HTTP ステータスコード
   - エラーメッセージ（例: `500 Internal Server Error`）
   - エラーが発生したサービス名と Operation 名

---

#### Step 6: CloudWatch Logs で関連ログを確認

**Log Insights コンソール URL:**  
`https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#logsV2:logs-insights`

ロググループ: `/aws/containerinsights/obs-poc/application`

Trace ID でログを絞り込む:
```sql
fields @timestamp, service, level, message, trace_id, http_method, http_path, duration_ms
| filter trace_id = "1-xxxxxxxx-xxxxxxxxxxxxxxxxxxxx"
| sort @timestamp asc
```

ERROR / WARNING レベルのログを確認:
```sql
fields @timestamp, service, level, message, http_status, error_type
| filter level in ["ERROR", "WARNING"]
| sort @timestamp desc
| limit 50
```

---

#### Step 7: Container Insights で Pod 状態を確認

**コンソール URL:**  
`https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#container-insights:performance/EKS:Pod`

フィルター: クラスター `obs-poc`、ネームスペース `eks-ec2-appsignals`

確認項目:
- 対象 Pod（`device-api-*`、`netwatch-ui-*` 等）の CPU / Memory 使用率
- Pod の再起動回数（`container_restart_count`）
- Pod が Running 状態かどうか

---

### 2.2 Tier2 判断フロー

#### Slow Query 症状（レイテンシ高い、エラーなし）

```
レイテンシ急上昇
  └─ Trace で最も長い span はどこか？
       ├─ device-api の span が長い（DB 処理 or metrics-collector 呼び出し）
       │     └─ device-api 内部の DB クエリ span が長い → DB または Slow Query 設定の問題
       ├─ metrics-collector の span が長い
       │     └─ metrics-collector 側の問題（外部呼び出しや処理遅延）
       └─ netwatch-ui の span の大半が device-api 呼び出し待ち
             └─ device-api 側の問題（Tier3 へ詳細調査を依頼）
```

#### Error 症状（エラー率高い）

```
エラー率上昇
  └─ Service Map でエラーが発生しているサービスはどれか？
       ├─ device-api の Error rate が高い
       │     └─ device-api 側の問題（HTTP 500 が発生している）
       └─ netwatch-ui の Error rate が高いが device-api は正常
             └─ netwatch-ui 側の問題（UI 層の実装問題）
```

---

### 2.3 Tier2 が Tier3 に渡す情報テンプレート

```
【Tier2 → Tier3 連携情報】
悪化サービス: 
悪化Operation: 
Trace ID（代表例）: 1-xxxxxxxx-xxxxxxxxxxxxxxxxxxxx
遅いspan:
  - [サービス名] [Operation名] duration Xms
  - [サービス名] [Operation名] duration Xms
エラーspan:
  - [サービス名] [Operation名] HTTP XXX
関連ログ:
  - [timestamp] [level] message
  - [timestamp] [level] message
Pod/Nodeメトリクス:
  - 対象Pod: 
  - CPU: %
  - Memory: %
  - 再起動回数: 
原因候補:
  1. 
  2. 
```

---

## 3. Tier3 対応手順

### 3.1 アプリケーションログ詳細調査

**Log Insights コンソール URL:**  
`https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#logsV2:logs-insights`

ロググループ: `/aws/containerinsights/obs-poc/application`

---

#### エラーログ確認

```sql
fields @timestamp, service, level, message, http_method, http_path, http_status, error_type, trace_id
| filter level = "ERROR"
| sort @timestamp desc
| limit 100
```

---

#### slow_query ログ確認

```sql
fields @timestamp, service, message, duration_ms, http_path, trace_id
| filter message like "slow_query"
| sort duration_ms desc
| limit 50
```

---

#### alert_storm 確認

```sql
fields @timestamp, service, message, alert_count, trace_id
| filter message like "alert_storm"
| sort @timestamp desc
| limit 50
```

---

#### trace_id でのログ絞り込み

```sql
fields @timestamp, service, level, message, http_method, http_path, http_status, duration_ms
| filter trace_id = "1-xxxxxxxx-xxxxxxxxxxxxxxxxxxxx"
| sort @timestamp asc
```

---

#### error_injected フィールドの確認

```sql
fields @timestamp, service, message, error_injected, http_status, trace_id
| filter error_injected = true
| sort @timestamp desc
| limit 50
```

---

#### レイテンシ分布確認

```sql
fields @timestamp, service, http_path, duration_ms
| filter service = "device-api"
| filter ispresent(duration_ms)
| stats
    count() as request_count,
    avg(duration_ms) as avg_ms,
    pct(duration_ms, 50) as p50_ms,
    pct(duration_ms, 90) as p90_ms,
    pct(duration_ms, 99) as p99_ms,
    max(duration_ms) as max_ms
  by http_path
| sort avg_ms desc
```

---

### 3.2 カオスシナリオとの照合

#### Slow Query 症状の場合

`/chaos/state` エンドポイントで現在のカオス状態を確認する。

```bash
# kubectl exec 経由で確認
kubectl exec -n eks-ec2-appsignals -it deployment/device-api -- \
  python3 -c "
import urllib.request, json
resp = urllib.request.urlopen('http://localhost:8000/chaos/state')
print(json.dumps(json.loads(resp.read()), indent=2, ensure_ascii=False))
"
```

期待するレスポンス例（Slow Query ON の場合）:
```json
{
  "slow_query": true,
  "error_inject": false,
  "error_rate": 0.0
}
```

または Web UI の Chaos 画面（`http://<EC2_AS_BASE>/chaos`）でも確認可能。

---

#### Error Inject 症状の場合

Log Insights でエラーログの `error_injected` フィールドを確認する（上記クエリ参照）。

エラーログに `"error_injected": true` が含まれている場合、Chaos の Error Inject が有効になっている。

---

#### Alert Storm 症状の場合

```sql
fields @timestamp, service, message, alert_count
| filter service = "alert-api"
| filter message like "alert_storm_started"
| sort @timestamp desc
| limit 10
```

alert-api のログに `alert_storm_started` が記録されていれば、Alert Storm カオスが発動したことが確認できる。

---

### 3.3 暫定対応

#### Chaos ON が原因の場合

**方法 1: curl でリセット**
```bash
source .env
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"
# リセット後の状態確認
curl -s "${EC2_AS_BASE}/api/chaos/state" | python3 -m json.tool
```

**方法 2: Web UI のリセットボタン**  
ブラウザで `http://<EC2_AS_BASE>/chaos` を開き、「Reset All Chaos」ボタンをクリックする。

---

#### 本番障害を想定した暫定対応例

**Pod の再起動（device-api）:**
```bash
kubectl rollout restart deployment/device-api -n eks-ec2-appsignals
# ロールアウト完了を待機
kubectl rollout status deployment/device-api -n eks-ec2-appsignals
```

**Pod の再起動（netwatch-ui）:**
```bash
kubectl rollout restart deployment/netwatch-ui -n eks-ec2-appsignals
kubectl rollout status deployment/netwatch-ui -n eks-ec2-appsignals
```

**Pod の再起動（metrics-collector）:**
```bash
kubectl rollout restart deployment/metrics-collector -n eks-ec2-appsignals
kubectl rollout status deployment/metrics-collector -n eks-ec2-appsignals
```

**Pod の再起動（alert-api）:**
```bash
kubectl rollout restart deployment/alert-api -n eks-ec2-appsignals
kubectl rollout status deployment/alert-api -n eks-ec2-appsignals
```

**機器一覧エンドポイントを一時的に無効化する例:**  
本番では feature flag（環境変数 `DISABLE_DEVICE_LIST=true` など）を用いてトラフィックを遮断するか、インgressルールで当該パスを一時的に 503 返却にすることを検討する。

---

### 3.4 恒久対応の検討

| 項目 | 内容 | 優先度 |
|---|---|---|
| SLO / Alarm の閾値見直し | 現在の閾値が厳しすぎる / 緩すぎる場合は実際のトラフィックパターンに合わせて調整する | 中 |
| ログ改善 | `request_id`、`chaos_enabled` フィールドをすべてのサービスのログに追加してトレーサビリティを向上させる | 高 |
| Application Signals SLO の設定 | 各サービスの Operation 単位で SLO を設定し、バーンレートアラームを有効化する | 高 |
| Canary スクリプトの拡充 | 現在の 4 エンドポイントに加えて、POST 系や認証が必要なエンドポイントのカバレッジを追加する | 低 |
| ダッシュボードの整備 | 4 サービスの主要メトリクスを 1 画面で確認できる CloudWatch Dashboard を作成する | 中 |

---

## 4. 障害シナリオ別クイックリファレンス

### シナリオ A: device-api レイテンシ急上昇

**症状:** Application Signals で device-api の P99 が急上昇（通常 < 100ms → 5 秒以上）

**確認手順:**

1. Application Signals > `device-api` > Operation 別 Latency で `GET /devices`、`GET /devices/{id}` の P99 を確認する
2. X-Ray で duration が長い Trace を開き、どの span が遅いかを特定する
3. `kubectl exec` で `/chaos/state` を確認し、`slow_query: true` になっていないか確認する
4. Log Insights で `slow_query` ログを検索する（上記クエリ参照）
5. Container Insights で device-api Pod の CPU / Memory を確認する（リソース枯渇の可能性）

**チェック項目:**

- [ ] `/chaos/state` で `slow_query` が `true` になっていないか
- [ ] DB 接続数が上限に達していないか（CloudWatch メトリクス `DatabaseConnections`）
- [ ] device-api Pod が OOMKilled されていないか（`kubectl describe pod`）
- [ ] RDS の CPU / IOPS に異常がないか

---

### シナリオ B: device-api エラー率上昇

**症状:** Application Signals で device-api の Error rate が上昇（通常 0% → 30% 以上）

**確認手順:**

1. Application Signals > `device-api` > Operation 別 Error rate で `GET /devices`、`GET /devices/{id}` のエラー率を確認する
2. X-Ray でエラーになっている Trace を開き、HTTP ステータスコードとエラーメッセージを確認する
3. `kubectl exec` で `/chaos/state` を確認し、`error_inject: true` になっていないか確認する
4. Log Insights で `error_injected = true` のログを検索する（上記クエリ参照）
5. Synthetics Canary のスクリーンショットでエラーページの内容を確認する

**チェック項目:**

- [ ] `/chaos/state` で `error_inject` が `true` になっていないか（`error_rate` の値も確認）
- [ ] device-api Pod が正常に Running しているか（`kubectl get pods -n eks-ec2-appsignals`）
- [ ] DB への接続が失われていないか（接続エラーのログを確認）
- [ ] netwatch-ui 側のエラー率も上昇しているか（device-api 障害に引きずられているか）

---

### シナリオ C: alert-api スループット急増

**症状:** alert-api の request count が急増、ログボリュームが増加

**確認手順:**

1. Application Signals > `alert-api` > Request count のグラフを確認し、急増のタイミングを特定する
2. Log Insights で `alert_storm_started` ログを確認する（上記クエリ参照）
3. alert-api の `/alerts` エンドポイントに直接アクセスし、アラート件数を確認する:
   ```bash
   kubectl exec -n eks-ec2-appsignals -it deployment/alert-api -- \
     python3 -c "
   import urllib.request, json
   resp = urllib.request.urlopen('http://localhost:8000/alerts')
   data = json.loads(resp.read())
   print(f'アラート件数: {len(data)}')
   "
   ```
4. netwatch-ui のアラート画面でアラート一覧を確認する

**チェック項目:**

- [ ] alert-api のインメモリデータが 60 件以上のアラートを保持していないか
- [ ] Alert Storm カオスが有効になっていないか（`/chaos/state` は device-api に対して確認。alert-api に独立した chaos エンドポイントがある場合はそちらも確認）
- [ ] alert-api Pod のメモリ使用量が増加していないか（インメモリ保持のため）
- [ ] netwatch-ui の `/alerts` ページのレスポンスタイムが悪化していないか

---

### シナリオ D: Canary FAIL（外形監視アラート）

**症状:** CloudWatch Alarm が CanaryFailed をトリガー

**確認手順:**

1. Synthetics コンソールで失敗した実行の詳細を確認する（スクリーンショット・HAR ファイル）
2. どのエンドポイントが失敗しているかを特定する（`/`、`/devices`、`/devices/TKY-CORE-001`、`/alerts`）
3. 失敗しているエンドポイントに対応するサービスを特定する:
   - `/`、`/devices`、`/devices/TKY-CORE-001` → netwatch-ui → device-api
   - `/alerts` → netwatch-ui → alert-api
4. kubectl で対象サービスの Pod が Running かどうかを確認する:
   ```bash
   kubectl get pods -n eks-ec2-appsignals
   ```
5. LoadBalancer の External IP が変わっていないか確認する:
   ```bash
   kubectl get svc -n eks-ec2-appsignals netwatch-ui
   ```

**Application Signals との突き合わせ:**

Canary が FAIL している時刻に Application Signals のメトリクスを確認し、以下の相関を見る:

| Canary FAIL エンドポイント | 確認すべきサービス | 確認メトリクス |
|---|---|---|
| `/` | netwatch-ui | Error rate, Latency |
| `/devices` | netwatch-ui → device-api | device-api Error rate, Latency |
| `/devices/TKY-CORE-001` | netwatch-ui → device-api | device-api Error rate, Latency |
| `/alerts` | netwatch-ui → alert-api | alert-api Error rate, Latency |

Canary の FAIL と Application Signals のメトリクス悪化が同時刻に発生していれば、アプリケーション側の問題と判断できる。Canary のみ FAIL で Application Signals が正常な場合は、ネットワーク経路やロードバランサーの問題を疑う。

---

## 5. よく使うコマンド集

### kubectl

```bash
# Pod状態確認
kubectl get pods -n eks-ec2-appsignals

# Pod状態確認（詳細・再起動回数含む）
kubectl get pods -n eks-ec2-appsignals -o wide

# 全サービスのエンドポイント確認
kubectl get svc -n eks-ec2-appsignals

# Pod の詳細確認（OOMKilled, イベント等）
kubectl describe pod -n eks-ec2-appsignals <pod-name>

# ログ確認（直近 50 行）
kubectl logs -n eks-ec2-appsignals -l app=device-api --tail=50

# ログ確認（netwatch-ui）
kubectl logs -n eks-ec2-appsignals -l app=netwatch-ui --tail=50

# ログ確認（metrics-collector）
kubectl logs -n eks-ec2-appsignals -l app=metrics-collector --tail=50

# ログ確認（alert-api）
kubectl logs -n eks-ec2-appsignals -l app=alert-api --tail=50

# ログをリアルタイムで追う
kubectl logs -n eks-ec2-appsignals -l app=device-api -f

# Chaos状態確認（device-api）
kubectl exec -n eks-ec2-appsignals -it deployment/device-api -- \
  python3 -c "
import urllib.request, json
resp = urllib.request.urlopen('http://localhost:8000/chaos/state')
print(json.dumps(json.loads(resp.read()), indent=2, ensure_ascii=False))
"

# Pod再起動（device-api）
kubectl rollout restart deployment/device-api -n eks-ec2-appsignals

# Pod再起動（netwatch-ui）
kubectl rollout restart deployment/netwatch-ui -n eks-ec2-appsignals

# Pod再起動（metrics-collector）
kubectl rollout restart deployment/metrics-collector -n eks-ec2-appsignals

# Pod再起動（alert-api）
kubectl rollout restart deployment/alert-api -n eks-ec2-appsignals

# ロールアウト完了待機
kubectl rollout status deployment/device-api -n eks-ec2-appsignals

# デプロイメント一覧確認
kubectl get deployments -n eks-ec2-appsignals
```

### AWS CLI

```bash
# Canary状態確認
aws synthetics get-canary \
  --name obs-poc-health-check \
  --region ap-northeast-1

# Canary の最新実行結果確認
aws synthetics get-canary-runs \
  --name obs-poc-health-check \
  --region ap-northeast-1 \
  --query 'CanaryRuns[0]'

# Canary停止（コスト削減）
aws synthetics stop-canary \
  --name obs-poc-health-check \
  --region ap-northeast-1

# Canary開始
aws synthetics start-canary \
  --name obs-poc-health-check \
  --region ap-northeast-1

# Application Signalsメトリクス確認（device-api）
aws cloudwatch list-metrics \
  --namespace ApplicationSignals \
  --dimensions Name=Service,Value=device-api \
  --region ap-northeast-1

# CloudWatch Alarm 一覧確認
aws cloudwatch describe-alarms \
  --region ap-northeast-1 \
  --state-value ALARM \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Reason:StateReason}'

# EKS クラスター情報確認
aws eks describe-cluster \
  --name obs-poc \
  --region ap-northeast-1 \
  --query 'cluster.{Status:status,Endpoint:endpoint,Version:version}'

# kubeconfig 更新（EKS クラスターに接続）
aws eks update-kubeconfig \
  --name obs-poc \
  --region ap-northeast-1
```

### Chaos リセット

```bash
# .env を読み込む（EC2_AS_BASE などの変数を設定）
source .env

# Chaos 全リセット
curl -X POST "${EC2_AS_BASE}/api/chaos/reset"

# Chaos 状態確認
curl -s "${EC2_AS_BASE}/api/chaos/state" | python3 -m json.tool

# Slow Query のみ有効化（確認用）
curl -X POST "${EC2_AS_BASE}/api/chaos/slow-query" \
  -H "Content-Type: application/json" \
  -d '{"enabled": true}'

# Error Inject のみ有効化（エラー率 30% の例）
curl -X POST "${EC2_AS_BASE}/api/chaos/error-inject" \
  -H "Content-Type: application/json" \
  -d '{"enabled": true, "error_rate": 0.3}'

# Alert Storm 発動
curl -X POST "${EC2_AS_BASE}/api/chaos/alert-storm"
```

---

## 6. CloudWatch Logs Insights クエリ集

**ロググループ:** `/aws/containerinsights/obs-poc/application`

---

### エラーログ集計（直近 1 時間）

```sql
-- 用途: どのサービスで何件エラーが発生しているかを素早く把握する
fields @timestamp, service, level, message, http_method, http_path, http_status
| filter level = "ERROR"
| stats count() as error_count by service, http_path, http_status
| sort error_count desc
```

---

### slow_query ログ（遅いクエリの確認）

```sql
-- 用途: Slow Query カオスが発動しているか、または実際に遅いクエリが発生しているかを確認する
fields @timestamp, service, message, duration_ms, http_path, trace_id
| filter message like /slow_query/
| sort duration_ms desc
| limit 50
```

---

### error_injected ログ（Error Inject カオスの確認）

```sql
-- 用途: Error Inject カオスによって意図的に生成されたエラーを特定する
fields @timestamp, service, message, error_injected, http_status, http_path, trace_id
| filter error_injected = true
| stats count() as injected_count by service, http_path, http_status
| sort injected_count desc
```

---

### alert_storm ログ（Alert Storm カオスの確認）

```sql
-- 用途: Alert Storm カオスがいつ発動したかを確認する
fields @timestamp, service, message, alert_count
| filter service = "alert-api"
| filter message like /alert_storm/
| sort @timestamp desc
| limit 20
```

---

### trace_id でのログ絞り込み（特定リクエストのフルトレース）

```sql
-- 用途: X-Ray で特定した問題のある Trace に対応するアプリケーションログを全サービス横断で確認する
-- trace_id は X-Ray コンソールからコピーする（例: 1-661a2b3c-abcdef1234567890abcdef12）
fields @timestamp, service, level, message, http_method, http_path, http_status, duration_ms
| filter trace_id = "1-xxxxxxxx-xxxxxxxxxxxxxxxxxxxx"
| sort @timestamp asc
```

---

### レイテンシ分布（サービス・パス別）

```sql
-- 用途: 各サービスのエンドポイント別のレイテンシ分布を確認し、遅いエンドポイントを特定する
fields @timestamp, service, http_path, duration_ms
| filter ispresent(duration_ms)
| filter ispresent(http_path)
| stats
    count() as request_count,
    avg(duration_ms) as avg_ms,
    pct(duration_ms, 50) as p50_ms,
    pct(duration_ms, 90) as p90_ms,
    pct(duration_ms, 99) as p99_ms,
    max(duration_ms) as max_ms
  by service, http_path
| sort avg_ms desc
```

---

### サービス別ログ件数 / 分（ログ量の急増を検出）

```sql
-- 用途: Alert Storm や急激なトラフィック増加によってログ量が増加していないかを確認する
fields @timestamp, service
| filter ispresent(service)
| stats count() as log_count by service, bin(1min)
| sort @timestamp desc
```

---

### 直近のエラーサマリー（全サービス）

```sql
-- 用途: 現在の障害状況を素早く把握するためのトップレベルサマリー
fields @timestamp, service, level, message, http_status, trace_id
| filter level in ["ERROR", "WARNING"]
| sort @timestamp desc
| limit 100
```

---

### HTTP 5xx エラーのエンドポイント別集計

```sql
-- 用途: どのエンドポイントで 5xx エラーが最も多く発生しているかを把握する
fields @timestamp, service, http_method, http_path, http_status
| filter http_status >= 500
| stats count() as error_count by service, http_method, http_path, http_status
| sort error_count desc
```

---

*このRunbookはNetWatch PoC専用です。本番環境への適用時は各種閾値・エンドポイント・クラスター名を実環境に合わせて修正してください。*
