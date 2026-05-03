# NetWatch Observability PoC — CloudWatch App Signals vs New Relic

> **検証コンセプト**: 大手キャリアが運用するネットワーク機器監視システム「NetWatch」を題材に、
> **EKS on EC2 / EKS on Fargate** それぞれで **CloudWatch Application Signals** と **New Relic APM** を実装し、機能・運用コスト・可観測性を比較する。

## 環境マトリクス

| | CloudWatch App Signals | New Relic APM |
|---|---|---|
| **EKS on EC2** | `eks-ec2-appsignals` | `eks-ec2-newrelic` |
| **EKS on Fargate** | `eks-fargate-appsignals` | `eks-fargate-newrelic` ⚠️ |

> ⚠️ `eks-fargate-newrelic`: New Relic Infrastructure Agent (DaemonSet) は Fargate 非対応のため **APM トレースのみ**。詳細 → [`docs/environment-comparison.md`](docs/environment-comparison.md)

---

## クイックスタート

詳細な手順・トラブルシューティングは [`docs/setup.md`](docs/setup.md) を参照してください。

この PoC は、4環境を同じ日にすべて構築する前提ではありません。まず共通リソースとアプリイメージを準備し、その後は検証したい環境だけを選んで個別にデプロイします。

```bash
# ① 前提確認
make check-prereq
cp .env.example .env       # AWS_ACCOUNT_ID / AWS_REGION を設定

# ② 共通準備（初回のみ・全環境共通）
make up                    # EKS + Fargate Profile + RDS + VPC + ECR
make create-secrets        # RDS 接続情報を K8s Secret に登録
make build-push            # 4サービスをビルドして ECR にプッシュ

# ③ 検証したい環境だけをデプロイ（例: EC2 + App Signals）
make install-cloudwatch-full
make ec2-appsignals-deploy
make ec2-appsignals-verify
```

---

## 進め方

### 共通準備

以下はどの環境を作る場合も共通です。初回に一度実行します。別日に再開する場合は、`make check-prereq` と `kubectl config current-context` で接続先を確認し、アプリを変更していなければ `make build-push` は再実行不要です。

```bash
make check-prereq
make up
make create-secrets
make build-push
```

### 環境別の独立手順

各行は単独で実施できます。複数環境を同日に作る必要はありません。

| 環境 | デプロイ手順 | 検証ガイド |
|------|-------------|-----------|
| EC2 + App Signals | `make install-cloudwatch-full`<br>`make ec2-appsignals-deploy`<br>`make ec2-appsignals-verify` | [lab-eks-ec2-appsignals.md](docs/lab-eks-ec2-appsignals.md) |
| Fargate + App Signals | `make install-cloudwatch-full`<br>`make fargate-appsignals-deploy`<br>`make fargate-appsignals-verify` | [lab-eks-fargate-appsignals.md](docs/lab-eks-fargate-appsignals.md) |
| EC2 + New Relic | `make install-newrelic-full`<br>`make ec2-newrelic-deploy`<br>`make ec2-newrelic-verify` | [lab-eks-ec2-newrelic.md](docs/lab-eks-ec2-newrelic.md) |
| Fargate + New Relic | `make install-newrelic-full`<br>`make fargate-newrelic-deploy`<br>`make fargate-newrelic-verify` | [lab-eks-fargate-newrelic.md](docs/lab-eks-fargate-newrelic.md) |

> `install-cloudwatch-full` と `install-newrelic-full` はそれぞれ同じ監視方式内で共用できます。すでに実行済みなら、次回は対象環境の `*-deploy` から再開できます。

### 比較検証する場合

個別環境の検証が終わった後、必要に応じて複数環境を並べて比較します。比較は最後にまとめて行う作業で、各環境の構築日とは分けて構いません。

```
[共通準備] ─── docs/setup.md
        │
        ├─ EC2 + App Signals ─── docs/lab-eks-ec2-appsignals.md
        ├─ Fargate + App Signals ─── docs/lab-eks-fargate-appsignals.md
        ├─ EC2 + New Relic ─── docs/lab-eks-ec2-newrelic.md
        └─ Fargate + New Relic ─── docs/lab-eks-fargate-newrelic.md

[比較まとめ] ─── docs/environment-comparison.md / make compare-check
```

### 環境別 詳細

| 環境 | Namespace | 主な検証ポイント |
|------|-----------|----------------|
| EC2 + App Signals | `eks-ec2-appsignals` | App Signals / X-Ray / Logs / RUM / StatsD |
| Fargate + App Signals | `eks-fargate-appsignals` | EC2 との制約差分（StatsD 不可・DaemonSet 非対応） |
| EC2 + New Relic | `eks-ec2-newrelic` | Errors Inbox / Apdex / Transaction Traces / NRQL |
| Fargate + New Relic | `eks-fargate-newrelic` | APM only 環境の制約確認（任意） |
| 比較 | 全環境 | [environment-comparison.md](docs/environment-comparison.md) の機能差マトリクス |

### 障害対応シナリオ（各環境共通）

各環境で同一のシナリオを実行し、最初にアラートや異常メトリクスで気づき、APM で影響範囲と原因サービスを特定する流れを比較します。`make load-*` は負荷テストそのものではなく、障害調査に必要なトランザクションデータを発生させるための操作です。

