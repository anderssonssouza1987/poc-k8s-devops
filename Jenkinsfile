pipeline {
  agent any

  environment {
    REGISTRY   = 'localhost:5001'
    IMAGE      = 'localhost:5001/poc-k8s/app'
    TAG        = "${env.BUILD_NUMBER}"
    SONAR_HOST = 'http://sonarqube:9000'
    PROJECT    = 'poc-k8s-app'
    KUBECONFIG = '/root/.kube/config'
    HOST_WS    = "/srv/jenkins/workspace/${env.JOB_NAME}"
  }

  stages {
    stage('Testes') {
      steps {
        sh '''
          docker run --rm -v "$HOST_WS":/src -w /src python:3.12-slim \
            sh -c "test -f app/requirements-dev.txt && pip install -q -r app/requirements-dev.txt && cd app && python -m pytest -q"
        '''
      }
    }

    stage('SonarQube') {
      steps {
        withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
          sh '''
            docker run --rm --network kind -v "$HOST_WS":/usr/src -w /usr/src \
              -e SONAR_HOST_URL=$SONAR_HOST \
              -e SONAR_TOKEN=$SONAR_TOKEN \
              sonarsource/sonar-scanner-cli \
              -Dsonar.projectKey=$PROJECT \
              -Dsonar.projectName=$PROJECT \
              -Dsonar.sources=app \
              -Dsonar.python.version=3.12
          '''
        }
      }
    }

    stage('Quality Gate') {
      steps {
        withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
          sh '''
            for i in $(seq 1 30); do
              STATUS=$(curl -s -u "$SONAR_TOKEN:" \
                "$SONAR_HOST/api/qualitygates/project_status?projectKey=$PROJECT" \
                | grep -o '"status":"[A-Z]*"' | head -1 | cut -d'"' -f4)
              echo "quality gate: ${STATUS:-aguardando}"
              [ "$STATUS" = "OK" ] && exit 0
              [ "$STATUS" = "ERROR" ] && exit 1
              sleep 5
            done
            echo "timeout aguardando quality gate"
            exit 1
          '''
        }
      }
    }

    stage('Build') {
      steps {
        sh 'docker build -t $IMAGE:$TAG -t $IMAGE:latest .'
      }
    }

    stage('Trivy') {
      steps {
        sh '''
          docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
            aquasec/trivy:latest image \
            --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
            $IMAGE:$TAG
        '''
      }
    }

    stage('Push') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'nexus-docker',
                          usernameVariable: 'NEXUS_USER',
                          passwordVariable: 'NEXUS_PASS')]) {
          sh '''
            echo "$NEXUS_PASS" | docker login $REGISTRY -u "$NEXUS_USER" --password-stdin
            docker push $IMAGE:$TAG
            docker push $IMAGE:latest
          '''
        }
      }
    }

    stage('Deploy') {
      steps {
        sh '''
          helm upgrade --install poc chart --namespace poc \
            --set image.tag=$TAG --wait --timeout 3m
          kubectl -n poc rollout status deploy/poc-poc-k8s-app --timeout=120s
        '''
      }
    }
  }

  post {
    always { cleanWs() }
  }
}
