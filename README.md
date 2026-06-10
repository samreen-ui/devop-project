# Cloud-Native Deployment & CI/CD Pipeline

![Docker](https://img.shields.io/badge/Docker-2496ED?style=flat&logo=docker&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat&logo=kubernetes&logoColor=white)
![Jenkins](https://img.shields.io/badge/Jenkins-D24939?style=flat&logo=jenkins&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-232F3E?style=flat&logo=amazonaws&logoColor=white)
![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=flat&logo=terraform&logoColor=white)
![Maven](https://img.shields.io/badge/Maven-C71A36?style=flat&logo=apachemaven&logoColor=white)

End-to-end cloud-native deployment pipeline for a Java Spring Boot microservice — containerized with Docker, orchestrated on Kubernetes, automated via Jenkins + Maven CI/CD, and provisioned on AWS with Terraform.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Project Structure](#project-structure)
- [Docker](#docker)
- [Kubernetes](#kubernetes)
- [Jenkins Pipeline](#jenkins-pipeline)
- [AWS Infrastructure (Terraform)](#aws-infrastructure-terraform)
- [Security Practices](#security-practices)
- [Getting Started](#getting-started)
- [Environment Configuration](#environment-configuration)

---

## Architecture Overview

```
Developer Push
      │
      ▼
┌─────────────────────────────────────────────────────┐
│                  Jenkins Pipeline                    │
│  Checkout → Build/Test → Sonar → Docker Build/Push  │
│       → Deploy Staging → Smoke Test → [APPROVAL]    │
│                    → Deploy Prod                     │
└─────────────────────────────────────────────────────┘
      │                            │
      ▼                            ▼
 ECR (Docker Images)     AWS Infrastructure
                         (Terraform-managed)
      │                    VPC / EC2 / S3 / IAM
      ▼
┌──────────────┐     ┌──────────────────────┐
│   Staging    │     │     Production       │
│  EKS Cluster │     │    EKS Cluster       │
│  1 replica   │     │    3 replicas        │
│  DEBUG logs  │     │    WARN logs / HPA   │
└──────────────┘     └──────────────────────┘
```

---

## Project Structure

```
.
├── app/
│   └── pom.xml                        # Spring Boot 3.2 Maven build
├── docker/
│   ├── Dockerfile                     # Multi-stage build (builder → JRE-alpine)
│   └── docker-compose.yml             # Local dev with Postgres
├── k8s/
│   ├── base/
│   │   ├── deployment.yaml            # Deployment: rolling update, probes, HPA
│   │   ├── service.yaml               # ClusterIP Service
│   │   ├── configmap.yaml             # Non-sensitive app config
│   │   ├── hpa.yaml                   # HorizontalPodAutoscaler (2–10 pods)
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── staging/                   # 1 replica, DEBUG, relaxed resources
│       └── prod/                      # 3 replicas, WARN, full resources
├── jenkins/
│   └── Jenkinsfile                    # 8-stage declarative pipeline
└── terraform/
    ├── main.tf                        # Root module
    ├── variables.tf
    ├── modules/
    │   ├── vpc/                       # VPC, subnets, security groups
    │   ├── ec2/                       # Jenkins master, CloudWatch alarm
    │   ├── s3/                        # Artifact bucket, versioning, lifecycle
    │   └── iam/                       # Least-privilege roles and policies
    └── envs/
        ├── staging/terraform.tfvars
        └── prod/terraform.tfvars
```

---

## Docker

**Multi-stage Dockerfile** separates build from runtime:

| Stage | Base Image | Purpose |
|-------|-----------|---------|
| `builder` | `maven:3.9.5-eclipse-temurin-17` | Resolves dependencies, compiles JAR |
| `runtime` | `eclipse-temurin:17-jre-alpine` | Minimal runtime (~180MB vs ~500MB) |

Key decisions:
- `pom.xml` copied before source → dependency layer cached separately
- Non-root user (`appuser`) enforced at runtime
- `HEALTHCHECK` hits `/actuator/health` — aligns with K8s probes
- JVM flags: `-XX:+UseContainerSupport` and `-XX:MaxRAMPercentage=75.0`

**Local development:**
```bash
# Start app + Postgres
docker compose -f docker/docker-compose.yml up

# Build image only
docker build -f docker/Dockerfile -t user-service:local .
```

---

## Kubernetes

Manifests use **Kustomize** — single base, per-environment overlays.

### Base Resources

| Resource | Details |
|----------|---------|
| `Deployment` | `maxUnavailable: 0` rolling update, pod anti-affinity, Prometheus annotations |
| `Service` | ClusterIP on port 80 → container 8080 |
| `ConfigMap` | `SPRING_PROFILES_ACTIVE`, `LOG_LEVEL`, `DB_HOST`, feature flags |
| `HPA` | Scale 2–10 pods; CPU target 70%, memory target 80% |

### Environment Overlays

```
staging: 1 replica  │  DEBUG logging  │  100m CPU / 128Mi memory
prod:    3 replicas  │  WARN logging   │  500m CPU / 512Mi memory
```

### Deploy Commands

```bash
# Staging
kubectl apply -k k8s/overlays/staging/

# Production
kubectl apply -k k8s/overlays/prod/

# Check rollout
kubectl rollout status deployment/user-service -n user-service-prod
```

### Probes

```yaml
readinessProbe: /actuator/health/readiness   # gates traffic
livenessProbe:  /actuator/health/liveness    # triggers restart
```

---

## Jenkins Pipeline

8-stage declarative pipeline running on **Kubernetes pod agents** (no static workers — each build gets a clean pod with `maven`, `docker`, and `kubectl` containers).

```
Checkout → Build & Test → SonarQube → Docker Build/Push
        → Deploy Staging → Smoke Test → [Manual Approval] → Deploy Prod
```

### Stage Summary

| Stage | Key Behaviour |
|-------|--------------|
| **Build & Test** | `mvn clean verify -B`; publishes JUnit XML + JaCoCo coverage |
| **SonarQube** | Runs on `main` branch only; `waitForQualityGate` blocks pipeline |
| **Docker Build** | Tags image with Git short SHA + `latest`; pushes to ECR |
| **Deploy Staging** | `kustomize edit set image` + `kubectl apply -k`; waits for rollout |
| **Smoke Test** | HTTP check on `/actuator/health`; fails pipeline on non-200 |
| **Manual Approval** | `input` step; only `devops-leads` or `release-managers` can approve |
| **Deploy Prod** | Same as staging with prod kubeconfig and prod overlay |

### Pipeline Features

- `disableConcurrentBuilds()` — no race conditions on cluster deploys
- `timeout(45, MINUTES)` — stuck builds don't hold executors
- Image tag = Git SHA — every image traceable to exact commit
- Maven dependency cache via PVC — fast builds, no full re-download
- Slack notifications on success/failure with build URL

### Required Jenkins Credentials

| ID | Type | Used For |
|----|------|---------|
| `aws-ecr-credentials` | AWS | ECR login |
| `kubeconfig-staging` | Secret file | Staging cluster access |
| `kubeconfig-prod` | Secret file | Prod cluster access |
| `sonarqube-token` | Secret text | SonarQube analysis |
| `slack-webhook-url` | Secret text | Build notifications |

---

## AWS Infrastructure (Terraform)

Infrastructure is split into four independent modules, composed by the root `main.tf`.

### Modules

#### `modules/ec2` — Jenkins Master
- Private subnet (not internet-facing); access via **SSM Session Manager** (no open port 22)
- **IMDSv2 enforced** (`http_tokens = required`) — prevents SSRF metadata attacks
- Encrypted gp3 EBS root volume
- CloudWatch alarm → SNS when CPU > 85% for 4 minutes

#### `modules/s3` — Artifact Storage
- Versioning enabled — all artifact versions retained
- AES-256 server-side encryption
- All four `block_public_*` settings enabled
- Lifecycle: Standard → Standard-IA (30d) → Glacier (90d) → Delete (365d)

#### `modules/iam` — Least Privilege
- EC2 Instance Profile (no hardcoded access keys on disk)
- ECR policy scoped to `BatchCheckLayerAvailability`, `PutImage`, `UploadLayerPart`
- S3 policy scoped to the artifact **bucket ARN only** — not `*`
- CloudWatch Logs write access for build log streaming

#### `modules/vpc` — Networking
- Public and private subnets across 2 AZs
- Internet Gateway for public subnets; NAT Gateway for private subnets
- Security groups with minimal ingress rules

### Remote State

```hcl
backend "s3" {
  bucket         = "samreen-terraform-state"
  key            = "user-service/terraform.tfstate"
  region         = "ap-south-1"
  encrypt        = true
  dynamodb_table = "terraform-state-lock"   # prevents concurrent apply
}
```

### Terraform Commands

```bash
# Initialize (once per environment)
terraform init -backend-config=envs/staging/backend.hcl

# Plan — always review before apply
terraform plan -var-file=envs/staging/terraform.tfvars -out=plan.tfplan

# Apply
terraform apply plan.tfplan

# Destroy staging (never run against prod without explicit approval)
terraform destroy -var-file=envs/staging/terraform.tfvars
```

---

## Security Practices

| Area | Practice |
|------|---------|
| Credentials | All secrets in Jenkins Credential Store — never in Git |
| EC2 | IMDSv2 enforced; SSM instead of SSH; encrypted EBS |
| S3 | Public access blocked; versioning; AES-256 encryption |
| IAM | Resource-scoped policies (bucket ARN, not `*`); instance profile |
| Containers | Non-root UID 1000; `runAsNonRoot: true` in pod security context |
| Config | Secrets via K8s `secretRef`, not ConfigMap; never committed |
| Deployments | Manual approval gate before every production release |
| Terraform | Remote encrypted state; DynamoDB locking; `force_destroy = false` in prod |

---

## Getting Started

### Prerequisites

```
Docker 24+       kubectl 1.28+      terraform 1.6+
Java 17+         Maven 3.9+         AWS CLI v2
Jenkins 2.440+   kustomize 5+
```

### 1. Clone and build locally

```bash
git clone https://github.com/samreen/cloud-native-devops.git
cd cloud-native-devops

# Local run with Docker Compose
cp .env.example .env.local
docker compose -f docker/docker-compose.yml up --build
```

### 2. Provision AWS infrastructure

```bash
cd terraform

# Staging
terraform init -backend-config=envs/staging/backend.hcl
terraform apply -var-file=envs/staging/terraform.tfvars

# Production
terraform init -backend-config=envs/prod/backend.hcl
terraform apply -var-file=envs/prod/terraform.tfvars
```

### 3. Deploy to Kubernetes manually

```bash
# Set image tag
export IMAGE_TAG=abc1234

# Staging
cd k8s/overlays/staging
kustomize edit set image 123456789.dkr.ecr.ap-south-1.amazonaws.com/user-service:$IMAGE_TAG
kubectl apply -k .

# Production (after staging validation)
cd k8s/overlays/prod
kustomize edit set image 123456789.dkr.ecr.ap-south-1.amazonaws.com/user-service:$IMAGE_TAG
kubectl apply -k .
```

### 4. Trigger Jenkins pipeline

Push to the `main` branch — the GitHub webhook triggers the pipeline automatically. For manual runs, go to **Jenkins → user-service → Build with Parameters** and select the target environment.

---

## Environment Configuration

| Variable | Staging | Production |
|----------|---------|------------|
| Replicas | 1 | 3 |
| Instance type | t3.medium | t3.large |
| Log level | DEBUG | WARN |
| CPU request | 100m | 500m |
| Memory request | 128Mi | 512Mi |
| Feature flags | enabled | disabled |
| Rate limit (RPM) | 100 | 1000 |

---

## Author

**Samreen Fatima** — DevOps Engineering, KMIT  
AWS Certified · Docker · Kubernetes · Jenkins · Terraform
