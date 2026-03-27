pipeline {
  agent any

  environment {
    // Vault внутри docker-compose сети
    VAULT_ADDR = 'https://vault:8200'

    // Удалённый Docker daemon по mTLS
    DOCKER_HOST = 'tcp://remote-docker:2376'
    DOCKER_TLS_VERIFY = '1'

    // Адрес registry, в который логинится Docker CLI.
    // Для docker_auth логин выполняется именно сюда,
    // а не в auth-сервис напрямую.
    REGISTRY_HOST = 'registry-proxy:443'

    // Имя образа в registry
    IMAGE_NAME = 'registry-proxy:443/lab/app'

    // Путь к writer credentials в Vault
    REGISTRY_SECRET_PATH = 'kv/data/ci/registry/writer'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Login to Vault and prepare Docker auth') {
      steps {
        withCredentials([
          string(credentialsId: 'vault-role-id', variable: 'VAULT_ROLE_ID'),
          string(credentialsId: 'vault-secret-id', variable: 'VAULT_SECRET_ID')
        ]) {
          sh '''
            set +x

            TLS_DIR="$WORKSPACE/.docker-tls"
            DOCKER_CFG_DIR="$WORKSPACE/.docker"

            mkdir -p "$TLS_DIR" "$DOCKER_CFG_DIR"

            ROLE_ID_CLEAN=$(printf %s "$VAULT_ROLE_ID" | tr -d '\\r\\n')
            SECRET_ID_CLEAN=$(printf %s "$VAULT_SECRET_ID" | tr -d '\\r\\n')

            LOGIN_PAYLOAD=$(jq -cn \
              --arg role_id "$ROLE_ID_CLEAN" \
              --arg secret_id "$SECRET_ID_CLEAN" \
              '{role_id:$role_id, secret_id:$secret_id}')

            LOGIN_JSON=$(curl --silent --show-error --fail \
              --cacert /var/jenkins_home/vault-ca/vault.crt \
              -H "Content-Type: application/json" \
              --request POST \
              --data "$LOGIN_PAYLOAD" \
              "$VAULT_ADDR/v1/auth/approle/login")

            VAULT_TOKEN=$(echo "$LOGIN_JSON" | jq -r '.auth.client_token // empty')

            if [ -z "$VAULT_TOKEN" ]; then
              echo "Vault AppRole login failed"
              echo "$LOGIN_JSON"
              exit 1
            fi

            curl --silent --show-error --fail \
              --cacert /var/jenkins_home/vault-ca/vault.crt \
              -H "X-Vault-Token: $VAULT_TOKEN" \
              "$VAULT_ADDR/v1/$REGISTRY_SECRET_PATH" > writer.json

            jq -e '.data.data.username and .data.data.password' writer.json >/dev/null || {
              echo "Failed to read writer credentials from Vault"
              cat writer.json
              exit 1
            }

            REGISTRY_USER=$(jq -r '.data.data.username' writer.json)
            REGISTRY_PASS=$(jq -r '.data.data.password' writer.json)

            curl --silent --show-error --fail \
              --cacert /var/jenkins_home/vault-ca/vault.crt \
              -H "X-Vault-Token: $VAULT_TOKEN" \
              -H "Content-Type: application/json" \
              --request POST \
              --data '{"common_name":"jenkins-client","ttl":"1h"}' \
              "$VAULT_ADDR/v1/pki/issue/docker-client" > cert.json

            jq -e '.data.private_key and .data.certificate' cert.json >/dev/null || {
              echo "Failed to issue docker client certificate"
              cat cert.json
              exit 1
            }

            jq -r '.data.private_key' cert.json > "$TLS_DIR/key.pem"
            jq -r '.data.certificate' cert.json > "$TLS_DIR/cert.pem"

            curl --silent --show-error --fail \
              --cacert /var/jenkins_home/vault-ca/vault.crt \
              -H "X-Vault-Token: $VAULT_TOKEN" \
              "$VAULT_ADDR/v1/pki/cert/ca" | jq -r '.data.certificate' > "$TLS_DIR/ca.pem"

            chmod 600 "$TLS_DIR/key.pem"

            export DOCKER_CERT_PATH="$TLS_DIR"
            export DOCKER_CONFIG="$DOCKER_CFG_DIR"

            docker version

            # Для docker_auth логинимся в registry.
            # Токен у auth-сервиса Docker получит автоматически.
            printf '%s' "$REGISTRY_PASS" | docker login "$REGISTRY_HOST" \
              --username "$REGISTRY_USER" \
              --password-stdin

            unset REGISTRY_PASS
            unset VAULT_TOKEN
          '''
        }
      }
    }

    stage('Build with cache') {
      steps {
        sh '''
          set +x
          export DOCKER_CERT_PATH="$WORKSPACE/.docker-tls"
          export DOCKER_CONFIG="$WORKSPACE/.docker"

          docker pull ${IMAGE_NAME}:latest || true

          docker build \
            --cache-from ${IMAGE_NAME}:latest \
            -t ${IMAGE_NAME}:${BUILD_NUMBER} \
            -t ${IMAGE_NAME}:latest \
            .
        '''
      }
    }

    stage('Push') {
      steps {
        sh '''
          set +x
          export DOCKER_CERT_PATH="$WORKSPACE/.docker-tls"
          export DOCKER_CONFIG="$WORKSPACE/.docker"

          docker push ${IMAGE_NAME}:${BUILD_NUMBER}
          docker push ${IMAGE_NAME}:latest
        '''
      }
    }

    stage('Smoke test') {
      steps {
        sh '''
          set +x
          export DOCKER_CERT_PATH="$WORKSPACE/.docker-tls"
          export DOCKER_CONFIG="$WORKSPACE/.docker"

          docker run --rm ${IMAGE_NAME}:${BUILD_NUMBER}
        '''
      }
    }
  }

  post {
    always {
      sh '''
        rm -rf .docker-tls .docker cert.json writer.json || true
      '''
    }
  }
}