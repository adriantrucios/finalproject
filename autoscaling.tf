resource "aws_vpc" "my_vpc" {
  cidr_block           = "10.100.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "My VPC"

  }
}

resource "aws_subnet" "public_us_east_1a" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.100.1.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name = "Public subnet us east 1a"
  }
}

resource "aws_subnet" "public_us_east_1b" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.100.2.0/24"
  availability_zone = "us-east-1b"
  tags = {
    Name = "Public subnet us east 1b"
  }
}

resource "aws_internet_gateway" "my_vpc_igw" {
  vpc_id = aws_vpc.my_vpc.id
  tags = {
    Name = "My IG"
  }

}

resource "aws_route_table" "my_vpc_public" {
  vpc_id = aws_vpc.my_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.my_vpc_igw.id
  }
  tags = {
    Name = "Public subnet route"
  }
}

resource "aws_route_table_association" "my_vpc_us_east_1a_public" {
  subnet_id      = aws_subnet.public_us_east_1a.id
  route_table_id = aws_route_table.my_vpc_public.id
}

resource "aws_route_table_association" "my_vpc_us_east_1b_public" {
  subnet_id      = aws_subnet.public_us_east_1b.id
  route_table_id = aws_route_table.my_vpc_public.id
}

resource "aws_security_group" "allow_http" {
  name        = "allow_http"
  description = "Allow http ssh connections"
  vpc_id      = aws_vpc.my_vpc.id

  ingress {
    description      = "HTTP from everywhere"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description      = "SSH from everywhere"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "Allow HTTP Security Group"

  }
}

# Adding SSH key to Amazon EC2
resource "aws_key_pair" "web_key" {
  key_name   = "linux_final"
  public_key = file("/home/ec2-user/.ssh/linux.pub")
}

# Data source for AMI id
data "aws_ami" "latest_amazon_linux" {
  owners      = ["amazon"]
  most_recent = true
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_launch_configuration" "web" {
  name_prefix                 = "dev-web-"
  image_id                    = "ami-0a3c14e1ddbe7f23c"
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.web_key.key_name
  security_groups             = ["${aws_security_group.allow_http.id}"]
  associate_public_ip_address = true
  user_data = templatefile("${path.module}/install_httpd.sh.tpl",
    {
      env    = "dev",
      prefix = "finalproject"
    }
  )
}


resource "aws_security_group" "elb_http" {
  name        = "elb_http"
  description = "Allow http ssh connections"
  vpc_id      = aws_vpc.my_vpc.id

  ingress {
    description      = "HTTP from everywhere"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description      = "SSH from everywhere"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "Allow ELB HTTP Security Group"

  }
}

resource "aws_elb" "web_elb" {
  name            = "web-elb"
  security_groups = ["${aws_security_group.elb_http.id}"]
  subnets = [
    "${aws_subnet.public_us_east_1a.id}",
    "${aws_subnet.public_us_east_1b.id}"
  ]
  cross_zone_load_balancing = true
  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    interval            = 30
    target              = "HTTP:80/"
  }
  listener {
    lb_port           = 80
    lb_protocol       = "http"
    instance_port     = "80"
    instance_protocol = "http"
  }
}

resource "aws_autoscaling_group" "web" {
  name                 = "${aws_launch_configuration.web.name}-asg"
  min_size             = 1
  desired_capacity     = 1
  max_size             = 2
  health_check_type    = "ELB"
  load_balancers       = ["${aws_elb.web_elb.id}"]
  launch_configuration = aws_launch_configuration.web.name
  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances"
  ]
  metrics_granularity = "1Minute"
  vpc_zone_identifier = [
    "${aws_subnet.public_us_east_1a.id}",
    "${aws_subnet.public_us_east_1b.id}"
  ]

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "web"
    propagate_at_launch = true

  }
}


resource "aws_autoscaling_policy" "web_policy_up" {
  name                   = "web_policy_up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.web.name
}

resource "aws_cloudwatch_metric_alarm" "web_cpu_alarm_up" {
  alarm_name          = "web_cpu_alarm_up"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "50"
  dimensions = {
    AutoScalingGroupName = "${aws_autoscaling_group.web.name}"
  }
  alarm_description = "Metric to monitor EC2 CPU usage"
  alarm_actions     = ["${aws_autoscaling_policy.web_policy_up.arn}"]
}


resource "aws_autoscaling_policy" "web_policy_down" {
  name                   = "web_policy_down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.web.name
}


resource "aws_cloudwatch_metric_alarm" "web_cpu_alarm_down" {
  alarm_name          = "web_cpu_alarm_down"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "20"
  dimensions = {
    AutoScalingGroupName = "${aws_autoscaling_group.web.name}"
  }
  alarm_description = "Metric to monitor EC2 CPU usage"
  alarm_actions     = ["${aws_autoscaling_policy.web_policy_up.arn}"]
}





[![tfsec](https://github.com/adriantrucios/finalproject/actions/workflows/tfsec.yml/badge.svg)](https://github.com/adriantrucios/finalproject/actions/workflows/tfsec.yml)


