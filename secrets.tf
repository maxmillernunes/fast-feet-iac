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
