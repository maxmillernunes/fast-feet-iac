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

resource "aws_iam_role_policy" "ecs_task" {
  name = "fast-feet-task-policy"
  role = aws_iam_role.ecs_task.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
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
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = ["*"]
      },
      {
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
      {
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
      {
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
      {
        Effect = "Allow"
        Action = ["iam:CreateServiceLinkedRole"]
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices"
}

resource "aws_ecs_cluster" "app" {
  name = "fast-feet"

  tags = { IAC = "true" }
}

resource "aws_ecs_express_gateway_service" "app" {
  depends_on              = [aws_iam_role_policy_attachment.ecs_task_execution, aws_iam_role_policy.ecs_task, aws_iam_role_policy_attachment.ecs_task, aws_ecs_cluster.app]
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
