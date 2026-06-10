# ── IAM Role for Jenkins EC2 instance ───────────────────────
resource "aws_iam_role" "jenkins" {
  name = "jenkins-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ── Policy: ECR push/pull ────────────────────────────────────
resource "aws_iam_policy" "ecr_access" {
  name        = "jenkins-ecr-${var.environment}"
  description = "Allow Jenkins to push/pull images to ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:ListImages"
        ]
        Resource = "*"
      }
    ]
  })
}

# ── Policy: S3 artifact read/write (scoped to bucket) ────────
resource "aws_iam_policy" "s3_artifacts" {
  name        = "jenkins-s3-artifacts-${var.environment}"
  description = "Allow Jenkins to read/write build artifacts"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          var.artifact_bucket_arn,
          "${var.artifact_bucket_arn}/*"
        ]
      },
      # Deny delete on objects older than 90 days (enforce retention via policy, not lifecycle)
      {
        Effect   = "Deny"
        Action   = "s3:DeleteObject"
        Resource = "${var.artifact_bucket_arn}/*"
        Condition = {
          NumericLessThan = {
            "s3:object-age" = 90
          }
        }
      }
    ]
  })
}

# ── Policy: CloudWatch Logs ───────────────────────────────────
resource "aws_iam_policy" "cloudwatch_logs" {
  name = "jenkins-cloudwatch-${var.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "arn:aws:logs:*:*:*"
    }]
  })
}

# ── Attach policies to role ────────────────────────────────────
resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.jenkins.name
  policy_arn = aws_iam_policy.ecr_access.arn
}

resource "aws_iam_role_policy_attachment" "s3" {
  role       = aws_iam_role.jenkins.name
  policy_arn = aws_iam_policy.s3_artifacts.arn
}

resource "aws_iam_role_policy_attachment" "cw" {
  role       = aws_iam_role.jenkins.name
  policy_arn = aws_iam_policy.cloudwatch_logs.arn
}

# Managed SSM policy — allows Session Manager instead of open SSH
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ── Instance Profile ──────────────────────────────────────────
resource "aws_iam_instance_profile" "jenkins" {
  name = "jenkins-profile-${var.environment}"
  role = aws_iam_role.jenkins.name
}

output "jenkins_instance_profile_name" {
  value = aws_iam_instance_profile.jenkins.name
}
