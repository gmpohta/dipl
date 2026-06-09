# ============================================
# СЕТЕВЫЕ РЕСУРСЫ
# ============================================

resource "yandex_vpc_network" "iot_network" {
  name = "iot-network"
}

resource "yandex_vpc_subnet" "db_subnet_a" {
  name           = "db-subnet-a"
  zone           = var.zone
  network_id     = yandex_vpc_network.iot_network.id
  v4_cidr_blocks = ["10.0.1.0/24"]
}

resource "yandex_vpc_subnet" "vm_subnet_a" {
  name           = "vm-subnet-a"
  zone           = var.zone
  network_id     = yandex_vpc_network.iot_network.id
  v4_cidr_blocks = ["10.0.10.0/24"]
}

# ============================================
# КЛАСТЕР POSTGRESQL
# ============================================

resource "yandex_mdb_postgresql_cluster" "db_cluster" {
  name            = "${var.database_name}-cluster"
  environment     = var.db_environment
  network_id      = yandex_vpc_network.iot_network.id

  database {
    name  = var.database_name
    owner = var.db_user_name
  }

  user {
    name     = var.db_user_name
    password = var.db_user_password
    permission {
      database_name = var.database_name
    }
  }

  host {
    zone       = var.zone
    subnet_id  = yandex_vpc_subnet.db_subnet_a.id
    assign_public_ip = var.db_assign_public_ip
  }

  config {
    version = var.postgresql_version
    
    postgresql_config = {
      max_connections          = "100"
      shared_buffers           = 2097152      # 2 GB → 2 097 152 KB
      work_mem                 = 65536        # 64 MB → 65 536 KB
      maintenance_work_mem     = 1048576      # 1 GB → 1 048 576 KB
      effective_cache_size     = 6291456      # 6 GB → 6 291 456 KB
    }
    
    resources {
      resource_preset_id = var.db_resource_preset
      disk_size          = var.db_disk_size
      disk_type_id       = var.db_disk_type
    }
  }
}

# ============================================
# ХРАНИЛИЩЕ S3
# ============================================

resource "yandex_storage_bucket" "data_bucket" {
  bucket     = var.bucket_name
  folder_id  = var.yc_folder_id
  
  # Используем grant вместо deprecated acl
  grant {
    id          = yandex_iam_service_account.function_sa.id
    type        = "CanonicalUser"
    permissions = ["FULL_CONTROL"]
  }
}

# ============================================
# СЕРВИСНЫЕ АККАУНТЫ
# ============================================

# Сервисный аккаунт для Cloud Function
resource "yandex_iam_service_account" "function_sa" {
  name        = "function-service-account"
  description = "Service account for Cloud Function"
}

# Сервисный аккаунт для API Gateway
resource "yandex_iam_service_account" "api_gateway_sa" {
  name        = "api-gateway-sa"
  description = "Service account for API Gateway"
}

# Сервисный аккаунт для машины с MOSQUITTO (MQTT)
resource "yandex_iam_service_account" "vm_sa" {
  name        = "vm-sa"
  description = "Service account for MQTT VM"
}

# ============================================
# СТАТИЧЕСКИЕ КЛЮЧИ ДОСТУПА
# ============================================

resource "yandex_iam_service_account_static_access_key" "function_keys" {
  service_account_id = yandex_iam_service_account.function_sa.id
}

# ============================================
# НАЗНАЧЕНИЕ ПРАВ (IAM ROLES)
# ============================================

# Права для основной функции на доступ к S3
resource "yandex_resourcemanager_folder_iam_member" "sa_storage_access" {
  folder_id = var.yc_folder_id
  role      = "storage.editor"
  member    = "serviceAccount:${yandex_iam_service_account.function_sa.id}"
}

# Права для API Gateway на вызов функции
resource "yandex_resourcemanager_folder_iam_member" "api_gateway_function_invoker" {
  folder_id = var.yc_folder_id
  role      = "functions.functionInvoker"
  member    = "serviceAccount:${yandex_iam_service_account.api_gateway_sa.id}"
}

# Права для триггера на вызов функции
resource "yandex_resourcemanager_folder_iam_member" "function_invoker" {
  folder_id = var.yc_folder_id
  role      = "functions.functionInvoker"
  member    = "serviceAccount:${yandex_iam_service_account.function_sa.id}"
}

# Дополнительные права для функции на вызов самой себя
resource "yandex_resourcemanager_folder_iam_member" "function_self_invoke" {
  folder_id = var.yc_folder_id
  role      = "functions.functionInvoker"
  member    = "serviceAccount:${yandex_iam_service_account.function_sa.id}"
}

