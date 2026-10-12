# Application Load Balancer -> Target Group -> Auto Scaling Group of EC2 instances.
# Each instance runs a Docker container (by default the image from docker-cicd-pipeline).

# Latest Amazon Linux 2023 AMI, looked up at plan time, never hard-coded
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---------- Security groups ----------
resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Public HTTP into the load balancer"
  vpc_id      = var.vpc_id
  tags        = var.tags

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.name}-app-"
  description = "Only the ALB may reach the app port"
  vpc_id      = var.vpc_id
  tags        = var.tags

  ingress {
    description     = "App port from ALB only"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Pull images and OS updates"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------- Load balancer ----------
resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.subnet_ids
  tags               = var.tags
}

resource "aws_lb_target_group" "app" {
  name_prefix = "app-"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  tags        = var.tags

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  # Faster deploys: don't wait the default 300s when draining instances
  deregistration_delay = 30

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------- Compute ----------
resource "aws_launch_template" "app" {
  name_prefix            = "${var.name}-"
  image_id               = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.app.id]

  # IMDSv2 only - blocks the classic SSRF credential-theft attack
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    image          = var.container_image
    container_port = var.container_port
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-app" })
  }
}

resource "aws_autoscaling_group" "app" {
  name_prefix               = "${var.name}-"
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.min_size
  vpc_zone_identifier       = var.subnet_ids
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB" # replace instances the ALB marks unhealthy
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # Changing the launch template (e.g. new image) rolls instances gradually
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  dynamic "tag" {
    for_each = merge(var.tags, { Name = "${var.name}-app" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# Scale out/in to keep average CPU around the target
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target
  }
}
