data "aws_security_group" "kind" {
  id = var.security_group_id
}

resource "aws_instance" "kind" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
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
    instance_id   = aws_instance.kind.id
    prepare_sha   = filesha256("${path.module}/scripts/prepare.sh")
    bootstrap_sha = filesha256("${path.module}/scripts/bootstrap.sh")
  }

  connection {
    type     = "ssh"
    user     = var.ssh_user
    password = var.ssh_password
    host     = aws_instance.kind.public_ip
    timeout  = "10m"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/prepare.sh"
    destination = "/home/${var.ssh_user}/kind-prepare.sh"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/bootstrap.sh"
    destination = "/home/${var.ssh_user}/kind-bootstrap.sh"
  }

  # One command per block. Terraform only checks the exit code of the last
  # inline line, so a failure earlier in a list goes unnoticed.
  provisioner "remote-exec" {
    inline = ["bash ~/kind-prepare.sh"]
  }

  # prepare.sh may have scheduled a reboot 5 seconds out. Wait until the box
  # is down; the next block's connection then retries until SSH is back.
  provisioner "local-exec" {
    command = "sleep 30"
  }

  provisioner "remote-exec" {
    inline = [
      "SSH_PASSWORD='${var.ssh_password}' KIND_CLUSTER_NAME='${var.kind_cluster_name}' bash ~/kind-bootstrap.sh && rm -f ~/kind-prepare.sh ~/kind-bootstrap.sh",
    ]
  }
}
