#!/bin/bash

# Скрипт автоматической установки VLESS VPN на CentOS 9
# Требует запуска от root

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Переменные
DOMAIN=""
EMAIL=""
UUID=$(cat /proc/sys/kernel/random/uuid)
CONFIG_FILE="/usr/local/etc/xray/config.json"
SERVICE_FILE="/etc/systemd/system/xray.service"

# Функции для вывода
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
}

# Проверка ОС
check_os() {
    if [[ ! -f /etc/centos-release ]]; then
        print_error "Этот скрипт предназначен только для CentOS"
        exit 1
    fi
    
    source /etc/os-release
    if [[ $VERSION_ID != "9" ]]; then
        print_warning "Скрипт тестировался на CentOS 9, но запущен на $VERSION_ID"
    fi
}

# Ввод данных
get_user_input() {
    read -p "Введите ваш домен (example.com): " DOMAIN
    read -p "Введите ваш email (для сертификатов): " EMAIL
    
    if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
        print_error "Домен и email обязательны для работы"
        exit 1
    fi
}

# Обновление системы
update_system() {
    print_info "Обновление системы..."
    dnf update -y
    dnf install -y curl wget sudo
}

# Установка зависимостей
install_dependencies() {
    print_info "Установка зависимостей..."
    dnf install -y epel-release
    dnf install -y socat cronie certbot
    systemctl enable crond
    systemctl start crond
}

# Настройка firewall
setup_firewall() {
    print_info "Настройка firewall..."
    
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --permanent --add-port=8443/tcp
        firewall-cmd --reload
    else
        print_warning "firewalld не найден, проверьте настройки iptables/nftables вручную"
    fi
}

# Установка Xray
install_xray() {
    print_info "Установка Xray..."
    
    # Скачивание и установка Xray
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    # Создание директории для конфигурации
    mkdir -p /usr/local/etc/xray/
}

# Получение SSL сертификата
get_ssl_certificate() {
    print_info "Получение SSL сертификата от Let's Encrypt..."
    
    # Остановка служб на 80 порту для получения сертификата
    systemctl stop xray 2>/dev/null || true
    
    # Получение сертификата
    certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"
    
    # Создание симлинков для сертификатов Xray
    mkdir -p /usr/local/etc/xray/ssl
    ln -sf /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem /usr/local/etc/xray/ssl/server.crt
    ln -sf /etc/letsencrypt/live/"$DOMAIN"/privkey.pem /usr/local/etc/xray/ssl/server.key
}

# Создание конфигурации Xray
create_xray_config() {
    print_info "Создание конфигурации Xray..."
    
    cat > $CONFIG_FILE << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": []
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/usr/local/etc/xray/ssl/server.crt",
              "keyFile": "/usr/local/etc/xray/ssl/server.key"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "listen": "0.0.0.0",
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vless"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
}

# Создание systemd службы
create_systemd_service() {
    print_info "Создание systemd службы..."
    
    if [[ ! -f $SERVICE_FILE ]]; then
        cat > $SERVICE_FILE << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    fi
}

# Настройка автоматического обновления сертификатов
setup_cert_renewal() {
    print_info "Настройка автоматического обновления сертификатов..."
    
    # Создание скрипта для обновления сертификатов
    cat > /usr/local/bin/renew-xray-cert.sh << EOF
#!/bin/bash
certbot renew --quiet
systemctl restart xray
EOF
    
    chmod +x /usr/local/bin/renew-xray-cert.sh
    
    # Добавление в cron
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/renew-xray-cert.sh") | crontab -
}

# Запуск служб
start_services() {
    print_info "Запуск служб..."
    
    systemctl daemon-reload
    systemctl enable xray
    systemctl start xray
    
    # Проверка статуса
    if systemctl is-active --quiet xray; then
        print_info "Xray успешно запущен"
    else
        print_error "Ошибка запуска Xray"
        journalctl -u xray -n 10
        exit 1
    fi
}

# Показать конфигурацию
show_config() {
    print_info "Настройка завершена!"
    echo "==================================================="
    echo "Домен: $DOMAIN"
    echo "UUID: $UUID"
    echo "Порт: 443 (VLESS + TCP + TLS)"
    echo "Порт: 8443 (VLESS + WS)"
    echo "Flow: xtls-rprx-vision"
    echo "==================================================="
    echo ""
    echo "Конфигурация для клиента (рекомендуемый):"
    cat << EOF
{
  "v": "2",
  "ps": "VLESS-TLS-$DOMAIN",
  "add": "$DOMAIN",
  "port": "443",
  "id": "$UUID",
  "aid": "0",
  "scy": "none",
  "net": "tcp",
  "type": "none",
  "host": "",
  "path": "",
  "tls": "tls",
  "sni": "$DOMAIN",
  "flow": "xtls-rprx-vision",
  "alpn": ""
}
EOF
    echo ""
    echo "Ссылка для импорта:"
    CONFIG_LINK="vless://$UUID@$DOMAIN:443?security=tls&flow=xtls-rprx-vision&type=tcp#VLESS-TLS-$DOMAIN"
    echo "$CONFIG_LINK"
    echo ""
    print_warning "Сохраните эту информацию в безопасном месте!"
}

# Основная функция
main() {
    clear
    echo "==================================================="
    echo "    Автоматическая установка VLESS VPN на CentOS 9"
    echo "==================================================="
    echo ""
    
    check_root
    check_os
    get_user_input
    update_system
    install_dependencies
    setup_firewall
    install_xray
    get_ssl_certificate
    create_xray_config
    create_systemd_service
    setup_cert_renewal
    start_services
    show_config
    
    print_info "Установка завершена успешно!"
}

# Запуск основной функции
main "$@"