# ============================================
# ГРУППА БЕЗОПАСНОСТИ ДЛЯ MQTT
# ============================================

resource "yandex_vpc_security_group" "mqtt_sg" {
  name       = "mqtt-security-group"
  network_id = yandex_vpc_network.iot_network.id

  # Входящий трафик на MQTT
  ingress {
    description    = "MQTT Standard Port"
    protocol       = "TCP"
    port           = 1883
    v4_cidr_blocks = ["0.0.0.0/0"] # Лучше ограничить IP клиентов в продакшене
  }

  # Входящий трафик на MQTT WebSocket
  ingress {
    description    = "MQTT WebSocket"
    protocol       = "TCP"
    port           = 9001
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH доступ (рекомендуется только с вашего IP)
  ingress {
    description    = "SSH"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"] # Замените на ваш IP: "x.x.x.x/32"
  }

  # Исходящий трафик разрешен весь
  egress {
    description    = "Allow all outbound"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# ============================================
# СОЗДАНИЕ ZIP АРХИВОВ ДЛЯ ФУНКЦИЙ
# ============================================

# Создаем zip архив из папки functions (основная функция)
data "archive_file" "functions_zip" {
  type        = "zip"
  source_dir  = "${path.module}/functions"
  output_path = "${path.module}/functions.zip"
}

# Создаем zip архив для MQTT эмулятора
data "archive_file" "mqtt_emulator_zip" {
  type        = "zip"
  source_dir  = "${path.module}/mqtt_emulator"
  output_path = "${path.module}/mqtt_emulator.zip"
}

# ============================================
# ОСНОВНАЯ ФУНКЦИЯ ОБРАБОТКИ ДАННЫХ
# ============================================

resource "yandex_function" "data_processor" {
  name = var.function_name

  runtime            = "python311"
  entrypoint         = "index.handler"
  memory             = "128"
  execution_timeout  = "60"
  user_hash          = data.archive_file.functions_zip.output_base64sha256
  service_account_id = yandex_iam_service_account.function_sa.id

  content {
    zip_filename = data.archive_file.functions_zip.output_path
  }

  environment = {
    BUCKET_NAME                  = var.bucket_name
    DB_HOST                      = yandex_mdb_postgresql_cluster.db_cluster.host[0].fqdn
    DB_PORT                      = var.db_port
    DB_NAME                      = var.database_name
    DB_USER                      = var.db_user_name
    DB_PASSWORD                  = var.db_user_password
    STORAGE_ENDPOINT             = var.storage_endpoint
    AVERAGING_INTERVAL_MINUTES   = var.averaging_interval_minutes
    AWS_ACCESS_KEY_ID            = yandex_iam_service_account_static_access_key.function_keys.access_key
    AWS_SECRET_ACCESS_KEY        = yandex_iam_service_account_static_access_key.function_keys.secret_key
  }
}

# Функция эмулятора MQTT
resource "yandex_function" "mqtt_emulator" {
  name = "mqtt-emulator"

  runtime            = "python311"
  entrypoint         = "mqtt_emulator.handler"
  memory             = "128"
  execution_timeout  = "120"
  user_hash          = data.archive_file.mqtt_emulator_zip.output_base64sha256
  service_account_id = yandex_iam_service_account.function_sa.id

  content {
    zip_filename = data.archive_file.mqtt_emulator_zip.output_path
  }

  environment = {
    MQTT_HOST     = yandex_compute_instance.mqtt_broker.network_interface[0].nat_ip_address
    MQTT_PORT     = "1883"
    MQTT_USERNAME = var.mqtt_username
    MQTT_PASSWORD = var.mqtt_password
  }
}

# ============================================
# API GATEWAY
# ============================================

resource "yandex_api_gateway" "api_gw" {
  name        = "data-ingestion-gateway"
  description = "API Gateway for data ingestion"
  
  spec = templatefile("${path.module}/api-spec.yaml.tpl", {
    function_id        = yandex_function.data_processor.id
    service_account_id = yandex_iam_service_account.api_gateway_sa.id
  })
  
  depends_on = [
    yandex_function.data_processor,
    yandex_resourcemanager_folder_iam_member.api_gateway_function_invoker
  ]
}

# ============================================
# ТРИГГЕР ПО РАСПИСАНИЮ
# ============================================

resource "yandex_function_trigger" "timer_trigger" {
  name = "five-minute-averaging"

  timer {
    cron_expression = "*/5 * ? * *"
  }

  function {
    id                 = yandex_function.data_processor.id
    service_account_id = yandex_iam_service_account.function_sa.id
  }
}

# Триггер для автоматической эмуляции
resource "yandex_function_trigger" "mqtt_emulation_trigger" {
  count = var.enable_auto_emulation ? 1 : 0
  
  name = "mqtt-emulation-trigger"

  timer {
    cron_expression = "*/2 * * * ? *"  # Каждые 2 минуты
    payload = jsonencode({
      devices     = var.emulation_devices
      count       = 5
      interval    = 0.5
      value_range = [0, 100]
      pattern     = var.emulation_pattern
    })
  }

  function {
    id                 = yandex_function.mqtt_emulator.id
    service_account_id = yandex_iam_service_account.function_sa.id
  }
}

# ============================================
# ПОЛУЧЕНИЕ АКТУАЛЬНОГО ОБРАЗА UBUNTU
# ============================================

data "yandex_compute_image" "ubuntu_image" {
  family = "ubuntu-2204-lts"
}

# ============================================
# ВИРТУАЛЬНАЯ МАШИНА ДЛЯ MOSQUITTO (MQTT)
# ============================================

resource "yandex_compute_instance" "mqtt_broker" {
  name        = "mosquitto-broker"
  platform_id = "standard-v2"
  zone        = var.zone

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_image.id
      size     = 20
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.vm_subnet_a.id
    nat       = true
    security_group_ids = [yandex_vpc_security_group.mqtt_sg.id]
  }

  metadata = {
    user-data = <<-EOF
      #cloud-config
      package_update: true
      package_upgrade: true
      
      packages:
        - mosquitto
        - mosquitto-clients
        - curl
        - jq
      
      write_files:
        - path: /opt/mosquitto-forwarder/forward.sh
          permissions: '0755'
          content: |
            #!/bin/bash
            
            TOPIC="$1"
            PAYLOAD="$2"
            
            # Формируем JSON для отправки в API Gateway
            # Добавляем топик в качестве device_id если он не указан в payload
            DATA=$(echo "$PAYLOAD" | jq -c --arg topic "$TOPIC" '{
                timestamp: (.timestamp // (now | strftime("%Y-%m-%dT%H:%M:%SZ"))),
                value: (.value // (. | tonumber? // .)),
                device_id: (.device_id // $topic)
            }' 2>/dev/null || echo "$PAYLOAD" | jq -c --arg topic "$TOPIC" '{
                timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
                value: (. | tonumber? // .),
                device_id: $topic
            }')
            
            # Отправляем в API Gateway
            RESPONSE=$(curl -s -X POST \
                -H "Content-Type: application/json" \
                -d "$DATA" \
                -w "\n%{http_code}" \
                "${api_gateway_url}/")
            
            HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
            BODY=$(echo "$RESPONSE" | head -n-1)
            
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Topic: $TOPIC - HTTP $HTTP_CODE - $BODY" >> /var/log/mosquitto-forwarder.log

        - path: /etc/mosquitto/conf.d/forwarder.conf
          content: |
            # Подписываемся на все топики и вызываем скрипт при получении сообщения
            topic # out /opt/mosquitto-forwarder/forward.sh
          permissions: '0644'

        - path: /etc/mosquitto/conf.d/default.conf
          content: |
            listener 1883 0.0.0.0
            allow_anonymous true
            
            # WebSocket для веб-клиентов
            listener 9001
            protocol websockets
            
            # Логирование
            log_dest file /var/log/mosquitto/mosquitto.log
            log_type all
            log_timestamp true
          permissions: '0644'

      runcmd:
        # Создаем директории и файлы
        - mkdir -p /opt/mosquitto-forwarder
        - touch /var/log/mosquitto-forwarder.log
        - chmod 644 /var/log/mosquitto-forwarder.log
        
        # Перезапускаем Mosquitto с новой конфигурацией
        - systemctl restart mosquitto
        
        # Проверяем статус
        - sleep 5
        - systemctl status mosquitto --no-pager
        
        - echo "Mosquitto MQTT Broker setup complete!"
    EOF
  }

  service_account_id = yandex_iam_service_account.vm_sa.id

  depends_on = [
    yandex_api_gateway.api_gw
  ]
}

# ============================================
# ВЫХОДНЫЕ ДАННЫЕ
# ============================================

output "db_host_fqdn" {
  value = yandex_mdb_postgresql_cluster.db_cluster.host[0].fqdn
}

output "function_id" {
  value = yandex_function.data_processor.id
}

output "api_gateway_domain" {
  value = yandex_api_gateway.api_gw.domain
}

output "bucket_name" {
  value = yandex_storage_bucket.data_bucket.bucket
}

output "mqtt_connection_info" {
  value = {
    host     = yandex_compute_instance.mqtt_broker.network_interface[0].nat_ip_address
    port     = 1883
    ws_port  = 9001
  }
}