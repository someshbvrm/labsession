terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Get the latest Ubuntu 22.04 AMI from Canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  owners = ["099720109477"] # Canonical
}

resource "random_id" "id" {
  byte_length = 4
}

# Launch EC2 instance in default VPC & default security group
resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = "keypair_stockholms"
  associate_public_ip_address = true   # ensure public IP in default VPC

  # By default, AWS assigns the default security group of the default VPC
  # (allows all egress, but no ingress except when manually modified)

  tags = {
    Name = "jenkins-java-app"
  }
}
