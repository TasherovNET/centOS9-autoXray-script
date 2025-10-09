#!/bin/bash

# Скрипт управления VLESS VPN

case "$1" in
    start)
        systemctl start xray
        echo "VLESS сервис запущен"
        ;;
    stop)
        systemctl stop xray
        echo "VLESS сервис остановлен"
        ;;
    restart)
        systemctl restart xray
        echo "VLESS сервис перезапущен"
        ;;
    status)
        systemctl status xray
        ;;
    log)
        journalctl -u xray -f
        ;;
    config)
        echo "UUID: $(grep -oP '"id": "\K[^"]+' /usr/local/etc/xray/config.json | head -1)"
        echo "Домен: $(hostname -f)"
        ;;
    renew)
        certbot renew
        systemctl restart xray
        echo "Сертификаты обновлены"
        ;;
    *)
        echo "Использование: $0 {start|stop|restart|status|log|config|renew}"
        exit 1
        ;;
esac