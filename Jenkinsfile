pipeline {
  agent any

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '10'))
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  environment {
    REGISTRY      = 'localhost:5001'
    IMAGE_NAME    = 'poc-k8s-app'
    IMAGE_TAG     = "${BUILD_NUMBER}"
    NAMESPACE     = 'poc-k8s'
    RELEASE_NAME  = 'poc-k8s-app'
    CHART_DIR     = 'helm/poc-k8s-app'
    SONAR_HOST    = 'http://sonarqube:9000'
    SONAR_PROJECT = 'poc-k8s-app'
    SCANNER_IMAGE = 'sonarsource/sonar-scanner-cli:12.4.0.4321_8.4.0'
    KUBECONFIG    = '/root/.kube/config'
  }

  stages {

    stage('Checkout') {
      steps {
        script {
          env.GIT_SHA    = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
          env.GIT_BRANCH = sh(returnStdout: true, script: 'git rev-parse --abbrev-ref HEAD').trim()

          env.HOST_WS = env.WORKSPACE.replace('/var/jenkins_home', '/srv/jenkins')
          if (env.HOST_WS.contains('/var/jenkins_home')) {
            error "HOST_WS nao foi traduzido para o caminho do host: ${env.HOST_WS}"
          }

          echo "commit ${env.GIT_SHA} no branch ${env.GIT_BRANCH}"
          echo "workspace container: ${env.WORKSPACE}"
          echo "workspace host:      ${env.HOST_WS}"
        }
      }
    }

    stage('Testes') {
      steps {
        sh '''
          set -eu
          docker run --rm \
            -v "${HOST_WS}:/src" -w /src \
            python:3.12-slim sh -c '
              pip install -q -r app/requirements-dev.txt pytest-cov &&
              cd app &&
              python -m pytest -q \
                --cov=. \
                --cov-report=xml:coverage.xml \
                --cov-report=term-missing \
                --junitxml=test-results.xml
            '
          test -s "${HOST_WS}/app/test-results.xml" || { echo "ERRO: test-results.xml nao gerado"; exit 1; }
          test -s "${HOST_WS}/app/coverage.xml"    || { echo "ERRO: coverage.xml nao gerado";    exit 1; }
        '''
      }
      post {
        always {
          junit allowEmptyResults: true, testResults: 'app/test-results.xml'
        }
      }
    }

    stage('SonarQube') {
      steps {
        withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
          sh '''
            set -eu
            docker run --rm --network kind \
              -v "${HOST_WS}:/usr/src" -w /usr/src \
              -e SONAR_HOST_URL="${SONAR_HOST}" \
              -e SONAR_TOKEN="${SONAR_TOKEN}" \
              "${SCANNER_IMAGE}" \
                -Dsonar.projectKey="${SONAR_PROJECT}" \
                -Dsonar.projectName="${SONAR_PROJECT}" \
                -Dsonar.sources=app \
                -Dsonar.tests=app/tests \
                -Dsonar.exclusions=app/tests/**,**/__pycache__/**,**/*.pyc \
                -Dsonar.python.version=3.12 \
                -Dsonar.python.coverage.reportPaths=app/coverage.xml
          '''
        }
      }
    }

    stage('Quality Gate') {
      steps {
        withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
          sh '''
            set -eu
            for i in $(seq 1 40); do
              RESP=$(curl -s -u "${SONAR_TOKEN}:" \
                "${SONAR_HOST}/api/qualitygates/project_status?projectKey=${SONAR_PROJECT}")
              STATUS=$(printf '%s' "$RESP" | grep -o '"status":"[A-Z]*"' | head -1 | cut -d'"' -f4)
              echo "tentativa ${i}: status=${STATUS:-sem-resposta}"
              if [ "$STATUS" = "OK" ]; then
                echo "Quality Gate aprovado"
                exit 0
              fi
              if [ "$STATUS" = "ERROR" ]; then
                printf '%s' "$RESP" | grep -o '"metricKey":"[^"]*"' | cut -d'"' -f4 | sed 's/^/  condicao reprovada: /'
                echo "Quality Gate reprovado"
                exit 1
              fi
              sleep 5
            done
            echo "timeout aguardando o Quality Gate"
            exit 1
          '''
        }
      }
    }

    stage('Build') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'nexus-docker',
                                          usernameVariable: 'NEXUS_USER',
                                          passwordVariable: 'NEXUS_PASS')]) {
          sh '''
            set -eu
            IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
            echo "$NEXUS_PASS" | docker login "$REGISTRY" -u "$NEXUS_USER" --password-stdin
            docker build \
              --label "org.opencontainers.image.revision=${GIT_SHA}" \
              --label "org.opencontainers.image.version=${IMAGE_TAG}" \
              -t "$IMAGE" \
              -t "${REGISTRY}/${IMAGE_NAME}:latest" \
              "${HOST_WS}/app"
            docker push "$IMAGE"
            docker push "${REGISTRY}/${IMAGE_NAME}:latest"
            docker logout "$REGISTRY"
          '''
        }
      }
    }

    stage('Trivy') {
      steps {
        sh '''
          set -eu
          IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
          docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v "${HOST_WS}:/work" -w /work \
            aquasec/trivy:latest image \
              --severity HIGH,CRITICAL \
              --ignore-unfixed \
              --format table \
              --output trivy-report.txt \
              --exit-code 1 \
              "$IMAGE"
        '''
      }
      post {
        always {
          archiveArtifacts artifacts: 'trivy-report.txt', allowEmptyArchive: true
        }
      }
    }

    stage('Deploy') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'nexus-docker',
                                          usernameVariable: 'NEXUS_USER',
                                          passwordVariable: 'NEXUS_PASS')]) {
          sh '''
            set -eu
            IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

            kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

            kubectl -n "${NAMESPACE}" create secret docker-registry nexus-regcred \
              --docker-server="${REGISTRY}" \
              --docker-username="${NEXUS_USER}" \
              --docker-password="${NEXUS_PASS}" \
              --dry-run=client -o yaml | kubectl apply -f -

            helm template "${RELEASE_NAME}" "${CHART_DIR}" \
              --namespace "${NAMESPACE}" \
              --set image.repository="${REGISTRY}/${IMAGE_NAME}" \
              --set image.tag="${IMAGE_TAG}" \
              > /tmp/rendered.yaml

            echo "--- manifesto renderizado (${RELEASE_NAME}) ---"
            grep -E '^(kind|  name):' /tmp/rendered.yaml | head -40

            helm upgrade --install "${RELEASE_NAME}" "${CHART_DIR}" \
              --namespace "${NAMESPACE}" \
              --set image.repository="${REGISTRY}/${IMAGE_NAME}" \
              --set image.tag="${IMAGE_TAG}" \
              --set imagePullSecrets[0].name=nexus-regcred \
              --wait --timeout 5m

            kubectl -n "${NAMESPACE}" rollout status "deploy/${RELEASE_NAME}" --timeout=180s
            kubectl -n "${NAMESPACE}" get pods,svc,ingress,hpa -o wide
          '''
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'app/coverage.xml, app/test-results.xml',
                       allowEmptyArchive: true
      echo "build ${BUILD_NUMBER} finalizado com status ${currentBuild.currentResult}"
    }
    failure {
      sh '''
        kubectl -n "${NAMESPACE}" get pods -o wide || true
        kubectl -n "${NAMESPACE}" describe pods || true
        kubectl -n "${NAMESPACE}" logs -l app.kubernetes.io/name="${RELEASE_NAME}" --tail=80 || true
      '''
    }
  }
}
