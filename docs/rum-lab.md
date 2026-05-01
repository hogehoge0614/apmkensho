# CloudWatch RUM ハンズオン

CloudWatch RUM（Real User Monitoring）は、実際のブラウザセッションのパフォーマンス・エラー・HTTP リクエストを収集するサービスです。このラボでは RUM を有効化し、ブラウザ側のテレメトリが CloudWatch に届くことを確認します。

## アーキテクチャ

```
Browser
  → JS snippet (AwsRumClient) が自動ロード
  → ページロード / エラー / fetch を検知
  → Cognito Identity Pool で認証（匿名）
  → CloudWatch RUM データプレーン (dataplane.rum.ap-northeast-1.amazonaws.com)
  → CloudWatch RUM コンソール
```

## 前提条件

- `make ec2-appsignals-deploy` が完了していること
- `.env` に以下が設定されていること:
  ```
  CW_RUM_APP_MONITOR_ID=<UUID>
  CW_RUM_IDENTITY_POOL_ID=ap-northeast-1:<UUID>
  CW_RUM_REGION=ap-northeast-1
  ```

## Step 1 — RUM の値を確認する

```bash
# Terraform output から取得
terraform -chdir=infra/terraform output rum_app_monitor_id
terraform -chdir=infra/terraform output cognito_identity_pool_id
```

取得した値を `.env` に設定する。

## Step 2 — RUM を有効化する

```bash
make ec2-appsignals-enable-rum
```

内部では netwatch-ui Deployment の環境変数に RUM 設定値を注入し、ロールアウト再起動する。

## Step 3 — 動作確認

1. ブラウザで `http://<EC2_BASE>/rum-test` を開く
2. サイドバーの **RUM Test** をクリック
3. ページ上部のステータスが **ENABLED** になっていることを確認
4. `✓ AwsRumClient 初期化済み` が表示されることを確認

## Step 4 — テレメトリを発生させる

`/rum-test` 画面の各ボタンを押す:

| ボタン | 発生するテレメトリ |
|--------|-------------------|
| JavaScript エラー | `window.onerror` → RUM Errors タブ |
| HTTP エラー (404) | `fetch /api/devices/NONEXISTENT` → RUM HTTP タブ |
| カスタムイベント | `cwr('recordEvent', ...)` → カスタムイベント |
| リロード | LCP / FID / CLS → RUM Performance タブ |

## Step 5 — CloudWatch コンソールで確認

1. CloudWatch → **Application monitoring → RUM**
2. App Monitor（`obs-poc` または `netwatch`）を選択
3. 各タブを確認:

### Performance タブ
- **Page load steps**: DNS lookup / TCP connection / TLS / TTFB / FCP / LCP
- Core Web Vitals の分布

### Errors タブ
- JavaScript errors: 発生したエラーのスタックトレース
- HTTP errors: 4xx/5xx レスポンスの一覧

### HTTP requests タブ
- 各エンドポイントへのリクエスト数・エラー率・レイテンシ

### User sessions タブ
- セッション単位のイベントタイムライン
- X-Ray トレースとの連携（enableXRay: true の効果）

## Step 6 — X-Ray との連携を確認

RUM snippet に `enableXRay: true` を設定しているため、ブラウザから発行される HTTP リクエストに `X-Amzn-Trace-Id` ヘッダが自動付与される。

1. **User sessions** → セッションを選択
2. HTTP リクエストの行をクリック
3. **View in X-Ray** リンクをクリック
4. ブラウザ → netwatch-ui → device-api → metrics-collector の全体トレースを確認

## トラブルシューティング

| 症状 | 確認箇所 |
|------|---------|
| `✗ AwsRumClient 未検出` | ブラウザの Network タブで `cwr.js` のロードを確認 |
| CORS エラー | Cognito Identity Pool の認証プロバイダーに RUM のドメインが含まれているか |
| RUM データが届かない | CloudWatch コンソールで App Monitor の Status が Active か確認 |
| `CW_RUM_APP_MONITOR_ID` 未設定 | `kubectl exec deploy/netwatch-ui -n demo-ec2 -- env | grep CW_RUM` |

## 後片付け

RUM を無効化するには `.env` の RUM 変数を空にして再デプロイ:
```bash
# .env の CW_RUM_APP_MONITOR_ID を削除または空にする
make ec2-appsignals-deploy
```
