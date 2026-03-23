pipeline {
  // Запускать pipeline можно на любом доступном agent'е Jenkins.
  agent any

  environment {
    // Адрес Vault внутри docker-compose сети.
    VAULT_ADDR = 'https://vault:8200'

    // Удалённый Docker daemon, к которому Jenkins будет подключаться по TLS.
    DOCKER_HOST = 'tcp://remote-docker:2376'

    // Включаем TLS-проверку для Docker CLI.
    DOCKER_TLS_VERIFY = '1'

    // Имя образа в приватном registry.
    IMAGE_NAME = 'registry-proxy:443/lab/app'
  }

  stages {

    stage('Checkout') {
      steps {
        // Забираем исходный код из SCM, который привязан к job.
        checkout scm
      }
    }

    stage('Login to Vault and fetch secrets') {
      steps {
        // Берём из Jenkins Credentials только AppRole-пару:
        // role_id и secret_id.
        // Они должны быть заранее добавлены как Secret text.
        withCredentials([
          string(credentialsId: 'vault-role-id', variable: 'VAULT_ROLE_ID'),
          string(credentialsId: 'vault-secret-id', variable: 'VAULT_SECRET_ID')
        ]) {

          // Выполняем shell-скрипт.
          sh '''
          mkdir -p .docker-tls
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
            "$VAULT_ADDR/v1/kv/data/ci/registry/writer" > writer.json

          jq -e '.data.data.username and .data.data.password' writer.json >/dev/null || {
            echo "Failed to read writer credentials from Vault"
            cat writer.json
            exit 1
          }

          export REGISTRY_USER=$(jq -r '.data.data.username' writer.json)
          export REGISTRY_PASS=$(jq -r '.data.data.password' writer.json)

          curl --silent --show-error --fail \
            --cacert /var/jenkins_home/vault-ca/vault.crt \
            -H "X-Vault-Token: $VAULT_TOKEN" \
            -H "Content-Type: application/json" \
            --request POST \
            --data '{"common_name":"jenkins-client","ttl":"1h"}' \
            "$VAULT_ADDR/v1/pki/issue/docker-client" > cert.json
          TLS_DIR="$WORKSPACE/.docker-tls"
          mkdir -p "$TLS_DIR"
          jq -e '.data.private_key and .data.certificate' cert.json >/dev/null || {
            echo "Failed to issue docker client certificate"
            cat cert.json
            exit 1
          }

          jq -r '.data.private_key' cert.json > .docker-tls/key.pem
          jq -r '.data.certificate' cert.json > .docker-tls/cert.pem

          curl --silent --show-error --fail \
            --cacert /var/jenkins_home/vault-ca/vault.crt \
            -H "X-Vault-Token: $VAULT_TOKEN" \
            "$VAULT_ADDR/v1/pki/cert/ca" | jq -r '.data.certificate' > .docker-tls/ca.pem

          chmod 600 .docker-tls/key.pem
          export DOCKER_CERT_PATH="$WORKSPACE/.docker-tls"

          docker version

            # Логинимся в приватный registry как writer.
            # Пароль передаём через stdin, а не в аргументах команды.
            echo "$REGISTRY_PASS" | docker login registry-proxy:443 \
              --username "$REGISTRY_USER" \
              --password-stdin
          '''
        }
      }
    }

    stage('Build with cache') {
      steps {
        sh '''
          # Не печатаем лишнее в лог.
          set +x

          # Повторно указываем путь к TLS-файлам,
          # потому что каждый sh-блок — это отдельная shell-сессия.
          export DOCKER_CERT_PATH="$WORKSPACE/.docker-tls"

          # Пытаемся скачать последний образ, чтобы использовать его как cache source.
          # Если образа ещё нет, не падаем.
          docker pull ${IMAGE_NAME}:latest || true

          # Собираем образ:
          # --cache-from использует слои из latest,
          # BUILD_NUMBER даёт уникальный тег текущей сборки,
          # latest обновляется на свежую версию.
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
          # Не печатаем команды с возможными чувствительными данными.
          set +x

          # Снова задаём путь к TLS-файлам для Docker CLI.
          export DOCKER_CERT_PATH="$WORKSPACE/.docker-tls"

          # Публикуем версию, привязанную к номеру сборки.
          docker push ${IMAGE_NAME}:${BUILD_NUMBER}

          # Обновляем тег latest.
          docker push ${IMAGE_NAME}:latest
        '''
      }
    }

    stage('Smoke test') {
      steps {
        sh '''
          # Не печатаем лишнее в лог.
          set +x

          # Docker CLI снова должен знать, где лежат клиентские TLS-файлы.
          export DOCKER_CERT_PATH="$WORKSPACE/.docker-tls"

          # Минимальная проверка:
          # контейнер из только что собранного образа должен стартовать и завершиться без ошибки.
          docker run --rm ${IMAGE_NAME}:${BUILD_NUMBER} true
        '''
      }
    }
  }

  post {
    always {
      // После завершения сборки удаляем временные секреты и сертификаты из workspace.
      // || true нужен, чтобы cleanup не падал, если файлов уже нет.
      sh 'rm -rf .docker-tls cert.json writer.json || true'
    }
  }
}