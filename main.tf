data "aws_security_group" "kind" {
  id = var.security_group_id
}

data "aws_subnets" "kind" {
  filter {
    name   = "vpc-id"
    values = [data.aws_security_group.kind.vpc_id]
  }
}

resource "random_shuffle" "subnet" {
  input        = sort(data.aws_subnets.kind.ids)
  result_count = 1
}

resource "aws_instance" "kind" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = random_shuffle.subnet.result[0]
  vpc_security_group_ids      = [var.security_group_id]
  associate_public_ip_address = true

  # Spot with no max_price. AWS then uses its default cap, the On-Demand price,
  # and charges the current Spot price while the instance runs.
  instance_market_options {
    market_type = "spot"
  }

  root_block_device {
    volume_type = "gp3"
    # 40 GiB. The guest still has the AMI partition table until bootstrap
    # runs growpart and lvextend on /dev/RootVG/varVol.
    volume_size           = var.root_volume_size
    delete_on_termination = true
  }

  tags = {
    Name = "kind-cluster"
  }
}

resource "null_resource" "kind_bootstrap" {
  triggers = {
    instance_id = aws_instance.kind.id
    script_sha  = filesha256("${path.module}/scripts/bootstrap.sh")
  }

  connection {
    type     = "ssh"
    user     = var.ssh_user
    password = var.ssh_password
    host     = aws_instance.kind.public_ip
    timeout  = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo -n true 2>/dev/null || echo '${var.ssh_password}' | sudo -S -p '' -v",
      "sudo dnf update -y",
      "sudo sh -c 'sleep 5; reboot' >/dev/null 2>&1 &",
    ]
  }

  provisioner "local-exec" {
    command = "sleep 120"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/bootstrap.sh"
    destination = "/tmp/bootstrap-kind.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 700 /tmp/bootstrap-kind.sh",
      "SSH_PASSWORD='${var.ssh_password}' KIND_CLUSTER_NAME='${var.kind_cluster_name}' bash /tmp/bootstrap-kind.sh",
      "rm -f /tmp/bootstrap-kind.sh",
    ]
  }
}
