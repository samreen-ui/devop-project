data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-*-x86_64"]
  }
}

resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.iam_instance_profile
  key_name               = var.key_name

  # Enforce IMDSv2 (prevents SSRF-based metadata attacks)
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/jenkins_userdata.sh.tpl", {
    environment = var.environment
  }))

  tags = {
    Name = "jenkins-master-${var.environment}"
    Role = "ci-cd"
  }
}

# ── CloudWatch alarms ────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "jenkins_cpu" {
  alarm_name          = "jenkins-cpu-high-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Jenkins CPU > 85% for 4 minutes"
  alarm_actions       = [var.sns_alert_arn]

  dimensions = {
    InstanceId = aws_instance.jenkins.id
  }
}

output "jenkins_instance_id" {
  value = aws_instance.jenkins.id
}

output "jenkins_private_ip" {
  value = aws_instance.jenkins.private_ip
}
