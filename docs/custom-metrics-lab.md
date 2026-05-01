# カスタムメトリクス (StatsD) ハンズオン

アプリケーションが StatsD プロトコルで送信するメトリクスを CloudWatch Agent が受信し、CloudWatch Metrics に転送するパイプラインを構築します。

## アーキテクチャ

```
App Pod
  → socket.sendto(UDP:8125) → STATSD_HOST (Node IP)
  → CloudWatch Agent (DaemonSet, each EC2 node)
  → CloudWatch Metrics (namespace: NetwatchPoC/Custom)
  → CloudWatch コンソール / アラーム / ダッシュボード
```

> **Fargate について**: DaemonSet は Fargate では動作しません。Fargate で StatsD メトリクスを使用する場合は、ADOT Collector をサイドカーとして注入する構成が必要です（本 PoC の範囲外）。

## 実装されているメトリクス

### netwatch-ui (`netwatch.ui.*`)

| メトリクス | タイプ | 説明 |
|------------|--------|------|
| `page.dashboard_ms` | timing | ダッシュボード表示レイテンシ |
| `page.devices_ms` | timing | 機器一覧表示レイテンシ |
| `page.device_detail_ms` | timing | 機器詳細表示レイテンシ |
| `page.alerts_ms` | timing | アラート一覧表示レイテンシ |
| `page.views` | counter | ページビュー数 |
| `error.count` | counter | 500 エラー発生数 |

### device-api (`netwatch.device.*`)

| メトリクス | タイプ | 説明 |
|------------|--------|------|
| `list_ms` | timing | デバイス一覧取得レイテンシ (DB込み) |
| `list_count` | counter | 取得デバイス数 |
| `detail_ms` | timing | デバイス詳細取得レイテンシ |

### alert-api (`netwatch.alert.*`)

| メトリクス | タイプ | 説明 |
|------------|--------|------|
| `list_ms` | timing | アラート一覧取得レイテンシ |
| `list_count` | counter | 取得アラート数 |

## Step 1 — CloudWatch Agent に StatsD を有効化する

```bash
make ec2-appsignals-enable-custom-metrics
```

これにより:
1. CloudWatch Agent に StatsD リスナー (UDP 8125) の設定を追加
2. Agent を再起動してポートを開放

## Step 2 — アプリのメトリクス送信を確認する

```bash
# netwatch-ui pod から STATSD_HOST と PORT を確認
kubectl exec deploy/netwatch-ui -n demo-ec2 -- env | grep STATSD

# 手動で UDP パケットを送信してテスト
kubectl exec -n demo-ec2 deploy/netwatch-ui -- python3 -c "
import socket, os
host = os.getenv('STATSD_HOST', 'localhost')
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b'netwatch.ui.test_counter:1|c', (host, 8125))
s.sendto(b'netwatch.ui.test_timing:150|ms', (host, 8125))
print(f'Sent to {host}:8125')
"
```

## Step 3 — トラフィックを生成してメトリクスを溜める

```bash
make load
# または特定シナリオ
make load-detail   # device detail (3ホップ) × ROUNDS回
```

## Step 4 — CloudWatch Metrics で確認

```bash
# CLI で確認
aws cloudwatch list-metrics \
  --namespace NetwatchPoC/Custom \
  --region ap-northeast-1

# 特定メトリクスの値を取得 (直近10分)
aws cloudwatch get-metric-statistics \
  --namespace NetwatchPoC/Custom \
  --metric-name netwatch.ui.page.views \
  --statistics Sum \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --region ap-northeast-1
```

コンソール: CloudWatch → **Metrics → All metrics → Custom namespaces → NetwatchPoC/Custom**

## Step 5 — アラームを作成する

例: device-api の DB クエリが 500ms を超えたらアラーム

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "device-api-slow-query" \
  --namespace "NetwatchPoC/Custom" \
  --metric-name "netwatch.device.list_ms" \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 500 \
  --comparison-operator GreaterThanThreshold \
  --alarm-description "device-api DB query latency > 500ms" \
  --region ap-northeast-1
```

## Step 6 — Chaos との組み合わせ

1. `/chaos` 画面で **Slow Query** を有効化 (3000ms)
2. `make load-slow` でトラフィックを発生させる
3. CloudWatch Metrics で `netwatch.device.list_ms` の値が上昇することを確認
4. App Signals のトレースとメトリクスを並べて比較

## トラブルシューティング

| 症状 | 確認箇所 |
|------|---------|
| メトリクスが届かない | `kubectl get pods -n amazon-cloudwatch` で Agent が Running か確認 |
| `STATSD_HOST` が `localhost` | Pod spec の `status.hostIP` fieldRef が設定されているか確認 |
| Agent が StatsD ポートを開放していない | `kubectl exec -n amazon-cloudwatch <cw-agent-pod> -- ss -ulnp \| grep 8125` |
| CloudWatchAgent CR が見つからない | enable-custom-metrics.sh の ConfigMap fallback が実行されているか確認 |
