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
