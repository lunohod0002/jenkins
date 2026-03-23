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
    IMAGE_NAME = 'registry-proxy/lab/app'
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
            # Отключаем echo команд в логе,
            # чтобы случайно не светить секреты.
            set +x

            # Создаём каталог, где будут лежать TLS-файлы
            # для подключения Docker CLI к remote-docker.
            mkdir -p .docker-tls

            # Логинимся в Vault через AppRole.
            # --cacert указывает доверенный сертификат Vault,
            # который примонтирован в контейнер Jenkins.
            LOGIN_JSON=$(curl --silent \
              --cacert /var/jenkins_home/vault-ca/vault.crt \
              --request POST \
              --data "{\"role_id\":\"$VAULT_ROLE_ID\",\"secret_id\":\"$VAULT_SECRET_ID\"}" \
              "$VAULT_ADDR/v1/auth/approle/login")

            # Достаём временный Vault token из JSON-ответа.
            VAULT_TOKEN=$(echo "$LOGIN_JSON" | jq -r .auth.client_token)

            # Читаем из Vault секрет writer для Docker Registry.
            # По политике Jenkins имеет доступ только к этому пути.
            curl --silent \
              --cacert /var/jenkins_home/vault-ca/vault.crt \
              -H "X-Vault-Token: $VAULT_TOKEN" \
              "$VAULT_ADDR/v1/kv/data/ci/registry/writer" > writer.json

            # Извлекаем логин пользователя registry.
            export REGISTRY_USER=$(jq -r '.data.data.username' writer.json)

            # Извлекаем пароль пользователя registry.
            export REGISTRY_PASS=$(jq -r '.data.data.password' writer.json)

            # Запрашиваем у Vault короткоживущий клиентский сертификат
            # для подключения к Docker daemon по mTLS.
            curl --silent \
              --cacert /var/jenkins_home/vault-ca/vault.crt \
              -H "X-Vault-Token: $VAULT_TOKEN" \
              --request POST \
              --data '{"common_name":"jenkins-client","ttl":"1h"}' \
              "$VAULT_ADDR/v1/pki/issue/docker-client" > cert.json

            # Сохраняем приватный ключ клиентского сертификата.
            jq -r '.data.private_key' cert.json > .docker-tls/key.pem

            # Сохраняем сам клиентский сертификат.
            jq -r '.data.certificate' cert.json > .docker-tls/cert.pem

            # Читаем CA-сертификат из Vault.
            # Он нужен Docker CLI, чтобы проверять серверный сертификат remote-docker.
            curl --silent \
              --cacert /var/jenkins_home/vault-ca/vault.crt \
              "$VAULT_ADDR/v1/pki/cert/ca" | jq -r '.data.certificate' > .docker-tls/ca.pem

            # Ограничиваем права на приватный ключ.
            chmod 600 .docker-tls/key.pem

            # Говорим Docker CLI, где лежат cert.pem / key.pem / ca.pem.
            export DOCKER_CERT_PATH="$WORKSPACE/.docker-tls"

            # Проверяем, что подключение к remote-docker по TLS работает.
            # Если mTLS или доверие к CA настроены неправильно, pipeline упадёт здесь.
            echo "=== cert.json ==="
            cat cert.json
            echo
            echo "=== key.pem head ==="
            head -5 .docker-tls/key.pem
            echo
            ls -l .docker-tls
            docker version

            # Логинимся в приватный registry как writer.
            # Пароль передаём через stdin, а не в аргументах команды.
            echo "$REGISTRY_PASS" | docker login registry-proxy \
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