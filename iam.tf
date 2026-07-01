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
          StringEquals : {
            "token.actions.githubusercontent.com:aud" : [
              "sts.amazonaws.com"
            ]
          },
          StringLike : {
            "token.actions.githubusercontent.com:sub" : [
              "repo:maxmillernunes/fast-feet:ref:refs/heads/main",
              "repo:maxmillernunes/fast-feet:ref:refs/heads/main"
            ]
          }
        }
      }
    ]
  })

  tags = { IAC = "true" }
}

resource "aws_iam_role" "tf-role" {
  name = "tf-role"

  assume_role_policy = jsonencode({
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" : [
              "sts.amazonaws.com"
            ]
          },
          StringLike : {
            "token.actions.githubusercontent.com:sub" : [
              "repo:maxmillernunes/fast-feet-iac:ref:refs/heads/main",
              "repo:maxmillernunes/fast-feet-iac:ref:refs/heads/main"
            ]
          }
        }
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
      }
    ]
    Version = "2012-10-17"
  })

  tags = { IAC = "true" }
}
