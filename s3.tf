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
