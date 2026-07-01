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

data "aws_iam_policy_document" "tf_role" {
  statement {
    sid       = "Statement1"
    effect    = "Allow"
    actions   = ["ecr:*"]
    resources = ["*"]
  }

  statement {
    sid       = "Statement2"
    effect    = "Allow"
    actions   = ["iam:*"]
    resources = ["*"]
  }

  statement {
    sid       = "Statement3"
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "tf_role" {
  name   = "tf-role-policy"
  role   = aws_iam_role.tf-role.name
  policy = data.aws_iam_policy_document.tf_role.json
}
