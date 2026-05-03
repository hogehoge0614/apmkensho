# セットアップ・デプロイ手順

## 前提条件

以下のツールがインストール・設定済みであること:

```bash
aws --version        # >= 2.x（ap-northeast-1 アクセス可能なプロファイル設定済み）
kubectl version      # >= 1.28
helm version         # >= 3.x
terraform version    # >= 1.5
docker version       # >= 24.x（Docker Desktop 起動済み）
```

```bash
make check-prereq    # 上記ツールと AWS 認証情報を一括確認
```

## .env 設定

```bash
cp .env.example .env
```

`.env` を開いて以下を設定:

```bash
AWS_REGION=ap-northeast-1
AWS_ACCOUNT_ID=123456789012    # 自分の AWS アカウント番号（12桁）
CLUSTER_NAME=obs-poc

# New Relic 環境を構築する場合は以下も設定
NEW_RELIC_LICENSE_KEY=...
NEW_RELIC_ACCOUNT_ID=...
```

---

## 共通セットアップ（初回のみ・全環境共通）

### Step 1: インフラ構築（約20分）

```bash
make up
```

作成されるリソース: EKS クラスター、EC2 Node Group (t3.small × 2)、Fargate Profile、RDS PostgreSQL、VPC、ECR リポジトリ × 4、IAM ロール、Interface VPC Endpoints

### Step 2: Kubernetes シークレット作成

```bash
make create-secrets
```

RDS の接続情報（ホスト名・ユーザー・パスワード）を K8s Secret として作成します。

### Step 3: アプリイメージのビルド & ECR プッシュ（約10分）

```bash
make build-push
```

4サービス（netwatch-ui / device-api / alert-api / metrics-collector）を Docker でビルドして ECR にプッシュします。

---

## 環境別セットアップ

### [1] EKS on EC2 + App Signals（`eks-ec2-appsignals`）

```bash
make install-cloudwatch-full       # CloudWatch スタック（OTel Operator + ADOT + Fluent Bit）
make ec2-appsignals-deploy         # eks-ec2-appsignals namespace にデプロイ
make ec2-appsignals-verify         # Pod 起動・OTel init container の確認

# LoadBalancer URL を .env に追記
EC2_AS_LB=$(kubectl get svc netwatch-ui -n eks-ec2-appsignals \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "EC2_AS_BASE=http://${EC2_AS_LB}" >> .env && source .env

make load                          # トラフィック生成
```

オプション:
```bash
make ec2-appsignals-enable-rum             # CloudWatch RUM ブラウザ監視
make ec2-appsignals-enable-custom-metrics  # StatsD カスタムメトリクス
```

### [2] EKS on Fargate + App Signals（`eks-fargate-appsignals`）

> 前提: 共通手順（make up / make create-secrets / make build-push）が完了していること。

```bash
make install-cloudwatch-full       # EC2 環境と共用可
make fargate-appsignals-deploy     # eks-fargate-appsignals namespace にデプロイ
make fargate-appsignals-verify     # Pod 起動の確認

# LoadBalancer URL を .env に追記
FARGATE_AS_LB=$(kubectl get svc netwatch-ui -n eks-fargate-appsignals \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "FARGATE_AS_BASE=http://${FARGATE_AS_LB}" >> .env && source .env

make load
```

オプション:
```bash
make fargate-appsignals-enable-rum  # CloudWatch RUM ブラウザ監視
```

> **Fargate の制約:** DaemonSet 非対応のため StatsD カスタムメトリクスは未対応。CloudWatch Agent は Deployment として別途起動します。

### [3] EKS on EC2 + New Relic（`eks-ec2-newrelic`）

> 前提: `.env` に `NEW_RELIC_LICENSE_KEY` / `NEW_RELIC_ACCOUNT_ID` を設定済みであること。

```bash
make install-newrelic-full         # nri-bundle Helm + k8s-agents-operator インストール
make ec2-newrelic-deploy           # eks-ec2-newrelic namespace にデプロイ
make ec2-newrelic-verify           # NR Python Agent の注入確認

# LoadBalancer URL を .env に追記
EC2_NR_LB=$(kubectl get svc netwatch-ui -n eks-ec2-newrelic \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "EC2_NR_BASE=http://${EC2_NR_LB}" >> .env && source .env

make load
```

