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
 SECTION 2-APM: New Relic APM 特化機能（CW との有意差検証）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[シナリオA] エラー分析の深度 — Errors Inbox vs X-Ray

  事前操作:
    for i in $(seq 1 25); do curl -s http://localhost:8080/api/checkout/payment-error > /dev/null; done

  [NR] APM > [payment-api] > Errors Inbox
  確認:
  - エラーが fingerprint で自動グルーピングされているか（同種エラーをまとめて表示）
  - Python の full stack trace が取得できているか（ファイル名・行番号まで）
  - occurrence count, First seen / Last seen が自動記録されているか
  - Resolved / Ignored / Assigned でステータス変更できるか

  [CW] X-Ray > Traces > Filter: Error = true
  確認:
  - 個別トレースを1件ずつ開いて確認するしかないか
  - エラーのグルーピング・集計機能はあるか

  比較ポイント:
  □ 同じエラーが 25 回発生した時、NR は何グループに集約されるか
  □ CW で「このエラーは昨日から何回発生しているか」を把握するのに何ステップかかるか

---

[シナリオB] 遅いトランザクションの自動検出 — Transaction Traces vs X-Ray 手動フィルタ

  事前操作:
    for i in $(seq 1 30); do curl -s http://localhost:8080/api/checkout/slow-payment > /dev/null; done

  [NR] APM > [backend-for-frontend] > Transaction Traces
  確認:
  - 遅い実行が自動的にリストアップされているか
  - Trace 詳細の Breakdown Table で FastAPI ルート・httpx 呼び出しごとの時間が見えるか
  - payment-api への httpx 呼び出しが何% の時間を占めているかが一目でわかるか

  [CW] X-Ray > Traces > Sort by duration (降順)
  確認:
  - 遅いトレースを手動で並び替えて探す必要があるか
  - スパン間の「空白時間（待ち時間）」の原因が読み取れるか

  比較ポイント:
  □ "payment-api の呼び出しが遅い" という結論に到達するまでのクリック数
  □ NR Breakdown Table の粒度 vs X-Ray のスパンリストの粒度

---

[シナリオC] Logs in Context の操作性

  事前操作: checkout/payment-error または slow-payment を数回実行

  [NR] トレース → ログへの1クリック移動
  手順:
  1. APM > [payment-api] > Distributed Tracing で任意のトレースを選択
  2. payment-api スパンを選択 → 右パネルの "Logs" タブをクリック
  3. そのスパン時刻範囲内のログが自動表示されるか確認
  4. ログエントリを選択 → "View span in APM" で逆引きナビゲーションができるか

  [CW] トレース → ログへの手動移動
  手順:
  1. X-Ray で任意のトレースの trace_id をコピー
  2. CloudWatch Logs Insights を開き以下のクエリを手動入力:
       fields @timestamp, service_name, trace_id, message
       | filter trace_id = "<コピーした trace_id>"
  3. 結果を確認

  比較ポイント:
  □ トレースからそのトレースのログに到達するまでの操作手順数
  □ ログからトレースへの逆引きが両ツールで可能か

---

[シナリオD] サービスマップの情報密度

  事前操作: make load（全シナリオ混在、5 分以上）

  [NR] APM > Service Map
  確認:
  - 各ノードに Apdex スコアが表示されているか（0–1 のスコア）
  - スループット（rpm）が各ノードに表示されるか
  - External Services として external-api-simulator が別枠で詳細表示されるか
  - APM > [order-api] > External services でレスポンスタイムの breakdown が見えるか

  [CW] Application Signals > Service Map
  確認:
  - ノードに表示される指標は何か（レイテンシ・エラー率のみか）
  - Apdex に相当するユーザー体感スコアはあるか

  比較ポイント:
  □ サービスマップ上で "最も問題のあるサービス" を直感的に特定できるか
  □ Apdex の有無が障害トリアージの速度に影響するか

---

[シナリオE] アラート定義の柔軟性

  [NR] Alerts > Create alert condition
  操作:
  1. "Write your own query" を選択
  2. 以下の条件をそれぞれ作成してみる:
     - payment-api の p99 レイテンシ > 2 秒:
         SELECT percentile(duration, 99) FROM Transaction
         WHERE appName = 'payment-api'
     - エラー率 5% 超え:
         SELECT percentage(count(*), WHERE error IS true) FROM Transaction
         WHERE appName = 'payment-api'
     - 特定エンドポイントのみ (/pay/error):
         SELECT count(*) FROM Transaction
         WHERE request.uri LIKE '/pay/error' AND error IS true
  確認: 条件の自由度・プレビューで閾値を視覚確認できるか

  [CW] CloudWatch Alarms > Create alarm
  操作:
  - 同等の条件を CloudWatch Alarm で設定してみる
  - Application Signals メトリクスのディメンション指定の複雑さを確認
  比較ポイント:
  □ "payment-api の /pay/error エンドポイントのみのエラー率" をアラート化できるか
  □ アラート条件の定義にかかる時間とステップ数

---

[シナリオF] 自動異常検知の感度

  事前操作:
    # 正常トラフィックを 5 分流す
    make load
    # 異常を注入（slow-payment を集中させる）
    for i in $(seq 1 50); do curl -s http://localhost:8080/api/checkout/slow-payment > /dev/null; sleep 1; done

  [NR] Applied Intelligence > Lookout（または APM > Lookout）
  確認:
  - 事前設定なしで backend-for-frontend の異常が自動検出されるか
  - どのシグナル（レイテンシ・エラー率・スループット）の異常が検出されるか
  - 関連エンティティ（payment-api）まで自動的に相関が示されるか

  [CW] CloudWatch > Anomaly Detection
  確認:
  - Anomaly Detection を使うために何の事前設定が必要か
  - Application Signals メトリクスに自動的に適用されているか

  比較ポイント:
  □ "設定ゼロで異常を自動検出できるか" の差
  □ 複数サービスにまたがる異常の相関を自動で示せるか

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 3: 比較ポイント まとめ
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

── APM 機能（NR が有意差を出しやすい領域） ──────────────────────────────

□ エラー分析: 25 回エラー発生後、NR Errors Inbox でグルーピングされるか・stack trace が取れるか
□ 遅いTX自動検出: slow-payment 実行後、NR Transaction Traces が自動キャプチャするか
□ Logs in Context: トレース → ログへの到達クリック数（NR vs CW の手動 trace_id 検索）
□ Apdex: slow-payment で Apdex スコアが下がるタイミングが視覚的に分かるか
□ サービスマップ情報密度: ノードの情報量・external-api-simulator の可視性の差
□ アラート柔軟性: "/pay/error エンドポイントのみのエラー率" を両ツールでアラート化できるか
□ 自動異常検知: 設定ゼロで異常が検出されるか（NR Lookout vs CW Anomaly Detection）

── その他比較ポイント ──────────────────────────────────────────────────

□ トレース見やすさ: 1画面でサービス間依存とスパン時間が比較できるか
□ ボトルネック特定: slow-payment 実行後、どちらが速く原因を指し示すか
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
