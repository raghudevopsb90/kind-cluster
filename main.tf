resource "aws_instance" "kind" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  associate_public_ip_address = true

  # Spot with no max_price. AWS then uses its default cap, the On-Demand price,
  # and charges the current Spot price while the instance runs.
  instance_market_options {
    market_type = "spot"
  }

  root_block_device {
    volume_type           = "gp3"
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
