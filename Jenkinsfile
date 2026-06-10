// ============================================================
// Jenkins Declarative Pipeline — user-service
// Stages: Checkout → Build → Test → Docker Build/Push →
//         Deploy Staging → Smoke Test → Deploy Prod (manual gate)
// ============================================================
pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: maven
    image: maven:3.9.5-eclipse-temurin-17
    command: ['cat']
    tty: true
    volumeMounts:
    - name: maven-cache
      mountPath: /root/.m2
  - name: docker
    image: docker:24-dind
    securityContext:
      privileged: true
    volumeMounts:
    - name: docker-socket
      mountPath: /var/run/docker.sock
  - name: kubectl
    image: bitnami/kubectl:1.28
    command: ['cat']
    tty: true
  volumes:
  - name: maven-cache
    persistentVolumeClaim:
      claimName: maven-cache-pvc
  - name: docker-socket
    hostPath:
      path: /var/run/docker.sock
"""
        }
    }

    // ── Parameters ──────────────────────────────────────────
    parameters {
        choice(name: 'DEPLOY_ENV', choices: ['staging', 'prod', 'both'],
               description: 'Target deployment environment')
        booleanParam(name: 'SKIP_TESTS', defaultValue: false,
                     description: 'Skip unit tests (emergency hotfix only)')
    }

    // ── Environment variables ────────────────────────────────
    environment {
        APP_NAME        = 'user-service'
        ECR_REGISTRY    = '123456789.dkr.ecr.ap-south-1.amazonaws.com'
        ECR_REPO        = "${ECR_REGISTRY}/${APP_NAME}"
        IMAGE_TAG       = "${env.GIT_COMMIT[0..7]}"  // short SHA
        AWS_REGION      = 'ap-south-1'
        AWS_CREDENTIALS = credentials('aws-ecr-credentials')
        SONAR_TOKEN     = credentials('sonarqube-token')
        SLACK_WEBHOOK   = credentials('slack-webhook-url')
    }

    // ── Options ─────────────────────────────────────────────
    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 45, unit: 'MINUTES')
        timestamps()
        disableConcurrentBuilds()
    }

    // ── Triggers ─────────────────────────────────────────────
    triggers {
        githubPush()
    }

    // ══════════════════════════════════════════════════════
    // S T A G E S
    // ══════════════════════════════════════════════════════
    stages {

        // ── 1. Checkout ──────────────────────────────────────
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.GIT_AUTHOR = sh(returnStdout: true,
                        script: 'git log -1 --format="%an"').trim()
                    echo "Branch: ${env.BRANCH_NAME} | Commit: ${env.GIT_COMMIT[0..7]} | Author: ${env.GIT_AUTHOR}"
                }
            }
        }

        // ── 2. Build & Unit Test ─────────────────────────────
        stage('Build & Test') {
            steps {
                container('maven') {
                    dir('app') {
                        sh """
                            mvn clean verify \
                                -B \
                                -Dmaven.test.skip=${params.SKIP_TESTS} \
                                -Dspring.profiles.active=test
                        """
                    }
                }
            }
            post {
                always {
                    junit 'app/target/surefire-reports/*.xml'
                    publishHTML([
                        reportDir: 'app/target/site/jacoco',
                        reportFiles: 'index.html',
                        reportName: 'Code Coverage'
                    ])
                }
            }
        }

        // ── 3. SonarQube Analysis ────────────────────────────
        stage('SonarQube Analysis') {
            when { branch 'main' }
            steps {
                container('maven') {
                    withSonarQubeEnv('SonarQube') {
                        dir('app') {
                            sh """
                                mvn sonar:sonar \
                                    -Dsonar.projectKey=${APP_NAME} \
                                    -Dsonar.token=${SONAR_TOKEN}
                            """
                        }
                    }
                }
                timeout(time: 5, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        // ── 4. Docker Build & Push to ECR ────────────────────
        stage('Docker Build & Push') {
            steps {
                container('docker') {
                    sh """
                        # Authenticate to ECR
                        aws ecr get-login-password --region ${AWS_REGION} \
                            | docker login --username AWS --password-stdin ${ECR_REGISTRY}

                        # Build multi-stage image
                        docker build \
                            -f docker/Dockerfile \
                            -t ${ECR_REPO}:${IMAGE_TAG} \
                            -t ${ECR_REPO}:latest \
                            .

                        # Push both tags
                        docker push ${ECR_REPO}:${IMAGE_TAG}
                        docker push ${ECR_REPO}:latest
                    """
                }
            }
        }

        // ── 5. Deploy to Staging ─────────────────────────────
        stage('Deploy to Staging') {
            when {
                anyOf {
                    expression { params.DEPLOY_ENV == 'staging' }
                    expression { params.DEPLOY_ENV == 'both' }
                }
            }
            steps {
                container('kubectl') {
                    withCredentials([file(credentialsId: 'kubeconfig-staging',
                                         variable: 'KUBECONFIG')]) {
                        sh """
                            cd k8s/overlays/staging
                            kustomize edit set image ${ECR_REPO}:${IMAGE_TAG}
                            kubectl apply -k . --kubeconfig=${KUBECONFIG}
                            kubectl rollout status deployment/${APP_NAME} \
                                -n user-service-staging \
                                --timeout=5m \
                                --kubeconfig=${KUBECONFIG}
                        """
                    }
                }
            }
        }

        // ── 6. Smoke Test Staging ────────────────────────────
        stage('Smoke Test Staging') {
            when {
                anyOf {
                    expression { params.DEPLOY_ENV == 'staging' }
                    expression { params.DEPLOY_ENV == 'both' }
                }
            }
            steps {
                sh """
                    sleep 15
                    HEALTH=\$(curl -s -o /dev/null -w "%{http_code}" \
                        https://staging.userservice.internal/actuator/health)
                    if [ "\$HEALTH" != "200" ]; then
                        echo "Smoke test FAILED — HTTP \$HEALTH"
                        exit 1
                    fi
                    echo "Smoke test PASSED"
                """
            }
        }

        // ── 7. Manual Gate before Prod ───────────────────────
        stage('Approval for Production') {
            when {
                anyOf {
                    expression { params.DEPLOY_ENV == 'prod' }
                    expression { params.DEPLOY_ENV == 'both' }
                }
            }
            steps {
                input(
                    message: "Deploy ${IMAGE_TAG} to PRODUCTION?",
                    ok: 'Approve',
                    submitter: 'devops-leads,release-managers'
                )
            }
        }

        // ── 8. Deploy to Production ──────────────────────────
        stage('Deploy to Production') {
            when {
                anyOf {
                    expression { params.DEPLOY_ENV == 'prod' }
                    expression { params.DEPLOY_ENV == 'both' }
                }
            }
            steps {
                container('kubectl') {
                    withCredentials([file(credentialsId: 'kubeconfig-prod',
                                         variable: 'KUBECONFIG')]) {
                        sh """
                            cd k8s/overlays/prod
                            kustomize edit set image ${ECR_REPO}:${IMAGE_TAG}
                            kubectl apply -k . --kubeconfig=${KUBECONFIG}
                            kubectl rollout status deployment/${APP_NAME} \
                                -n user-service-prod \
                                --timeout=10m \
                                --kubeconfig=${KUBECONFIG}
                        """
                    }
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════
    // P O S T
    // ══════════════════════════════════════════════════════
    post {
        success {
            slackSend(
                channel: '#deployments',
                color: 'good',
                message: ":white_check_mark: *${APP_NAME}* `${IMAGE_TAG}` deployed to *${params.DEPLOY_ENV}* by ${env.GIT_AUTHOR}"
            )
        }
        failure {
            slackSend(
                channel: '#deployments',
                color: 'danger',
                message: ":x: *${APP_NAME}* pipeline failed on branch `${env.BRANCH_NAME}` — <${env.BUILD_URL}|View Build>"
            )
        }
        always {
            cleanWs()
        }
    }
}
