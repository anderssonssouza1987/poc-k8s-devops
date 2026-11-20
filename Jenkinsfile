pipeline {
  agent any

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '10'))
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  environment {
    REGISTRY              = 'nexus:5001'
    REGISTRY_PUSH         = 'localhost:5001'
    IMAGE_NAME            = 'poc-k8s-app'
    IMAGE_TAG             = "${BUILD_NUMBER}"
    NAMESPACE             = 'poc-k8s'
    RELEASE_NAME          = 'poc-k8s-app'
    CHART_DIR             = 'chart'
    SONAR_HOST            = 'http://sonarqube:9000'
    SONAR_PROJECT         = 'poc-k8s-app'
    SCANNER_IMAGE         = 'sonarsource/sonar-scanner-cli:12.4.0.4321_8.4.0'
    TRIVY_IMAGE           = 'aquasec/trivy@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb'
    TRIVY_EXIT_CODE       = '1'
    QG_REQUIRE_CONDITIONS = 'true'
    KUBECONFIG            = '/root/.kube/config'
  }

  stages {

    stage('Checkout') {
      steps {
        script {
          env.GIT_SHA    = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
          env.GIT_BRANCH = sh(returnStdout: true, script: 'git rev-parse --abbrev-ref HEAD').trim()

          env.WS      = env.WORKSPACE
          env.HOST_WS = env.WORKSPACE.replace('/var/jenkins_home', '/srv/jenkins')
          if (env.HOST_WS.contains('/var/jenkins_home')) {
            error "HOST_WS nao foi traduzido para o caminho do host: ${env.HOST_WS}"
          }

          echo "commit ${env.GIT_SHA} no branch ${env.GIT_BRANCH}"
          echo "workspace container: ${env.WS}"
          echo "workspace host:      ${env.HOST_WS}"
        }
      }
    }

    stage('Testes') {
      steps {
        sh '''
          set -eu
          docker run --rm \
            -v "${HOST_WS}:/usr/src" -w /usr/src \
            python:3.12-slim sh -c '
              pip install -q -r app/requirements-dev.txt pytest-cov &&
              cd app &&
              python -m pytest -q \
                --cov=. \
                --cov-report=xml:coverage.xml \
                --cov-report=term-missing \
                --junitxml=test-results.xml
            '
          ls -l "${WS}/app/test-results.xml" "${WS}/app/coverage.xml"
          grep -o "<source>[^<]*</source>" "${WS}/app/coverage.xml" || true
          test -s "${WS}/app/test-results.xml" || { echo "ERRO: test-results.xml nao gerado"; exit 1; }
          test -s "${WS}/app/coverage.xml"    || { echo "ERRO: coverage.xml nao gerado";    exit 1; }
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
                -Dsonar.exclusions=app/tests/**,**/__pycache__/**,**/*.pyc,app/coverage.xml,app/test-results.xml \
                -Dsonar.python.version=3.12 \
                -Dsonar.python.coverage.reportPaths=app/coverage.xml \
                -Dsonar.python.xunit.reportPath=app/test-results.xml \
                -Dsonar.python.xunit.skipDetails=true
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
              COND_COUNT=$(printf '%s' "$RESP" | grep -o '"metricKey"' | wc -l)
              echo "tentativa ${i}: status=${STATUS:-sem-resposta} condicoes=${COND_COUNT}"
              if [ "$STATUS" = "OK" ]; then
                if [ "$COND_COUNT" -eq 0 ]; then
                  echo "AVISO: gate aprovado sem nenhuma condicao avaliada (OK vazio)"
                  if [ "${QG_REQUIRE_CONDITIONS}" = "true" ]; then
                    echo "ERRO: QG_REQUIRE_CONDITIONS=true e o gate nao tem condicoes"
                    exit 1
                  fi
                fi
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
            PUSH_IMAGE="${REGISTRY_PUSH}/${IMAGE_NAME}:${IMAGE_TAG}"
            test -f "${WS}/Dockerfile" || { echo "ERRO: Dockerfile nao encontrado na raiz do repo"; exit 1; }
            AUTH=$(printf '%s:%s' "$NEXUS_USER" "$NEXUS_PASS" | base64 -w0)
            mkdir -p /root/.docker
            printf '{"auths":{"%s":{"auth":"%s"},"%s":{"auth":"%s"}}}' \
              "$REGISTRY_PUSH" "$AUTH" "$REGISTRY" "$AUTH" > /root/.docker/config.json
            docker build \
              -f "${WS}/Dockerfile" \
              --label "org.opencontainers.image.revision=${GIT_SHA}" \
              --label "org.opencontainers.image.version=${IMAGE_TAG}" \
              -t "$PUSH_IMAGE" \
              "${WS}"
            docker push "$PUSH_IMAGE"
            docker logout "$REGISTRY_PUSH" || true
          '''
        }
      }
    }

    stage('Trivy') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'nexus-docker',
                                          usernameVariable: 'NEXUS_USER',
                                          passwordVariable: 'NEXUS_PASS')]) {
        sh '''
          set -eu
          IMAGE="${REGISTRY_PUSH}/${IMAGE_NAME}:${IMAGE_TAG}"
          docker run --rm --network kind \
            -e TRIVY_USERNAME="$NEXUS_USER" \
            -e TRIVY_PASSWORD="$NEXUS_PASS" \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v "${HOST_WS}:/work" -w /work \
            "${TRIVY_IMAGE}" image \
              --severity HIGH,CRITICAL \
              --ignore-unfixed \
              --ignorefile /work/.trivyignore \
              --image-src docker \
              --timeout 10m \
              --format table \
              --output trivy-report.txt \
              --exit-code "${TRIVY_EXIT_CODE}" \
              "$IMAGE"
          echo "--- resumo do trivy ---"
          sed -n '1,40p' trivy-report.txt || true
        '''
        }
      }
      post {
        always {
          archiveArtifacts artifacts: 'trivy-report.txt', allowEmptyArchive: true
        }
      }
    }

    stage('Politica') {
      steps {
        sh '''
          set -eu
          kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
          kubectl apply -f policies/disallow-latest-tag.yaml
          for i in $(seq 1 24); do
            kubectl -n "${NAMESPACE}" run policy-probe --image=nginx:latest \
              --dry-run=server -o yaml >/tmp/probe.out 2>/tmp/probe.err || true
            if grep -q 'disallow-latest-tag' /tmp/probe.err; then
              echo "ok: :latest negado pelo admission"
              sed -n '1,6p' /tmp/probe.err
              kubectl -n "${NAMESPACE}" run policy-probe-ok --image=nginx:1.27.3 \
                --dry-run=server -o yaml >/dev/null
              echo "ok: tag imutavel aceita"
              exit 0
            fi
            if grep -q 'AlreadyExists' /tmp/probe.err; then
              echo "ERRO: probe colidiu com pod existente"
              exit 1
            fi
            echo "tentativa ${i}: politica ainda nao bloqueou"
            sleep 5
          done
          echo "ERRO: politica nao bloqueou :latest em 120s"
          exit 1
        '''
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

            test -f "${CHART_DIR}/Chart.yaml" || { echo "ERRO: ${CHART_DIR}/Chart.yaml nao encontrado"; exit 1; }

            helm lint "${CHART_DIR}" \
              --set image.repository="${REGISTRY}/${IMAGE_NAME}" \
              --set image.tag="${IMAGE_TAG}"

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
              --set imagePullSecrets[0].name=nexus-regcred \
              > /tmp/rendered.yaml

            echo "--- manifesto renderizado (${RELEASE_NAME}) ---"
            grep -E '^(kind|  name):' /tmp/rendered.yaml | head -40

            helm upgrade --install "${RELEASE_NAME}" "${CHART_DIR}" \
              --namespace "${NAMESPACE}" \
              --set image.repository="${REGISTRY}/${IMAGE_NAME}" \
              --set image.tag="${IMAGE_TAG}" \
              --set imagePullSecrets[0].name=nexus-regcred \
              --wait --timeout 3m --atomic

            kubectl -n "${NAMESPACE}" rollout status "deploy/${RELEASE_NAME}" --timeout=180s
            kubectl -n "${NAMESPACE}" get pods,svc,ingress,hpa -o wide
          '''
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'app/coverage.xml, app/test-results.xml, trivy-report.txt',
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
