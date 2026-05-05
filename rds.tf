resource "aws_security_group" "postgres" {
  name        = "${var.name}-postgres-${var.env}"
  description = "PostgreSQL access from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    protocol        = "tcp"
    from_port       = 5432
    to_port         = 5432
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    description = "Allow all outbound"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.name}-postgres-${var.env}"
    Environment = var.env
    Project     = var.name
  }
}

resource "aws_db_instance" "postgres" {
  identifier = "${var.name}-postgres-${var.env}"

  engine         = "postgres"
  engine_version = "16"
  instance_class = var.postgres_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.postgres_db_name
  username = var.postgres_db_username
  password = var.postgres_db_password

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.postgres.id]
  publicly_accessible    = false

  multi_az                = false
  backup_retention_period = 1
  deletion_protection     = false
  skip_final_snapshot     = true

  performance_insights_enabled = false
  auto_minor_version_upgrade   = true
  apply_immediately            = true

  tags = {
    Name        = "${var.name}-postgres-${var.env}"
    Environment = var.env
    Project     = var.name
  }
}

output "postgres_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "postgres_address" {
  value = aws_db_instance.postgres.address
}

output "postgres_port" {
  value = aws_db_instance.postgres.port
}

output "postgres_database_name" {
  value = aws_db_instance.postgres.db_name
}

output "postgres_username" {
  value = aws_db_instance.postgres.username
}
