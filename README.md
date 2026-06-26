# FastFeet — Infraestrutura como Código (Terraform)

> Infraestrutura completa para deploy da API FastFeet em **ECS Express Mode** na AWS.

## Sumário

- [Visão Geral](#visão-geral)
- [Arquitetura](#arquitetura)
- [Pré-requisitos](#pré-requisitos)
- [Como usar](#como-usar)
- [Pós-deploy](#pós-deploy)
- [Destruir](#destruir)
- [CI/CD](#cicd)
- [Estrutura de arquivos](#estrutura-de-arquivos)
- [Referência](#referência)

---

## Visão Geral

Este repositório provisiona toda a infraestrutura necessária para rodar a
API FastFeet (NestJS + Prisma + PostgreSQL) na AWS usando **ECS Express
Mode** — uma modalidade simplificada do ECS que gerencia automaticamente
ALB, SSL, DNS, Auto Scaling e CloudWatch.

### O que é provisionado

| Recurso | Descrição |
|---------|-----------|
| **ECR** | Repositório de imagens Docker com lifecycle (keep 5) |
| **RDS** | PostgreSQL 16 (db.t3.micro, 20GB) |
| **S3** | Bucket para uploads de fotos |
| **ECS Express** | Serviço gerenciado com ALB + SSL + DNS + Auto Scaling |
| **Secrets Manager** | 3 secrets (DATABASE_URL, JWT keys) |
| **IAM** | Roles para ECS, GitHub Actions (OIDC), execution role |
| **GitHub OIDC** | Autenticação segura para CI/CD sem chaves estáticas |

---

## Arquitetura

```
┌─────────┐    ┌──────────────────────────────────────────────────┐
│ GitHub  │───▶│  GitHub Actions (CI/CD)                          │
│ Actions │    │  ∙ OIDC assume role (sem chaves estáticas)       │
└─────────┘    │  ∙ CI: build Docker → push ECR                   │
               │  ∙ CD: ecs update-service --force-new-deployment │
               └───────────────────────┬──────────────────────────┘
                                       │
                                       ▼
               ┌──────────────────────────────────────────────────┐
               │              AWS (us-east-2)                     │
               │                                                  │
               │   ┌─────────────────────────────────────────┐    │
               │   │         ECS Express Service             │    │
               │   │  ┌───────────────────────────────────┐  │    │ 
               │   │  │  ALB (auto-provisionado)          │  │    │
               │   │  │  SSL (ACM, auto-provisionado)     │  │    │
               │   │  │  DNS (*.ecs.on.aws)               │  │    │
               │   │  └───────────────────────────────────┘  │    │
               │   │                                         │    │
               │   │  ┌───────────────────────────────────┐  │    │
               │   │  │ Container FastFeet (NestJS)       │  │    │
               │   │  │ PORT 3333, CPU 512, RAM 1024      │  │    │
               │   │  │ Auto Scaling: 1-3 tasks @ 70% CPU │  │    │
               │   │  └───────────────────────────────────┘  │    │
               │   └─────────────────────────────────────────┘    │
               │                                                  │
               │   ┌──────────┐  ┌──────────┐  ┌─────────────┐    │
               │   │   RDS    │  │   S3     │  │ Secrets Mgr │    │
               │   │PostgreSQL│  │ Uploads  │  │ DB + JWT    │    │
               │   └──────────┘  └──────────┘  └─────────────┘    │
               └──────────────────────────────────────────────────┘
```

---

## Pré-requisitos

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
- [AWS CLI](https://aws.amazon.com/cli/) configurado com perfil que tenha
  permissões de admin ou power user
- [Docker](https://docker.com) (para build da imagem da aplicação)

---

## Como usar

```bash
# 1. Clone o repositório
git clone <seu-repo>
cd <seu-repo>

# 2. Configure o profile AWS (edite main.tf se necessário)
#    provider "aws" {
#      region  = "us-east-2"
#      profile = "seu-profile"
#    }

# 3. Inicialize o Terraform
terraform init

# 4. Veja o que será criado
terraform plan

# 5. Provisione tudo
terraform apply

# 6. Veja os outputs (URL do serviço, ECR, RDS, S3)
terraform output
```

> ⏱ O ECS Express leva **5–15 minutos** para provisionar (ALB, SSL, DNS).
> O Terraform aguarda automaticamente com `wait_for_steady_state = true`.

---

## Pós-deploy

Após o `apply`, a infraestrutura está pronta mas a aplicação ainda não
funciona. É necessário:

### 1. Popular as Secrets

Os valores das secrets **não** são gerenciados pelo Terraform (por
segurança). Popule manualmente via Console AWS ou CLI:

```bash
# DATABASE_URL: use o output do Terraform para obter o endpoint do RDS
aws secretsmanager put-secret-value \
  --secret-id fast-feet/database-url \
  --secret-string "postgresql://fastfeet:<password>@<db-endpoint>:5432/fastfeet"

# JWT Private Key (gere um par RSA)
openssl genpkey -algorithm RSA -out private.pem -pkeyopt rsa_keygen_bits:2048
openssl rsa -pubout -in private.pem -out public.pem

aws secretsmanager put-secret-value \
  --secret-id fast-feet/jwt-private-key \
  --secret-string "$(cat private.pem)"

aws secretsmanager put-secret-value \
  --secret-id fast-feet/jwt-public-key \
  --secret-string "$(cat public.pem)"
```

> 💡 A senha do RDS foi gerada aleatoriamente pelo Terraform. Para obtê-la:
> ```bash
> terraform state show random_password.db
> ```
> (O valor está no campo `result`, marcado como sensitive.)

### 2. Fazer push da imagem Docker

A imagem `:main` precisa existir no ECR:

```bash
# Build e push manual
docker build -t <ecr-repo-url>:main .
docker push <ecr-repo-url>:main

# Ou rode a pipeline CI (recomendado)
```

### 3. Forçar novo deploy no ECS

```bash
# Manual
aws ecs update-service \
  --cluster fast-feet \
  --service fast-feet \
  --force-new-deployment

# Ou rode a pipeline de CD (ira forçar um novo deploy)
```

---

## Destruir

```bash
terraform destroy
```

> ⚠️ `terraform destroy` deleta **tudo**: RDS (dados), S3 (arquivos), ECR
> (imagens). As secrets são deletadas imediatamente
> (`recovery_window_in_days = 0`).

- Ponto de atenção, o ECR irar dar erro ao tentar o `destroy`, porque esta com imagens, delete as imagens e rode novamente um `destroy`

---

## CI/CD

O repositório da **aplicação** contém as pipelines:

- **CI** (`.github/workflows/ci.yml`): build, test, push to ECR
- **CD** (`.github/workflows/cd.yml`): força novo deploy no ECS

Ambas usam **OIDC** para autenticação na AWS — sem chaves estáticas.
O provedor OIDC e a role `github-actions-role` são criados por este
Terraform.

---

## Estrutura de arquivos

```
├── main.tf              # Provider AWS (região, profile)
├── ecr.tf               # Repositório ECR + lifecycle policy
├── secrets.tf           # Secrets Manager (3 secrets)
├── rds.tf               # RDS PostgreSQL + senha aleatória
├── s3.tf                # Bucket S3 para uploads
├── iam.tf               # GitHub OIDC + GitHub Actions role
├── iam-policies.tf      # Políticas do GitHub Actions
├── ecs-express.tf       # Core: ECS Express + roles + cluster
├── outputs.tf           # Outputs do Terraform
└── .terraform.lock.hcl  # Lock file do provider
```

---

## Referência

Para documentação detalhada de cada recurso (o que é, por que existe,
dependências, armadilhas), consulte:

➡️ [`iac-reference.md`](./iac-reference.md)
