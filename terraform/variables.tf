variable "aws_region" {
  description = "The AWS region where resources will be created"
  type        = string
  default     = "eu-north-1" # Stockholm region
}

variable "instance_type" {
  description = "The EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "ssh_public_key" {
  description = "The public SSH key to be used for EC2 instance access"
  type        = string
}
