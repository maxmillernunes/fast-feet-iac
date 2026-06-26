output "service_url" {
  value = try(aws_ecs_express_gateway_service.app.ingress_paths[0].endpoint, aws_ecs_express_gateway_service.app.service_arn)
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
