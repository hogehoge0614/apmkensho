#!/usr/bin/env bash

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
NR_ACCOUNT_ID="${NEW_RELIC_ACCOUNT_ID:-YOUR_ACCOUNT_ID}"

cat <<'EOF'
========================================================================
 Observability PoC Compare-Check Guide
 CloudWatch + Application Signals  vs  New Relic Full Stack
========================================================================

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 1: CloudWatch + Application Signals (AWS Console)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[1-A] Application Signals - Service Map
  URL: CloudWatch > Application Signals > Services
  観点:
  - frontend-ui → backend-for-frontend → order-api/inventory-api/payment-api の依存グラフが見えるか
  - external-api-simulator が外部依存として見えるか
  - ノードのレイテンシ・エラー率がリアルタイムで更新されるか
  確認シナリオ: checkout/slow-payment を実行してpayment-apiが赤くなるか

[1-B] Application Signals - Traces
  URL: CloudWatch > Application Signals > Services > [service] > Traces
  観点:
  - 単一リクエストのエンドツーエンドトレースが見えるか
  - 各スパンの所要時間が棒グラフで確認できるか
  - checkout/slow-inventory でinventory-apiのスパンが長くなるか
  - checkout/payment-error でpayment-apiにエラーが表示されるか
  - trace_id でログとの相関ができるか

[1-C] CloudWatch Container Insights
  URL: CloudWatch > Insights > Container Insights
  観点:
  - demo-ec2 namespace のPod CPU/Memoryが見えるか
  - demo-fargate namespace のPod CPU/Memoryが見えるか (制約あり)
  - Kubernetes Service Mapが表示されるか
  EC2 vs Fargate 差分: Fargateは拡張メトリクスが制限される

[1-D] CloudWatch Logs
  URL: CloudWatch > Logs > Log groups > /obs-poc/demo-ec2/application
  観点:
  - 構造化JSONログが出力されているか
  - trace_id フィールドを含むか (Logs in Context)
  - Log Insights で "filter status_code >= 400" が使えるか
  - CloudWatch Logs Insights クエリ例:
    fields @timestamp, service_name, endpoint, status_code, latency_ms, trace_id
    | filter status_code >= 400
    | sort @timestamp desc

[1-E] CloudWatch RUM
  URL: CloudWatch > RUM > App Monitors > obs-poc-rum
  観点:
  - ページビュー数が記録されているか
  - JavaScriptエラーが捕捉されるか (Trigger JS Error ボタンを押す)
  - Core Web Vitals (LCP/FID/CLS) が記録されるか
  - APIコールのタイミングが記録されるか
  - セッション単位でのユーザー行動が追跡できるか

[1-F] CloudWatch Synthetics
  URL: CloudWatch > Synthetics > Canaries
  観点:
  - obs-poc-health-check の実行履歴が見えるか
  - 成功/失敗率が記録されているか
  - スクリーンショット/HAR が保存されているか

[1-G] CloudWatch Dashboard
  URL: CloudWatch > Dashboards > obs-poc-observability-poc
  観点:
  - Application Signalsメトリクスが表示されているか
  - Container Insightsメトリクスが表示されているか
  - EC2 vs Fargate の並列比較が可能か

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 2: New Relic Full Stack
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[2-A] New Relic APM - Service List
  URL: https://one.newrelic.com/apm
  観点:
  - 全6サービス (frontend-ui, bff, order-api, inventory-api, payment-api, external-api-simulator) が表示されるか
  - Apdex, エラー率, スループットがリアルタイム更新されるか
  - EC2版とFargate版で別アプリとして表示されるか

[2-B] New Relic Distributed Tracing
  URL: https://one.newrelic.com/distributed-tracing
  観点:
  - frontend-ui → bff → order-api → payment-api のトレースが1画面で見えるか
  - checkout/slow-payment でpayment-apiスパンが赤く表示されるか
  - checkout/payment-error でエラーの原因サービスが一目で分かるか
  - external-api-simulator が外部サービスとして表示されるか
  - 検索: "trace.id = <trace_id>" で特定トレースを検索できるか

[2-C] New Relic Kubernetes
  URL: https://one.newrelic.com/kubernetes
  観点:
  - demo-ec2, demo-fargate namespace のPod一覧が見えるか
  - CPU/Memory 使用率がリアルタイムで更新されるか
  - Pod → APMサービスへのリンクが機能するか
  - Fargate側でのKubernetes情報の完全性 (EC2に比べて制約あり)

[2-D] New Relic Logs - Logs in Context
  URL: New Relic APM > [service] > Logs
  観点:
  - APMトレース画面からそのトレースのログに直接ジャンプできるか
  - trace_id でログとトレースが紐付くか
  - 構造化JSONログが正しくパースされているか
  - エラーログに "error_message" フィールドが含まれるか
  NR Logs検索クエリ例:
    service_name = 'payment-api' AND status_code >= 500

[2-E] New Relic Browser
  URL: https://one.newrelic.com/browser
  観点:
  - ページビュー数が記録されているか
  - JavaScriptエラーが捕捉されるか (Trigger JS Error ボタンを押す)
  - Core Web Vitals (LCP/FID/INP/CLS) が記録されるか
  - SessionTraceで操作の順序が再現できるか
  - AjaxコールとAPMトレースが紐付くか

[2-F] New Relic Synthetic
  URL: https://one.newrelic.com/synthetics
  観点:
  - obs-poc-health-check の実行履歴が見えるか
  - 応答時間トレンドが見えるか
  - 障害時にアラートが発火するか

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 3: 比較ポイント まとめ
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

□ トレース見やすさ: 1画面でサービス間依存とスパン時間が比較できるか
□ ボトルネック特定: slow-payment 実行後、どちらが速く原因を指し示すか
□ エラー特定: payment-error 実行後、どちらが根本原因を特定しやすいか
□ ログ相関: trace_id → ログ → スパンの往復ナビゲーションのしやすさ
□ Kubernetes状態: Pod CPU/Memory とAPMトレースの連携しやすさ
□ Fargate制約: EC2と比べてどの機能が使えないか/制約があるか
□ ダッシュボード: カスタマイズのしやすさ・デフォルトで見える情報量
□ 導入コスト: アプリ改修量、設定の複雑さ、学習コスト

EOF
echo "URL一覧 (実際のアカウントIDに置換してください):"
echo "  CloudWatch Application Signals:"
echo "    https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#application-signals:services"
echo "  CloudWatch Container Insights:"
echo "    https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#container-insights:performance"
echo "  New Relic APM:"
echo "    https://one.newrelic.com/apm"
echo "  New Relic Kubernetes:"
echo "    https://one.newrelic.com/kubernetes"
echo "  New Relic Distributed Tracing:"
echo "    https://one.newrelic.com/distributed-tracing"
