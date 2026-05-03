# セットアップ・デプロイ手順

このドキュメントは、共通準備と環境別セットアップを分けて記載します。4環境を同じ日にすべて作る必要はありません。初回に共通準備を済ませた後は、検証したい環境の手順だけを実行してください。

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

## 共通準備（初回のみ・全環境共通）

以下は `EKS on EC2 / EKS on Fargate` と `App Signals / New Relic` の全環境で共通です。環境別のデプロイに進む前に一度だけ実行します。

別日に再開する場合:
- `.env` が残っていることを確認する
- `make check-prereq` で AWS 認証とツールを確認する
- `kubectl config current-context` で対象クラスターを確認する
- アプリケーションコードや Dockerfile を変更していなければ `make build-push` は再実行不要

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

以降の各セクションは単独で完結します。共通準備が完了していれば、対象環境のセクションだけ実行してください。

`make load` は `.env` に設定された到達可能な全環境へトランザクションを送信します。これはベンチマーク目的の負荷テストではなく、APM に調査対象のトレース、エラー、レイテンシ、スループット変化を記録させるための操作です。1環境だけ検証したい場合は、対象外の `*_BASE` を空にして `./scripts/load.sh` を実行します。各環境の手順内に例を記載しています。

### [1] EKS on EC2 + App Signals（`eks-ec2-appsignals`）

**この環境だけを作る場合の流れ:**

```bash
make install-cloudwatch-full       # CloudWatch スタック（OTel Operator + ADOT + Fluent Bit）
make ec2-appsignals-deploy         # eks-ec2-appsignals namespace にデプロイ
make ec2-appsignals-verify         # Pod 起動・OTel init container の確認

# LoadBalancer URL を .env に追記
EC2_AS_LB=$(kubectl get svc netwatch-ui -n eks-ec2-appsignals \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "EC2_AS_BASE=http://${EC2_AS_LB}" >> .env && source .env

FARGATE_AS_BASE="" EC2_NR_BASE="" FARGATE_NR_BASE="" \
  ./scripts/load.sh normal-device-detail
```

オプション:
```bash
make ec2-appsignals-enable-rum             # CloudWatch RUM ブラウザ監視
make ec2-appsignals-enable-custom-metrics  # StatsD カスタムメトリクス
```

### [2] EKS on Fargate + App Signals（`eks-fargate-appsignals`）

**この環境だけを作る場合の流れ:**

```bash
make install-cloudwatch-full       # CloudWatch スタック。EC2 App Signals と共用可
make fargate-appsignals-deploy     # eks-fargate-appsignals namespace にデプロイ
make fargate-appsignals-verify     # Pod 起動の確認

# LoadBalancer URL を .env に追記
FARGATE_AS_LB=$(kubectl get svc netwatch-ui -n eks-fargate-appsignals \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "FARGATE_AS_BASE=http://${FARGATE_AS_LB}" >> .env && source .env

EC2_AS_BASE="" EC2_NR_BASE="" FARGATE_NR_BASE="" \
  ./scripts/load.sh normal-device-detail
```

オプション:
```bash
make fargate-appsignals-enable-rum  # CloudWatch RUM ブラウザ監視
```

> **Fargate の制約:** DaemonSet 非対応のため StatsD カスタムメトリクスは未対応。CloudWatch Agent は Deployment として別途起動します。

### [3] EKS on EC2 + New Relic（`eks-ec2-newrelic`）

**この環境だけを作る場合の流れ:**

> 前提: `.env` に `NEW_RELIC_LICENSE_KEY` / `NEW_RELIC_ACCOUNT_ID` を設定済みであること。

```bash
make install-newrelic-full         # nri-bundle Helm + k8s-agents-operator インストール
make ec2-newrelic-deploy           # eks-ec2-newrelic namespace にデプロイ
make ec2-newrelic-verify           # NR Python Agent の注入確認

# LoadBalancer URL を .env に追記
EC2_NR_LB=$(kubectl get svc netwatch-ui -n eks-ec2-newrelic \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "EC2_NR_BASE=http://${EC2_NR_LB}" >> .env && source .env

EC2_AS_BASE="" FARGATE_AS_BASE="" FARGATE_NR_BASE="" \
  ./scripts/load.sh normal-device-detail
```

### [4] EKS on Fargate + New Relic（`eks-fargate-newrelic`）

> ⚠️ **APM トレースのみ。** Infrastructure Agent (DaemonSet) は Fargate 非対応のためインフラメトリクス・ログ転送は収集されません。  
> 詳細 → [`docs/environment-comparison.md`](environment-comparison.md)

**この環境だけを作る場合の流れ:**

> 前提: `.env` に `NEW_RELIC_LICENSE_KEY` / `NEW_RELIC_ACCOUNT_ID` を設定済みであること。`make install-newrelic-full` は `eks-ec2-newrelic` と共用できます。

```bash
make install-newrelic-full         # 未実行の場合のみ。既存 New Relic スタックがあればスキップ可
make fargate-newrelic-deploy       # eks-fargate-newrelic namespace にデプロイ
make fargate-newrelic-verify       # NR Python Agent の注入確認

# LoadBalancer URL を .env に追記
FARGATE_NR_LB=$(kubectl get svc netwatch-ui -n eks-fargate-newrelic \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "FARGATE_NR_BASE=http://${FARGATE_NR_LB}" >> .env && source .env

EC2_AS_BASE="" FARGATE_AS_BASE="" EC2_NR_BASE="" \
  ./scripts/load.sh normal-device-detail
```

---

## 計装の確認

### App Signals 環境（EC2 / Fargate 共通）

```bash
NS=eks-ec2-appsignals        # Fargate の場合: eks-fargate-appsignals
BASE="${EC2_AS_BASE}"        # Fargate の場合: "${FARGATE_AS_BASE}"

# OTel init container の注入確認（全4サービス）
for svc in netwatch-ui device-api alert-api metrics-collector; do
  echo -n "${svc}: "
  kubectl get pod -n "${NS}" -l app=${svc} \
    -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null
  echo ""
done

# 3ホップトレースを1本生成
curl -s "${BASE}/devices/TKY-CORE-001" > /dev/null
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
NS=eks-ec2-newrelic          # Fargate の場合: eks-fargate-newrelic

# NR Agent init container の注入確認
kubectl get pod -n "${NS}" -l app=netwatch-ui \
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

単独環境だけに送信する例:

```bash
# EC2 + App Signals のみ
FARGATE_AS_BASE="" EC2_NR_BASE="" FARGATE_NR_BASE="" ./scripts/load.sh normal-device-detail

# Fargate + App Signals のみ
EC2_AS_BASE="" EC2_NR_BASE="" FARGATE_NR_BASE="" ./scripts/load.sh normal-device-detail

# EC2 + New Relic のみ
EC2_AS_BASE="" FARGATE_AS_BASE="" FARGATE_NR_BASE="" ./scripts/load.sh normal-device-detail

# Fargate + New Relic のみ
EC2_AS_BASE="" FARGATE_AS_BASE="" EC2_NR_BASE="" ./scripts/load.sh normal-device-detail
```

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
