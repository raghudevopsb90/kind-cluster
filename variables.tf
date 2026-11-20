variable "aws_region" {
  description = "Region for the AMI and security group. Leave unset to use the AWS CLI or environment region."
  type        = string
  default     = null
}

variable "ami_id" {
  description = "AMI to launch. The image must allow SSH as ec2-user with the configured password."
  type        = string
  default     = "ami-0eec78ea4cbaaf5bd"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "m6a.xlarge"
}

variable "security_group_id" {
  description = "Existing security group. It must allow SSH (TCP 22) from the host running Terraform."
  type        = string
  default     = "sg-01c38564765bc218b"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB. Bootstrap then grows the last partition and adds 10 GiB to /dev/RootVG/varVol."
  type        = number
  default     = 40
}

variable "ssh_user" {
  description = "SSH user for the remote-exec provisioner."
  type        = string
  default     = "ec2-user"
}

variable "ssh_password" {
  description = "SSH password for the remote-exec provisioner."
  type        = string
  sensitive   = true
  default     = "DevOps321"
}

variable "kind_cluster_name" {
  description = "Name of the kind cluster created after the instance boots."
  type        = string
  default     = "kind"
}
