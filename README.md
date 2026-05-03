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

```bash
# ① 前提確認
make check-prereq
cp .env.example .env       # AWS_ACCOUNT_ID / AWS_REGION を設定

# ② 共通インフラ構築（初回のみ・約25分）
make up                    # EKS + Fargate Profile + RDS + VPC + ECR
make create-secrets        # RDS 接続情報を K8s Secret に登録
make build-push            # 4サービスをビルドして ECR にプッシュ

# ③ 最初の環境（EC2 + App Signals）をデプロイ
make install-cloudwatch-full
make ec2-appsignals-deploy
make load                  # トレース・メトリクス生成（2〜3分でコンソールに反映）
```

---

## 検証フロー（全体の流れ）

セットアップ完了後、以下の順で検証を進めます。各フェーズで **同一のカオスシナリオ** を実行し、ツールごとの見え方を比較するのが本 PoC のコアです。

```
[共通セットアップ] ─── docs/setup.md
        │
        ▼
[Phase 1] EKS on EC2 + App Signals ─── CloudWatch の全機能を一通り体験
        │  make ec2-appsignals-deploy
        │  → docs/lab-eks-ec2-appsignals.md
        │
        ▼
[Phase 2] EKS on Fargate + App Signals ─── EC2 との差分・制約を確認
        │  make fargate-appsignals-deploy
        │  → docs/lab-eks-fargate-appsignals.md
        │
        ▼
[Phase 3] EKS on EC2 + New Relic ─── CloudWatch との APM 機能を比較
        │  make install-newrelic-full && make ec2-newrelic-deploy
        │  → docs/lab-eks-ec2-newrelic.md
        │  → bash scripts/compare-check.sh  ← CW vs NR 比較観点ガイド
        │
        ▼
[Phase 4] EKS on Fargate + New Relic ─── APM only 制約確認（任意）
        │  make fargate-newrelic-deploy
        │  → docs/lab-eks-fargate-newrelic.md
        │
        ▼
[比較まとめ] ─── docs/environment-comparison.md
```

### Phase 別 詳細

| Phase | 環境 | デプロイ | 検証ガイド | 主な検証ポイント |
|-------|------|---------|-----------|----------------|
| 1 | EC2 + App Signals | `make ec2-appsignals-deploy` | [lab-eks-ec2-appsignals.md](docs/lab-eks-ec2-appsignals.md) | App Signals / X-Ray / Logs / RUM / StatsD |
| 2 | Fargate + App Signals | `make fargate-appsignals-deploy` | [lab-eks-fargate-appsignals.md](docs/lab-eks-fargate-appsignals.md) | EC2 との制約差分（StatsD 不可・DaemonSet 非対応） |
| 3 | EC2 + New Relic | `make install-newrelic-full`<br>`make ec2-newrelic-deploy` | [lab-eks-ec2-newrelic.md](docs/lab-eks-ec2-newrelic.md) | Errors Inbox / Apdex / Transaction Traces / NRQL |
| 4 | Fargate + New Relic | `make fargate-newrelic-deploy` | [lab-eks-fargate-newrelic.md](docs/lab-eks-fargate-newrelic.md) | APM only 環境の制約確認（任意） |
| 比較 | 全環境 | — | [environment-comparison.md](docs/environment-comparison.md) | 4環境の機能差マトリクス |

### カオスシナリオ（各 Phase 共通）

各環境で同一のシナリオを実行し、ツールごとの見え方の差を比較します。

| シナリオ | `/chaos` 画面で操作 | `make` コマンド | 主な確認観点 |
|---------|------------------|----------------|------------|
| 正常系 | — | `make load` | サービスマップ・レイテンシ・エラー率の基準値 |
| Slow Query | Slow Query ON (3000ms) | `make load-slow` | device-api の DB スパン遅延、P99 の悪化 |
| Error Inject | Error Inject ON (30%) | `make load-error` | エラー伝播、Fault rate の連鎖 |
| Alert Storm | Alert Storm ON | `make load-storm` | alert-api スループット急増、ログ量増加 |
| 障害対応ドリル | — | — | [docs/runbook.md](docs/runbook.md) の Tier1/2/3 フロー |

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
| [`docs/setup.md`](docs/setup.md) | セットアップ・デプロイ手順（全4環境） + 削除手順 |
| [`docs/lab-eks-ec2-appsignals.md`](docs/lab-eks-ec2-appsignals.md) | ハンズオン — Phase 1: EC2 + App Signals（RUM / StatsD 含む） |
| [`docs/lab-eks-fargate-appsignals.md`](docs/lab-eks-fargate-appsignals.md) | ハンズオン — Phase 2: Fargate + App Signals |
| [`docs/lab-eks-ec2-newrelic.md`](docs/lab-eks-ec2-newrelic.md) | ハンズオン — Phase 3: EC2 + New Relic |
| [`docs/lab-eks-fargate-newrelic.md`](docs/lab-eks-fargate-newrelic.md) | ハンズオン — Phase 4: Fargate + New Relic（APM only） |
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
