data "aws_availability_zones" "available" {}

locals {
  name     = var.project
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
  services = ["catalog", "orders", "notifications", "storefront"]
  tags     = { Project = var.project, ManagedBy = "terraform" }
}

# ---------------- Network (VPC across 2 AZs) ----------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${local.name}-vpc"
  cidr = local.vpc_cidr
  azs  = local.azs

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # one NAT keeps cost down for learning

  # Tags the AWS Load Balancer Controller needs to find subnets.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }

  tags = local.tags
}

# ---------------- EKS cluster ----------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = local.name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true # the identity that runs terraform becomes a cluster admin

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

# ATHIS BLOCK ENABLES THE ALB CONTROLLER CAN MODIFY NODE SECURITY GROUPS:
  node_security_group_tags = {
    "kubernetes.io/cluster/${local.name}" = "owned"
  }

  eks_managed_node_groups = {
    default = {
      instance_types = ["c7i-flex.large"]
      desired_size   = 2
      min_size       = 2
      max_size       = 3

      # Phase 1: let pods use the node role to reach SQS. Phase 2 tightens this to IRSA.
      iam_role_additional_policies = {
        sqs = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
      }
    }
  }

  tags = local.tags
}

# ---------------- ECR (one repo per service) ----------------
resource "aws_ecr_repository" "service" {
  for_each             = toset(local.services)
  name                 = "${local.name}-${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
  tags = local.tags
}

# ---------------- SQS (order events) ----------------
resource "aws_sqs_queue" "order_events" {
  name = "${local.name}-order-events"
  tags = local.tags
}

# ---------------- RDS PostgreSQL ----------------
resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "Allow PostgreSQL from inside the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "PostgreSQL from the VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.5"

  identifier = "${local.name}-db"

  engine               = "postgres"
  engine_version       = "16"
  family               = "postgres16"
  instance_class       = "db.t3.micro"
  allocated_storage    = 20

  db_name  = "shopflow"
  username = var.db_username
  password = var.db_password
  port     = 5432
  manage_master_user_password = false

  multi_az               = false # Phase 1: single AZ to save cost
  vpc_security_group_ids = [aws_security_group.rds.id]
  create_db_subnet_group = true
  subnet_ids             = module.vpc.private_subnets

  skip_final_snapshot = true
  deletion_protection = false

  tags = local.tags
}

# ---------------- RDS Proxy ----------------
data "aws_caller_identity" "current" {}

resource "aws_security_group" "rds_proxy" {
  name        = "${local.name}-rds-proxy"
  description = "Allow database proxy access from inside the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "PostgreSQL proxy access from the VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_iam_role" "rds_proxy" {
  name               = "${local.name}-rds-proxy-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
      },
    ]
  })
  tags = local.tags
}

data "aws_iam_policy_document" "rds_proxy_secret_access" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = [aws_secretsmanager_secret.rds_proxy_credentials.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "rds-db:connect",
    ]
    resources = ["arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.rds.db_instance_resource_id}/${var.db_username}"]
  }
}

resource "aws_iam_role_policy" "rds_proxy_secret_access" {
  name   = "${local.name}-rds-proxy-secret-access"
  role   = aws_iam_role.rds_proxy.id
  policy = data.aws_iam_policy_document.rds_proxy_secret_access.json
}

resource "aws_secretsmanager_secret" "rds_proxy_credentials" {
  name = "${local.name}-db-proxy-credentials"
  description = "RDS Proxy credentials for ${local.name}"
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "rds_proxy_credentials" {
  secret_id     = aws_secretsmanager_secret.rds_proxy_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
  })
}

resource "aws_db_proxy" "shopflow_db_proxy" {
  name                   = "${local.name}-db-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]
  idle_client_timeout    = 1800
  require_tls            = false

  auth {
    auth_scheme = "SECRETS"
    secret_arn  = aws_secretsmanager_secret.rds_proxy_credentials.arn
    iam_auth    = "DISABLED"
  }

  tags = local.tags
}

resource "aws_db_proxy_target" "shopflow_db_proxy_target" {
  db_proxy_name        = aws_db_proxy.shopflow_db_proxy.name
  target_group_name    = "default"
  db_instance_identifier = module.rds.db_instance_identifier
  depends_on           = [module.rds]
}