| シナリオ | 最初の検知 | `make` コマンド | APM で特定したいこと |
|---------|------------|----------------|----------------------|
| 正常系 | アラートなし | `make load` | サービスマップ・レイテンシ・エラー率の基準値 |
| Slow Query | レイテンシ閾値超過 / SLO 悪化 | `make load-slow` | `device-api` の DB 処理が遅く、上流の `netwatch-ui` に影響していること |
| Error Inject | 5xx エラー率閾値超過 / エラーログ増加 | `make load-error` | エラー発生源が `device-api` で、`netwatch-ui` は下流エラーを受けていること |
| Alert Storm | リクエスト数・ログ量・CPU の急増 | `make load-storm` | 急増の中心が `alert-api` で、影響が `/alerts` 系に限定されるかどうか |
| 障害対応ドリル | Canary / Alarm / NR Alert | — | [docs/runbook.md](docs/runbook.md) の Tier1/2/3 フロー |

---

## アプリケーション構成（NetWatch）

大手キャリアのネットワーク機器監視システムを模したサンプルアプリ。4サービスが3ホップのトレースを生成する。

| サービス | 役割 | 公開 |
|---------|------|------|
| **netwatch-ui** | ダッシュボード UI (FastAPI + Jinja2) | LoadBalancer |
| **device-api** | 機器 CRUD + RDS PostgreSQL | ClusterIP |
| **alert-api** | アラート管理（in-memory） | ClusterIP |
| **metrics-collector** | メトリクス収集 API（3rd hop） | ClusterIP |

```
ブラウザ → netwatch-ui → device-api → RDS          (デバイス詳細: 3ホップ)
                       → alert-api                  (アラート一覧)
         device-api   → metrics-collector            (3rd hop)
```

---

## アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────────────────────┐
│  EKS Cluster (obs-poc) — ap-northeast-1                                 │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  EC2 Node Group (t3.small × 2)  [public subnet]                  │   │
│  │  ┌──────────────────────────────┐  ┌──────────────────────────┐  │   │
│  │  │ eks-ec2-appsignals           │  │ eks-ec2-newrelic          │  │   │
│  │  │ OTel SDK                     │  │ NR Python Agent           │  │   │
│  │  │  → CW Agent DaemonSet        │  │  → collector.newrelic.com │  │   │
│  │  │  → App Signals / X-Ray       │  │  → New Relic APM + Infra  │  │   │
│  │  └──────────────────────────────┘  └──────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Fargate Profile  [private subnet + NAT]                          │   │
│  │  ┌──────────────────────────────┐  ┌──────────────────────────┐  │   │
│  │  │ eks-fargate-appsignals       │  │ eks-fargate-newrelic      │  │   │
│  │  │ OTel SDK                     │  │ NR Python Agent           │  │   │
│  │  │  → ADOT Collector Deployment │  │  → collector.newrelic.com │  │   │
│  │  │  → App Signals / X-Ray       │  │  → New Relic APM only     │  │   │
│  │  │    (via VPC endpoint)        │  │    (NR Infra: DaemonSet   │  │   │
│  │  └──────────────────────────────┘  │    非対応のため不可)      │  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌──────────────────────────────┐   ┌──────────────────────────────┐   │
│  │ CW Agent DaemonSet (EC2用)   │   │ RDS PostgreSQL db.t3.micro   │   │
│  │ ADOT Collector Deployment    │   │  private subnet              │   │
│  │  (Fargate用, 各 NS 内)        │   └──────────────────────────────┘   │
│  └──────────────────────────────┘                                       │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## ドキュメント一覧

| ドキュメント | 内容 |
|-------------|------|
| [`docs/setup.md`](docs/setup.md) | 共通準備 + 環境別の単独セットアップ + 削除手順 |
| [`docs/lab-eks-ec2-appsignals.md`](docs/lab-eks-ec2-appsignals.md) | ハンズオン — EC2 + App Signals（RUM / StatsD 含む） |
| [`docs/lab-eks-fargate-appsignals.md`](docs/lab-eks-fargate-appsignals.md) | ハンズオン — Fargate + App Signals |
| [`docs/lab-eks-ec2-newrelic.md`](docs/lab-eks-ec2-newrelic.md) | ハンズオン — EC2 + New Relic |
| [`docs/lab-eks-fargate-newrelic.md`](docs/lab-eks-fargate-newrelic.md) | ハンズオン — Fargate + New Relic（APM only） |
| [`docs/environment-comparison.md`](docs/environment-comparison.md) | 4環境の構成・機能差・比較マトリクス |
| [`docs/runbook.md`](docs/runbook.md) | 障害対応 Runbook（Tier1/2/3 切り分け手順） |

```bash
make help   # 全コマンド一覧
```

---

## AWS リソース概要

`make up`（Terraform）で作成される共通リソース:

| カテゴリ | リソース |
|---------|---------|
| EKS | Cluster + EC2 Node Group (t3.small × 2) + Fargate Profile |
| ECR | 4リポジトリ（netwatch-ui / device-api / alert-api / metrics-collector） |
| RDS | PostgreSQL 16 db.t3.micro（シングルAZ, プライベートサブネット） |
| IAM | IRSA ロール（App Signals 用） |
| VPC | VPC + Public/Private Subnet + SG + Interface Endpoints + NAT Gateway |
| CloudWatch | Application Signals / Container Insights / Log Groups |

## 費用概算

| リソース | 月額概算 |
|---------|---------|
| EKS クラスター | ~$75 |
| EC2 t3.small × 2 | ~$35 |
| RDS db.t3.micro | ~$16 |
| NAT Gateway（Fargate 用） | ~$32 |
| Application Signals + Container Insights + Logs | ~$13–30 |
| **合計（概算）** | **~$170–190/月** |

> PoC 終了後は必ず `make down` でリソースを削除してください。
