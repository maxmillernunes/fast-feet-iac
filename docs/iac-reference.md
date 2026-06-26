# FastFeet — Referência da Infraestrutura (IaC)

> Documento de referência para entender cada recurso Terraform, por que existe,
> do que depende, e o que é necessário para funcionar.

---

## Sumário

1. [main.tf — Provider e Configuração Global](#1-maintf--provider-e-configuração-global)
2. [ecr.tf — Repositório de Imagens Docker](#2-ecrtf--repositório-de-imagens-docker)
3. [secrets.tf — AWS Secrets Manager](#3-secretstf--aws-secrets-manager)
4. [rds.tf — Banco de Dados PostgreSQL](#4-rdstf--banco-de-dados-postgresql)
5. [s3.tf — Bucket S3 para Uploads](#5-s3tf--bucket-s3-para-uploads)
6. [iam.tf — GitHub Actions (OIDC)](#6-iamtf--github-actions-oidc)
7. [iam-policies.tf — Permissões do GitHub Actions](#7-iam-policiestf--permissões-do-github-actions)
8. [ecs-express.tf — Core da Infraestrutura](#8-ecs-expresstf--core-da-infraestrutura)
9. [outputs.tf — Saídas do Terraform](#9-outputstf--saídas-do-terraform)
10. [Fluxo Completo — Ordem de Criação e Dependências](#10-fluxo-completo--ordem-de-criação-e-dependências)

---

## 1. `main.tf` — Provider e Configuração Global

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.51.0"
    }
  }
}

provider "aws" {
  region  = "us-east-2"
  profile = "seu-profile"
}
```

### O que é

Arquivo raiz que configura o provedor AWS e a versão do Terraform.

### Por que existe

Todo projeto Terraform precisa declarar quais provedores usar e a versão mínima.
O Terraform baixa automaticamente o plugin do provider AWS.

### Recursos declarados

| Recurso | Descrição |
|---------|-----------|
| `required_providers` | Define que usamos `hashicorp/aws` versão `6.51.0` |
| `provider "aws"` | Configura região `us-east-2` e profile `sansao` |

### Importante saber

- A versão `6.51.0` mudou alguns atributos de recursos mais recentes como
  `aws_ecs_express_gateway_service`. Se atualizar o provider, verifique o
  changelog.
- O profile `sansao` deve estar configurado em `~/.aws/credentials`.
- A região `us-east-2` (Ohio) foi escolhida por ser mais barata que
  `us-east-1` (Norte da Virgínia).

---

## 2. `ecr.tf` — Repositório de Imagens Docker

```hcl
resource "aws_ecr_repository" "app" {
  name                 = "fast-feet"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { IAC = "true" }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
```

### `aws_ecr_repository.app`

#### O que é

Repositório no Amazon ECR (Elastic Container Registry) que armazena as imagens
Docker da aplicação.

#### Por que existe

O ECS Express precisa de um repositório de imagens para puxar o container.
Usamos o ECR porque é o registro nativo da AWS, não precisa de autenticação
extra (o ECS já tem permissão via execution role), e fica na mesma região.

#### Detalhes

- `image_tag_mutability = "MUTABLE"` — permite sobrescrever a tag `:main`
  a cada push da CI. Se fosse `IMMUTABLE`, cada push precisaria de uma tag
  diferente.
- `scan_on_push = true` — toda imagem enviada é escaneada automaticamente em
  busca de vulnerabilidades (CVE).

#### Dependências

- **Nada.** É o primeiro recurso a ser criado.

#### Quem depende dele

- A CI faz push das imagens aqui.
- O ECS Express service puxa a imagem daqui (`image = "${aws_ecr_repository.app.repository_url}:main"`).

---

### `aws_ecr_lifecycle_policy.app`

#### O que é

Política de ciclo de vida que expira imagens antigas automaticamente.

#### Por que existe

A CI faz push a cada merge na `main`. Sem uma política de expiração, o
repositório acumularia centenas de imagens e aumentaria custos de
armazenamento.

#### Regra

Mantém apenas as **5 imagens mais recentes** (independente da tag) e apaga
o resto.

---

## 3. `secrets.tf` — AWS Secrets Manager

```hcl
resource "aws_secretsmanager_secret" "jwt_private" {
  name                    = "fast-feet/jwt-private-key"
  recovery_window_in_days = 0
  tags = { IAC = "true" }
}

resource "aws_secretsmanager_secret" "jwt_public" {
  name                    = "fast-feet/jwt-public-key"
  recovery_window_in_days = 0
  tags = { IAC = "true" }
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "fast-feet/database-url"
  recovery_window_in_days = 0
  tags = { IAC = "true" }
}
```

### `aws_secretsmanager_secret` (3 recursos)

#### O que é

Recursos no AWS Secrets Manager que armazenam senhas e chaves sensíveis.
**Importante:** o Terraform cria apenas o **recurso** (o "container" do
segrredo), não o **valor**. Os valores precisam ser populados manualmente
via Console AWS ou AWS CLI após o `apply`.

#### Por que existe

A aplicação precisa de 3 valores sensíveis para funcionar:

| Secret | Nome no Secrets Manager | Para que serve |
|--------|------------------------|----------------|
| `jwt_private` | `fast-feet/jwt-private-key` | Assinar tokens JWT |
| `jwt_public` | `fast-feet/jwt-public-key` | Verificar tokens JWT |
| `db` | `fast-feet/database-url` | String de conexão com o PostgreSQL |

Poderíamos colocar esses valores no arquivo `.env` ou variáveis de ambiente
do ECS, mas isso não é seguro (vazaria no Terraform). Secrets Manager é a
forma segura e recomendada pela AWS.

#### Por que `recovery_window_in_days = 0`

Quando você deleta um secret no Secrets Manager, a AWS por padrão aguarda
30 dias antes de deletar de verdade (período de recuperação). Isso significa
que um `terraform destroy` não deleta imediatamente — o secret fica agendado
pra deleção.

Com `recovery_window_in_days = 0`, o secret é deletado **imediatamente**.
Isso é importante para testes: você pode destruir e recriar a infra sem
deixar lixo agendado pra deletar.

#### Dependências

- **Nada.** Secrets são independentes.

#### Quem depende deles

- **ECS Express service** — o execution role lê esses secrets na
  inicialização do container e injeta como variáveis de ambiente
  (DATABASE_URL, JWT_PRIVATE_KEY, JWT_PUBLIC_KEY).
- **Task role** tem permissão `secretsmanager:GetSecretValue` para acessar
  em runtime.

---

## 4. `rds.tf` — Banco de Dados PostgreSQL

```hcl
resource "random_password" "db" {
  length  = 20
  special = false
}

resource "aws_db_instance" "postgres" {
  engine              = "postgres"
  engine_version      = "16"
  instance_class      = "db.t3.micro"
  allocated_storage   = 20
  db_name             = "fastfeet"
  username            = "fastfeet"
  password            = random_password.db.result
  skip_final_snapshot = true
  publicly_accessible = false

  tags = { IAC = "true" }
}
```

### `random_password.db`

#### O que é

Recurso do provedor `random` que gera uma senha aleatória de 20 caracteres
(sem caracteres especiais).

#### Por que existe

Precisamos de uma senha para o banco PostgreSQL. Ao invés de fixar uma senha
no código (nunca faça isso), usamos `random_password` para gerar uma senha
segura automaticamente.

#### Importante saber

- A senha é gerada **no momento do `apply`** e fica armazenada no state do
  Terraform.
- Se perder o state, perde a senha. Nesse caso, seria necessário resetar a
  senha no RDS manualmente.

---

### `aws_db_instance.postgres`

#### O que é

Instância RDS PostgreSQL rodando em `db.t3.micro` (classe gratuita elegível).

#### Por que existe

A aplicação FastFeet precisa de um banco de dados relacional para armazenar
entregas, destinatários, usuários etc. O Prisma ORM já está configurado para
PostgreSQL.

#### Detalhes

| Atributo | Valor | Por que |
|----------|-------|---------|
| `engine` | `postgres` | Prisma ORM suporta nativamente |
| `engine_version` | `16` | Versão estável mais recente |
| `instance_class` | `db.t3.micro` | 2 vCPUs, 1GB RAM — suficiente para dev/teste |
| `allocated_storage` | `20` | Mínimo exigido pela AWS para RDS |
| `db_name` | `fastfeet` | **Sem hífen!** PostgreSQL não aceita `-` em nomes de banco |
| `skip_final_snapshot` | `true` | Não cria snapshot ao destruir (evita custos de teste) |
| `publicly_accessible` | `false` | Banco acessível apenas dentro da VPC |

#### Dependências

- `random_password.db` — a senha é gerada aleatoriamente.
- A VPC default (implícita — o RDS é criado na VPC default por padrão).

#### Quem depende dele

- A aplicação FastFeet (container no ECS) se conecta via `DATABASE_URL`
  no Secrets Manager.

#### O que mais precisa

- A `DATABASE_URL` no Secrets Manager precisa ser populada manualmente com
  o valor `postgresql://fastfeet:<password>@<rds-endpoint>:5432/fastfeet`.
  O endpoint do RDS aparece no output `db_endpoint` do Terraform.

---

## 5. `s3.tf` — Bucket S3 para Uploads

```hcl
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "uploads" {
  bucket = "fast-feet-uploads-${data.aws_caller_identity.current.account_id}"
  tags = { IAC = "true" }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

### `data.aws_caller_identity.current`

#### O que é

Data source que retorna o ID da conta AWS atual.

#### Por que existe

Usamos o account ID para garantir que o nome do bucket S3 seja
**globalmente único** (S3 exige nomes únicos em toda a AWS, não só na sua
conta). O nome final é `fast-feet-uploads-288761730227`.

---

### `aws_s3_bucket.uploads`

#### O que é

Bucket S3 que armazena as fotos de comprovante de entrega e outros uploads
da aplicação.

#### Por que existe

A aplicação FastFeet permite que entregadores enviem fotos como comprovante
de entrega. Essas imagens são armazenadas no S3.

#### Dependências

- **Nada.** Bucket S3 é independente.

#### Quem depende dele

- A aplicação (via task role com permissões S3).
- O ambiente do ECS passa `AWS_S3_BUCKET = aws_s3_bucket.uploads.bucket`.

---

### `aws_s3_bucket_public_access_block.uploads`

#### O que é

Bloqueia todo acesso público ao bucket.

#### Por que existe

Segurança. Buckets S3 podem ser expostos acidentalmente. Este recurso
garante que nenhuma política pública ou ACL pública seja aplicada, mesmo
que alguém tente manualmente.

---

## 6. `iam.tf` — GitHub Actions (OIDC)

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags = { IAC = "true" }
}

resource "aws_iam_role" "github_actions" {
  name = "github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = ["sts.amazonaws.com"]
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              "repo:maxmillernunes/fast-feet:ref:refs/heads/main"
            ]
          }
        }
      }
    ]
  })

  tags = { IAC = "true" }
}
```

### `aws_iam_openid_connect_provider.github`

#### O que é

Provedor de identidade OIDC que estabelece confiança entre a AWS e o GitHub
Actions.

#### Por que existe

A pipeline CI (GitHub Actions) precisa se autenticar na AWS para fazer push
de imagens no ECR e atualizar o serviço ECS. Existem duas formas:

1. **Access keys estáticas** — criar um usuário IAM, gerar chaves, colocar
   como secrets do GitHub. **Inseguro**: chaves vazam, nunca expiram.
2. **OIDC** — GitHub Actions assume uma role IAM diretamente, sem chaves.
   **Seguro**: tokens temporários (1 hora), sem secrets para gerenciar.

Escolhemos **OIDC** por segurança.

---

### `aws_iam_role.github_actions`

#### O que é

Role IAM que o GitHub Actions assume durante a pipeline.

#### Por que existe

A CI precisa de permissões específicas (ECR push, ECS update, PassRole).
Ao invés de dar permissão para um usuário fixo, o GitHub assume esta role
temporariamente.

#### Trust Policy

- **Principal:** o provedor OIDC do GitHub
- **Condição:** apenas o repo `maxmillernunes/fast-feet` na branch `main`
- **Ação:** `sts:AssumeRoleWithWebIdentity`

#### Dependências

- `aws_iam_openid_connect_provider.github` — a role confia no OIDC provider.

#### Quem depende dela

- A CI (`.github/workflows/ci.yml`) usa a action `configure-aws-credentials`
  para assumir esta role.
- As policies em `iam-policies.tf` definem o que esta role pode fazer.

---

## 7. `iam-policies.tf` — Permissões do GitHub Actions

```hcl
data "aws_iam_policy_document" "github_actions" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
      "ecs:ListClusters",
      "ecs:ListServices",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::*:role/fast-feet-execution-role",
      "arn:aws:iam::*:role/fast-feet-task-role",
    ]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "github-actions-policy"
  role   = aws_iam_role.github_actions.name
  policy = data.aws_iam_policy_document.github_actions.json
}
```

### `data.aws_iam_policy_document.github_actions`

#### O que é

Documento de política IAM que define as permissões da role do GitHub Actions.

#### Statement 1 — ECR (Push de imagens)

Permite à CI fazer push de imagens Docker no ECR: obter token de
autenticação, verificar layers, fazer upload, registrar a imagem.

**Por que `resources = ["*"]`:** O ECR não permite restringir a ação
`GetAuthorizationToken` por repositório específico — precisa ser `*`.

#### Statement 2 — ECS (Forçar deploy)

Permite à CI executar `aws ecs update-service --force-new-deployment`
para que o ECS substitua as tarefas pela nova imagem.

#### Statement 3 — PassRole

Permite que o GitHub Actions **passe** as roles para o ECS.
Se a CI executar `aws ecs update-service`, ela precisa de `iam:PassRole`
nas roles `fast-feet-execution-role` e `fast-feet-task-role`.

---

### `aws_iam_role_policy.github_actions`

Anexa o documento de política à role do GitHub Actions.

#### Dependências

- `aws_iam_role.github_actions`
- `data.aws_iam_policy_document.github_actions`

---

## 8. `ecs-express.tf` — Core da Infraestrutura

Este é o arquivo mais importante. Ele contém toda a configuração do ECS
Express Mode, que é a espinha dorsal da aplicação.

### Data Sources (preparação do ambiente)

```hcl
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_security_group" "default" {
  vpc_id = data.aws_vpc.default.id
  name   = "default"
}
```

#### O que são

Data sources que buscam recursos existentes na conta AWS — não criam nada
novo, apenas consultam.

#### Por que existem

O ECS Express precisa saber **onde** rodar os containers. Ele precisa de:

| Data Source | O que retorna | Para que serve |
|-------------|---------------|----------------|
| `aws_vpc.default` | A VPC default da conta | Rede onde tudo roda |
| `aws_subnets.default` | Todas as subnets da VPC default | Onde as tarefas ECS são alocadas |
| `aws_security_group.default` | O SG default da VPC | Regras de tráfego de rede |

Poderíamos criar uma VPC, subnets e security groups customizados, mas para
fins de desenvolvimento/teste a VPC default já atende. Em produção, o
recomendado é criar uma VPC dedicada.

---

### ECS Task Execution Role

```hcl
resource "aws_iam_role" "ecs_task_execution" {
  name = "fast-feet-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
  tags = { IAC = "true" }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_task_execution" {
  name = "fast-feet-execution-policy"
  role = aws_iam_role.ecs_task_execution.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = ["*"]
      },
    ]
  })
}
```

#### O que é

Role que o **agente ECS** assume para gerenciar o ciclo de vida do container:
baixar a imagem, configurar variáveis de ambiente, puxar secrets, enviar
logs.

#### Por que `ecs-tasks.amazonaws.com` no trust policy

O serviço ECS task (agente) precisa assumir esta role para executar tarefas
em nome do usuário. O principal correto é `ecs-tasks.amazonaws.com`.

#### Permissões

- **Managed policy `AmazonECSTaskExecutionRolePolicy`** — Permissões padrão:
  baixar imagem do ECR, criar grupos de logs, enviar logs para CloudWatch.
- **Inline policy `fast-feet-execution-policy`** — Permissão extra de
  `secretsmanager:GetSecretValue`. **Essencial!** Sem ela, o ECS não
  consegue ler DATABASE_URL, JWT_PRIVATE_KEY, JWT_PUBLIC_KEY ao iniciar
  o container, e a tarefa falha com
  `AccessDeniedException: não autorizado a performar secretsmanager:GetSecretValue`.

#### Dependências

- **Nada.** A role é independente.

#### Quem depende dela

- O ECS Express service a usa como `execution_role_arn`.

---

### ECS Task Role (Infrastructure Role)

```hcl
resource "aws_iam_role" "ecs_task" {
  name = "fast-feet-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ecs.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
  tags = { IAC = "true" }
}
```

#### O que é

Role que a **aplicação (container)** usa em runtime para acessar recursos
AWS (S3, Secrets Manager, etc). No ECS Express, esta role também serve como
**infrastructure role** — é a role que o ECS Express usa para **provisionar
automaticamente** o ALB, security groups, CloudWatch alarms, certificado
SSL, etc.

#### Trust policy: `ecs.amazonaws.com` (NÃO `ecs-tasks.amazonaws.com`)

**Isso é crítico.** O ECS Express exige que o **infrastructure role** confie
no serviço `ecs.amazonaws.com`, não `ecs-tasks.amazonaws.com`.
Se errar isso, o ECS Express rejeita a role e o provisioning falha.

---

#### Política inline do Task Role — 6 blocos de permissões

```hcl
resource "aws_iam_role_policy" "ecs_task" {
  name = "fast-feet-task-policy"
  role = aws_iam_role.ecs_task.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { # Bloco 1: S3
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.uploads.arn,
          "${aws_s3_bucket.uploads.arn}/*",
        ]
      },
      { # Bloco 2: Secrets Manager
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = ["*"]
      },
      { # Bloco 3: CloudWatch Logs
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = ["*"]
      },
      { # Bloco 4: Elastic Load Balancing
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
        ]
        Resource = ["*"]
      },
      { # Bloco 5: EC2
        Effect = "Allow"
        Action = [
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeRouteTables",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInstances",
          "ec2:CreateSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:DeleteSecurityGroup",
          "ec2:CreateTags",
        ]
        Resource = ["*"]
      },
      { # Bloco 6: IAM
        Effect = "Allow"
        Action = ["iam:CreateServiceLinkedRole"]
        Resource = ["*"]
      },
    ]
  })
}
```

**Cada bloco explicado:**

| Bloco | Permissões | Por que existe |
|-------|------------|----------------|
| **1. S3** | PutObject, GetObject, DeleteObject, ListBucket | A aplicação faz upload/download de fotos de comprovante de entrega |
| **2. Secrets Manager** | GetSecretValue | A aplicação em runtime pode precisar ler secrets (ex: se houver cache) |
| **3. CloudWatch Logs** | Criar grupos/streams, enviar logs | O container precisa escrever logs para debug |
| **4. ELB** | CRUD completo de ALB, target groups, listeners | **ESSENCIAL para ECS Express:** o ECS Express provisiona um ALB automaticamente — sem essas permissões ele não consegue criar |
| **5. EC2** | Descrever/criar security groups, subnets, VPCs | Provisionamento automático da infraestrutura de rede do ALB |
| **6. IAM** | CreateServiceLinkedRole | Criação de service-linked roles para ELB e Auto Scaling quando necessário |

---

#### Managed Policy Anexada

```hcl
resource "aws_iam_role_policy_attachment" "ecs_task" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices"
}
```

##### O que é

Managed policy da AWS chamada `AmazonECSInfrastructureRoleforExpressGatewayServices`
que contém as permissões necessárias para o ECS Express provisionar:

- Certificados SSL (ACM)
- CloudWatch Alarms (para auto scaling)
- Application Auto Scaling
- Tags nos recursos provisionados

##### Por que a inline policy não foi suficiente

Durante o desenvolvimento, descobrimos que mesmo com as 6 inline policies
acima, o ECS Express ainda falhava ao provisionar. A managed policy da AWS
inclui permissões específicas (como ACM, Application Auto Scaling) que são
necessárias e que não replicamos exatamente por tentativa e erro.

**Conclusão:** anexar a managed policy foi a solução que de fato fez o ECS
Express provisionar com sucesso. Manter a inline policy é complementar —
dá permissões extras (S3, Secrets Manager) que a managed policy não cobre.

---

### ECS Cluster

```hcl
resource "aws_ecs_cluster" "app" {
  name = "fast-feet"
  tags = { IAC = "true" }
}
```

#### O que é

Cluster ECS chamado `fast-feet`. É o agrupamento lógico onde o serviço ECS
Express vai rodar.

#### Por que existe

O ECS Express service precisa de um cluster para ser criado. Sem ele, o
recurso `aws_ecs_express_gateway_service` não tem onde ser alocado.

#### Detalhes

- É um cluster simples (sem capacidade providers, sem Auto Scaling Group,
  sem instâncias EC2) — o ECS Express gerencia tudo automaticamente.

---

### ECS Express Gateway Service

```hcl
resource "aws_ecs_express_gateway_service" "app" {
  depends_on = [
    aws_iam_role_policy_attachment.ecs_task_execution,
    aws_iam_role_policy.ecs_task,
    aws_iam_role_policy_attachment.ecs_task,
    aws_ecs_cluster.app,
  ]
  service_name            = "fast-feet"
  cluster                 = aws_ecs_cluster.app.name
  execution_role_arn      = aws_iam_role.ecs_task_execution.arn
  infrastructure_role_arn = aws_iam_role.ecs_task.arn

  cpu    = "512"
  memory = "1024"
  health_check_path = "/health"

  network_configuration {
    subnets         = data.aws_subnets.default.ids
    security_groups = [data.aws_security_group.default.id]
  }

  primary_container {
    image          = "${aws_ecr_repository.app.repository_url}:main"
    container_port = 3333

    environment {
      name  = "PORT"
      value = "3333"
    }
    environment {
      name  = "NODE_ENV"
      value = "production"
    }
    environment {
      name  = "AWS_S3_BUCKET"
      value = aws_s3_bucket.uploads.bucket
    }
    environment {
      name  = "AWS_REGION"
      value = "us-east-2"
    }
    environment {
      name  = "AWS_ENDPOINT"
      value = ""
    }

    secret {
      name       = "DATABASE_URL"
      value_from = aws_secretsmanager_secret.db.arn
    }
    secret {
      name       = "JWT_PRIVATE_KEY"
      value_from = aws_secretsmanager_secret.jwt_private.arn
    }
    secret {
      name       = "JWT_PUBLIC_KEY"
      value_from = aws_secretsmanager_secret.jwt_public.arn
    }
  }

  scaling_target {
    min_task_count            = 1
    max_task_count            = 3
    auto_scaling_metric       = "AVERAGE_CPU"
    auto_scaling_target_value = 70
  }

  wait_for_steady_state = true

  timeouts {
    create = "60m"
    update = "60m"
  }

  tags = { IAC = "true" }
}
```

#### O que é

O **recurso principal** de toda a infraestrutura. O `aws_ecs_express_gateway_service`
provisiona um serviço ECS no **Express Mode**, que é uma modalidade mais
simples que o ECS Fargate tradicional — ele gerencia automaticamente:

- Load Balancer (ALB)
- Security Groups
- Certificado SSL (HTTPS)
- DNS (domínio `*.ecs.on.aws`)
- Auto Scaling (com CloudWatch Alarms)
- Logs no CloudWatch

#### Atributos explicados

##### `depends_on`

Garante que as roles e o cluster estejam prontos antes de criar o serviço.
Sem isso, o Terraform pode tentar criar o serviço antes das roles existirem.

##### `execution_role_arn` vs `infrastructure_role_arn`

- **execution_role_arn** = `aws_iam_role.ecs_task_execution.arn` (role que
  o agente ECS usa para baixar a imagem e configurar o container)
- **infrastructure_role_arn** = `aws_iam_role.ecs_task.arn` (role que o
  ECS Express usa para provisionar ALB, SG, SSL, etc)

##### `health_check_path`

Caminho que o ALB vai usar para verificar se o container está saudável.
A aplicação precisa ter um endpoint `GET /health` que retorne `200 OK`.

##### `network_configuration`

**Obrigatório para ECS Express!** Define:
- **subnets:** onde as tarefas serão alocadas (usamos as subnets da VPC
  default)
- **security_groups:** regras de firewall para o tráfego (usamos o SG
  default que permite tráfego interno na VPC)

Se omitir `network_configuration`, o provisionamento falha.

##### `primary_container`

Define o container principal:

| Atributo | Valor | Explicação |
|----------|-------|------------|
| `image` | `${...repository_url}:main` | A imagem `:main` do ECR |
| `container_port` | `3333` | Porta que a aplicação ouve (definida em `main.ts`) |
| `environment` | PORT, NODE_ENV, AWS_S3_BUCKET, AWS_REGION, AWS_ENDPOINT | Variáveis injetadas no container |
| `secret` | DATABASE_URL, JWT_PRIVATE_KEY, JWT_PUBLIC_KEY | Secrets injetados como variáveis de ambiente seguras |

**`AWS_ENDPOINT` vazio:** Em desenvolvimento local, usamos LocalStack,
então o default no Zod é `http://localhost:4566`. Em produção, com task role,
o endpoint S3 deve ser vazio para usar o endpoint real da AWS.

##### `scaling_target`

Define a política de auto scaling:

- **min_task_count:** 1 (mínimo uma tarefa sempre rodando)
- **max_task_count:** 3 (pode escalar até 3 tarefas)
- **auto_scaling_metric:** `"AVERAGE_CPU"` (baseado em CPU)
- **auto_scaling_target_value:** `70` (escala quando CPU média > 70%)

**Nota:** No provider `hashicorp/aws` versão 6.x, os atributos foram
renomeados:
- Antes: `min_capacity`, `max_capacity`, `target_cpu`
- Agora: `min_task_count`, `max_task_count`, `auto_scaling_metric`,
  `auto_scaling_target_value`

##### `wait_for_steady_state`

Faz o Terraform aguardar até que o serviço esteja estável (tasks rodando,
health check passando) antes de marcar o recurso como criado com sucesso.

##### `timeouts` (60 minutos)

O ECS Express leva **vários minutos** para provisionar (cria ALB, SSL,
security groups, DNS). Sem um timeout alto, o Terraform aborta antes do
fim com erro de timeout.

#### Dependências

| Dependência | Para que serve |
|-------------|----------------|
| `aws_ecs_cluster.app` | O cluster deve existir |
| `aws_iam_role.ecs_task_execution` | Execution role deve existir |
| `aws_iam_role.ecs_task` | Infrastructure role deve existir |
| `aws_iam_role_policy_attachment.ecs_task_execution` | Permissões do execution role |
| `aws_iam_role_policy.ecs_task` | Permissões inline do task role |
| `aws_iam_role_policy_attachment.ecs_task` | Managed policy do task role |
| `aws_ecr_repository.app` | Repositório com a imagem Docker |
| `aws_s3_bucket.uploads` | Bucket S3 configurado como env var |
| `aws_secretsmanager_secret.db` | Secret DATABASE_URL |
| `aws_secretsmanager_secret.jwt_private` | Secret JWT_PRIVATE_KEY |
| `aws_secretsmanager_secret.jwt_public` | Secret JWT_PUBLIC_KEY |
| `data.aws_vpc.default` | VPC para network_configuration |
| `data.aws_subnets.default` | Subnets para as tarefas |
| `data.aws_security_group.default` | Security group das tarefas |

---

## 9. `outputs.tf` — Saídas do Terraform

```hcl
output "service_url" {
  value = try(
    aws_ecs_express_gateway_service.app.ingress_paths[0].endpoint,
    aws_ecs_express_gateway_service.app.service_arn
  )
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "db_endpoint" {
  value = aws_db_instance.postgres.address
}

output "s3_bucket" {
  value = aws_s3_bucket.uploads.bucket
}
```

### O que são

Valores exibidos no terminal após `terraform apply`, úteis para consulta
rápida e para usar em scripts.

| Output | Como acessar | Para que serve |
|--------|--------------|----------------|
| `service_url` | URL do ECS Express (ex: `https://xxxx.ecs.on.aws`) | Endpoint público da API |
| `ecr_repository_url` | URL do repositório ECR | Usado na CI para push |
| `db_endpoint` | Endpoint do RDS | Conectar no banco manualmente |
| `s3_bucket` | Nome do bucket | Configurar ambiente local |

### `service_url` — detalhes

Usa `try()` para retornar o endpoint do ingress se disponível (após o
provisionamento completo) ou fallback para o ARN do serviço.

---

## 10. Fluxo Completo — Ordem de Criação e Dependências

Diagrama textual das dependências entre os recursos:

```
                    ┌──────────────────────────────┐
                    │         main.tf              │
                    │  Provider AWS (us-east-2)    │
                    └──────────────┬───────────────┘
                                   │
            ┌──────────────────────┼──────────────────────┐
            │                      │                      │
            ▼                      ▼                      ▼
   ┌────────────────┐    ┌──────────────────┐    ┌──────────────┐
   │    ecr.tf      │    │   secrets.tf     │    │    s3.tf     │
   │  ECR Repo      │    │  3 Secrets       │    │  S3 Bucket   │
   │  Lifecycle     │    │  (sem valores)   │    │  + bloqueio  │
   └────────────────┘    └──────────────────┘    └──────────────┘
            │                      │                      │
            │                      │                      │
            ▼                      ▼                      ▼
   ┌──────────────────────────────────────────────────────────┐
   │                    iam.tf                                │
   │  OIDC Provider (GitHub) → GitHub Actions Role            │
   └──────────────────────┬───────────────────────────────────┘
                          │
                          ▼
   ┌──────────────────────────────────────────────────────────┐
   │                iam-policies.tf                           │
   │  GitHub Actions Policy (ECR push + ECS update + PassRole)│
   └──────────────────────────────────────────────────────────┘
                          │
                          ▼
   ┌──────────────────────────────────────────────────────────┐
   │                    rds.tf                                │
   │  Random Password → RDS PostgreSQL (db.t3.micro)          │
   └──────────────────────────────────────────────────────────┘
                          │
                          ▼
   ┌──────────────────────────────────────────────────────────┐
   │                  ecs-express.tf                          │
   │                                                          │
   │  ┌────────────────┐   ┌──────────────────────────────┐   │
   │  │Execution Role  │   │  Task/Infrastructure Role    │   │
   │  │+ ECSExecRole   │   │  + Inline Policy (6 blocos)  │   │
   │  │+ SecretGetValue│   │  + Managed Policy (ECS Infra)│   │
   │  └────────┬───────┘   └────────────────┬─────────────┘   │
   │           │                            │                 │
   │           └──────────┬─────────────────┘                 │
   │                      ▼                                   │
   │           ┌──────────────────────┐                       │
   │           │   ECS Cluster        │                       │
   │           └──────────┬───────────┘                       │
   │                      ▼                                   │
   │           ┌──────────────────────────────────────────┐   │
   │           │  ECS Express Gateway Service             │   │
   │           │  = ALB + SSL + DNS + Auto Scaling + TASK │   │
   │           └──────────────────────────────────────────┘   │
   └──────────────────────────────────────────────────────────┘
                          │
                          ▼
   ┌──────────────────────────────────────────────────────────┐
   │                   outputs.tf                             │
   │  service_url, ecr_repository_url, db_endpoint, s3_bucket │
   └──────────────────────────────────────────────────────────┘
```

### O que precisa ser feito APÓS o `terraform apply`

1. **Populart as Secrets** (via Console AWS ou CLI):
   - `fast-feet/database-url`: `postgresql://fastfeet:<password>@<db_endpoint>:5432/fastfeet`
   - `fast-feet/jwt-private-key`: chave privada RSA (gerar com `openssl genpkey -algorithm RSA -out private.pem`)
   - `fast-feet/jwt-public-key`: chave pública RSA (extrair com `openssl rsa -pubout -in private.pem -out public.pem`)

2. **Fazer push da imagem Docker** para o ECR (via CI ou manual):
   - A tag `:main` precisa existir no ECR
   - Se a CI já rodar, ela faz push automaticamente

3. **Forçar novo deploy** no ECS:
   ```bash
   aws ecs update-service --cluster fast-feet --service fast-feet --force-new-deployment
   ```
   (Isso é feito automaticamente pela CD pipeline no GitHub Actions)