### [4] EKS on Fargate + New Relic（`eks-fargate-newrelic`）

> ⚠️ **APM トレースのみ。** Infrastructure Agent (DaemonSet) は Fargate 非対応のためインフラメトリクス・ログ転送は収集されません。  
> 詳細 → [`docs/environment-comparison.md`](environment-comparison.md)

> 前提: `make install-newrelic-full` が完了していること（`eks-ec2-newrelic` と共用）。

```bash
make fargate-newrelic-deploy       # eks-fargate-newrelic namespace にデプロイ
make fargate-newrelic-verify       # NR Python Agent の注入確認

# LoadBalancer URL を .env に追記
FARGATE_NR_LB=$(kubectl get svc netwatch-ui -n eks-fargate-newrelic \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "FARGATE_NR_BASE=http://${FARGATE_NR_LB}" >> .env && source .env

make load
```

---

## 計装の確認

### App Signals 環境（EC2 / Fargate 共通）

```bash
# OTel init container の注入確認（全4サービス）
for svc in netwatch-ui device-api alert-api metrics-collector; do
  echo -n "${svc}: "
  kubectl get pod -n eks-ec2-appsignals -l app=${svc} \
    -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null
  echo ""
done

# 3ホップトレースを1本生成
curl -s "${EC2_AS_BASE}/devices/TKY-CORE-001" > /dev/null
echo "トレース送信完了（App Signals に反映されるまで 2〜3 分）"
```

CloudWatch コンソールで確認:
```
Application Signals > Services
  → 4サービスが表示されること

Application Signals > Service Map
  → netwatch-ui → device-api → metrics-collector の3段グラフが表示されること
```

### New Relic 環境（EC2 / Fargate 共通）

```bash
# NR Agent init container の注入確認
kubectl get pod -n eks-ec2-newrelic -l app=netwatch-ui \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'
# 期待値: newrelic-init が含まれること
```

New Relic コンソールで確認:
```
APM > Services
  → 4サービス（netwatch-ui / device-api / alert-api / metrics-collector）が表示されること

Distributed Tracing
  → netwatch-ui → device-api → PostgreSQL のトレースが確認できること
```

---

## トラフィック生成

```bash
make load           # 全シナリオ（設定済み全環境に同時送信）
make load-normal    # ダッシュボード + 機器一覧
make load-detail    # 機器詳細（3ホップトレース生成）
make load-slow      # Slow Query ON 後に実行
make load-error     # Error Inject ON 後に実行
make load-storm     # Alert Storm シナリオ
```

`make load` は `.env` に設定された `EC2_AS_BASE` / `FARGATE_AS_BASE` / `EC2_NR_BASE` / `FARGATE_NR_BASE` の到達可能な全環境にトラフィックを送信します。

---

## よくあるトラブル

| 症状 | 確認コマンド | 対処 |
|------|------------|------|
| App Signals にサービスが出ない | `make load` でトレース生成 → 2〜3 分待つ | OTel init container の有無を確認 |
| Pod が CrashLoop | `kubectl describe pod -n <ns> <pod>` | `make build-push` 済みか確認 |
| `/devices` でエラー | `kubectl logs -n <ns> -l app=device-api --tail=50` | RDS 接続エラーなら `make create-secrets` 後に再デプロイ |
| LoadBalancer の IP が出ない | `kubectl get svc -n <ns>` | ELB 払い出しに 3〜5 分かかることがある |
| NR Agent が注入されない | `kubectl get pods -n newrelic` | `make install-newrelic-full` が完了しているか確認 |

---

## PoC 後の削除

```bash
# 個別環境の削除
make ec2-appsignals-down
make fargate-appsignals-down
make ec2-newrelic-down
make fargate-newrelic-down

# 全リソース削除（EKS + Terraform）
make down
make destroy-check   # 残留リソースの確認
```

> ECR リポジトリは `force_delete = true` のため、イメージが残っていても削除されます。
