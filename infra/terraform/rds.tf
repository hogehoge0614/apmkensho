# ============================================================
# RDS PostgreSQL db.t3.micro — NetWatch device database
# Single-AZ, private subnets (no NAT needed for RDS itself)
# ============================================================

resource "aws_db_subnet_group" "netwatch" {
  name       = "${var.cluster_name}-netwatch"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.cluster_name}-netwatch-rds-subnet-group"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds"
  description = "Allow PostgreSQL from within VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-rds-sg"
  }
}

resource "aws_db_instance" "netwatch" {
  identifier        = "${var.cluster_name}-netwatch"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"
  allocated_storage = 20

  db_name  = "netwatch"
  username = "netwatch"
  password = var.rds_password

  db_subnet_group_name   = aws_db_subnet_group.netwatch.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az               = false
  publicly_accessible    = false
  storage_encrypted      = false
  skip_final_snapshot    = true
  deletion_protection    = false
  apply_immediately      = true

  tags = {
    Name = "${var.cluster_name}-netwatch"
  }
}
