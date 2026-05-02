# NetWatch Observability PoC

> **検証コンセプト**: 大手キャリアが運用するネットワーク機器監視システム「NetWatch」を題材に、
> **EKS on EC2 / EKS on Fargate** それぞれで **CloudWatch Application Signals** と **New Relic APM** を実装し、機能・運用コスト・可観測性を比較する。

## 環境マトリクス

| | CloudWatch App Signals | New Relic APM |
|---|---|---|
| **EKS on EC2** | `eks-ec2-appsignals` | `eks-ec2-newrelic` |
| **EKS on Fargate** | `eks-fargate-appsignals` | `eks-fargate-newrelic` ⚠️ |

> ⚠️ `eks-fargate-newrelic`: New Relic Infrastructure Agent (DaemonSet) は Fargate 非対応のため **APM トレースのみ**。インフラメトリクス・ログ転送は収集されない。詳細 → [`docs/environment-comparison.md`](docs/environment-comparison.md)

## アプリケーション構成（NetWatch）

大手キャリアのネットワーク機器監視システムを模したサンプルアプリ。4サービスが3ホップのトレースを生成する。

| サービス | 役割 | 公開 |
|---------|------|------|
| **netwatch-ui** | ダッシュボード UI (FastAPI + Jinja2) | LoadBalancer |
| **device-api** | 機器 CRUD + RDS PostgreSQL | ClusterIP |
| **alert-api** | アラート管理（in-memory） | ClusterIP |
| **metrics-collector** | メトリクス収集 API（3rd hop） | ClusterIP |

```
ブラウザ → netwatch-ui → device-api → RDS    (デバイス詳細: 3ホップ)
                       → alert-api            (アラート一覧)
                           └→ metrics-collector (3rd hop)
```

## アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────────────────────┐
│  EKS Cluster (obs-poc) — ap-northeast-1                                 │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  EC2 Node Group (t3.small × 2)                                   │   │
│  │  ┌─────────────────────────────┐  ┌──────────────────────────┐  │   │
│  │  │ namespace: eks-ec2-appsignals│  │ namespace: eks-ec2-newrelic│  │   │
│  │  │ OTel SDK → CloudWatch Agent │  │ NR Python Agent → NR Cloud│  │   │
│  │  └─────────────────────────────┘  └──────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Fargate Profile                                                  │   │
│  │  ┌────────────────────────────────┐  ┌─────────────────────────┐ │   │
│  │  │namespace: eks-fargate-appsignals│  │namespace: eks-fargate-nr│ │   │
│  │  │ OTel SDK → CW Agent Deployment │  │ NR Python Agent (APM only)│ │   │
│  │  └────────────────────────────────┘  └─────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─────────────────────────┐   ┌──────────────────────────────────┐    │
│  │ CloudWatch Agent (ADOT) │   │ RDS PostgreSQL db.t3.micro       │    │
│  │  → App Signals / X-Ray  │   │  private subnet                  │    │
│  └─────────────────────────┘   └──────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

## ドキュメント

| ドキュメント | 内容 |
|-------------|------|
| [`docs/setup.md`](docs/setup.md) | セットアップ・デプロイ手順（全4環境） |
| [`docs/environment-comparison.md`](docs/environment-comparison.md) | 4環境の構成・機能差・比較表 |
| [`docs/observability-lab.md`](docs/observability-lab.md) | CloudWatch ハンズオン検証ガイド |
| [`docs/rum-lab.md`](docs/rum-lab.md) | CloudWatch RUM ブラウザ監視ハンズオン |
| [`docs/custom-metrics-lab.md`](docs/custom-metrics-lab.md) | StatsD カスタムメトリクスハンズオン |
| [`docs/runbook.md`](docs/runbook.md) | 障害対応 Runbook・コマンド集 |

```bash
make help   # 全コマンド一覧
```

## AWS リソース概要

`make up`（Terraform）で作成される共通リソース:

| カテゴリ | リソース |
|---------|---------|
| EKS | Cluster + EC2 Node Group (t3.small × 2) + Fargate Profile |
| ECR | 4リポジトリ（netwatch-ui / device-api / alert-api / metrics-collector） |
| RDS | PostgreSQL 16 db.t3.micro（シングルAZ, プライベートサブネット） |
| IAM | IRSA ロール（App Signals 用） |
| VPC | VPC + Subnet + SG + Interface Endpoints（NAT Gateway 不使用） |
| CloudWatch | Application Signals / Container Insights / Log Groups |

## 費用概算

| リソース | 月額概算 |
|---------|---------|
| EKS クラスター | ~$75 |
| EC2 t3.small × 2 | ~$35 |
| RDS db.t3.micro | ~$16 |
| Application Signals + Container Insights + Logs | ~$13–30 |
| **合計（概算）** | **~$140–160/月** |

> PoC 終了後は必ず `make down` でリソースを削除してください。
