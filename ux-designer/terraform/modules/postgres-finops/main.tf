# Terraform module for PostgreSQL 16 (FinOps waste tracking)
# Provider: AWS RDS or GCP Cloud SQL depending on cloud

locals {
  db_name     = "finops_waste"
  db_username = "finops_svc"
}

resource "random_password" "db_password" {
  length           = 24
  special          = false
  override_special = "_%"
}

# For AWS RDS
resource "aws_db_instance" "finops" {
  count = var.provider == "aws" ? 1 : 0

  identifier     = "${var.environment}-finops-waste"
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = var.instance_class

  db_name  = local.db_name
  username = local.db_username
  password = random_password.db_password.result

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_encrypted     = true
  storage_type          = "gp3"

  vpc_security_group_ids = var.security_group_ids
  db_subnet_group_name   = var.db_subnet_group_name

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:05:00-sun:06:00"
  deletion_protection     = true
  skip_final_snapshot     = false
  final_snapshot_identifier = "${var.environment}-finops-waste-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = {
    Name        = "${var.environment}-finops-waste"
    Environment = var.environment
    ManagedBy   = "terraform"
    Service     = "finops-analyzer"
  }
}

# For GCP Cloud SQL
resource "google_sql_database_instance" "finops" {
  count = var.provider == "gcp" ? 1 : 0

  name             = "${var.environment}-finops-waste"
  database_version = "POSTGRES_16"
  region           = var.region

  settings {
    tier              = var.gcp_tier
    disk_type         = "PD_SSD"
    disk_size         = var.allocated_storage_gb
    disk_autoresize   = true
    disk_autoresize_limit = var.max_allocated_storage_gb

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      retention_count                = 7
      transaction_log_retention_days = 7
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.private_network_id
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 4096
      record_application_tags = false
      record_client_address   = false
    }
  }

  deletion_protection = true
}

# Outputs
output "db_host" {
  value = var.provider == "aws" ? aws_db_instance.finops[0].address : google_sql_database_instance.finops[0].private_ip_address
}

output "db_port" {
  value = 5432
}

output "db_name" {
  value = local.db_name
}

output "db_username" {
  value = local.db_username
}

output "db_password_secret_name" {
  value = "${var.environment}/finops/db-password"
}
