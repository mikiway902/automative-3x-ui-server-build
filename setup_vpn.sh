#!/bin/bash
sed -i 's/\r$//' "$0" 2>/dev/null
set -e

VPN_IP=""
VPN_DOMAIN=""
VPN_EMAIL=""

PANEL_PORT="2222"
PANEL_USER=""
PANEL_PASS=""
PANEL_WEB_BASE_PATH=""
PANEL_ACCESS_URL=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error_exit() {
    echo "[ОШИБКА] $*" >&2
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "Скрипт должен запускаться от root"
    fi
}

gen_creds() {
    PANEL_USER="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)"
    PANEL_PASS="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)"
}

prompt_vars() {
    read -rp "Введите IP сервера: " VPN_IP
    while [[ -z "$VPN_IP" ]]; do
        read -rp "IP не может быть пустым. Введите IP сервера: " VPN_IP
    done

    read -rp "Введите домен (например, vpn.example.com): " VPN_DOMAIN
    while [[ -z "$VPN_DOMAIN" ]]; do
        read -rp "Домен не может быть пустым. Введите домен: " VPN_DOMAIN
    done

    read -rp "Введите email для Let's Encrypt: " VPN_EMAIL
    while [[ -z "$VPN_EMAIL" ]]; do
        read -rp "Email не может быть пустым. Введите email: " VPN_EMAIL
    done
}

# ===== 1. ОБНОВЛЕНИЕ И БАЗОВАЯ НАСТРОЙКА =====
setup_base() {
    log "Обновление пакетов..."
    DEBIAN_FRONTEND=noninteractive apt update && DEBIAN_FRONTEND=noninteractive apt upgrade -y

    if ! command -v ufw &>/dev/null; then
        log "Установка UFW..."
        DEBIAN_FRONTEND=noninteractive apt install ufw -y
    fi

    log "Настройка UFW..."
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow OpenSSH
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 443/udp
    ufw allow 8443/tcp
    ufw allow 8443/udp
    ufw allow 10000:60000/tcp
    ufw allow 10000:60000/udp

    echo "y" | ufw enable
    log "UFW включён и настроен"
}

# ===== 2. НАСТРОЙКА FAIL2BAN =====
setup_fail2ban() {
    log "Установка fail2ban..."
    DEBIAN_FRONTEND=noninteractive apt install fail2ban -y

    cat << 'EOF' > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
banaction = ufw

[sshd]
enabled = true
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    log "Fail2ban настроен и запущен"
}

# ===== 3. ВЫПУСК SSL СЕРТИФИКАТА =====
setup_ssl() {
    log "Установка snapd и certbot..."
    DEBIAN_FRONTEND=noninteractive apt install snapd -y
    snap install --classic certbot
    ln -sf /snap/bin/certbot /usr/local/bin/certbot

    log "Выпуск SSL-сертификата для $VPN_DOMAIN..."
    certbot certonly --standalone -d "$VPN_DOMAIN" --non-interactive --agree-tos -m "$VPN_EMAIL"
    log "SSL-сертификат получен"
}

# ===== 4. УСТАНОВКА И НАСТРОЙКА NGINX =====
setup_nginx() {
    log "Установка Nginx..."
    DEBIAN_FRONTEND=noninteractive apt install nginx -y

    mkdir -p "/var/www/$VPN_DOMAIN/html"
    chown -R "$SUDO_USER:$SUDO_USER" "/var/www/$VPN_DOMAIN" 2>/dev/null || chown -R root:root "/var/www/$VPN_DOMAIN"

    cat > "/var/www/$VPN_DOMAIN/html/index.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$VPN_DOMAIN</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; background: #f5f5f5; }
        h1 { color: #333; }
    </style>
</head>
<body>
    <h1>$VPN_DOMAIN</h1>
    <p>Server is running</p>
</body>
</html>
EOF

    cat > "/etc/nginx/sites-available/$VPN_DOMAIN" << EOF
server {
    listen 80;
    server_name $VPN_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $VPN_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$VPN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$VPN_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /var/www/$VPN_DOMAIN/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    ln -sf "/etc/nginx/sites-available/$VPN_DOMAIN" /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default

    nginx -t || error_exit "Ошибка конфигурации Nginx"
    systemctl restart nginx
    log "Nginx настроен и запущен"

    log "Перенастройка certbot на webroot..."
    if [[ -f "/etc/letsencrypt/renewal/$VPN_DOMAIN.conf" ]]; then
        sed -i "s|^authenticator = .*|authenticator = webroot|" "/etc/letsencrypt/renewal/$VPN_DOMAIN.conf" || true
        if grep -q "^webroot_path" "/etc/letsencrypt/renewal/$VPN_DOMAIN.conf"; then
            sed -i "s|^webroot_path = .*|webroot_path = /var/www/$VPN_DOMAIN/html|" "/etc/letsencrypt/renewal/$VPN_DOMAIN.conf" || true
        else
            sed -i "/^authenticator = webroot/a webroot_path = /var/www/$VPN_DOMAIN/html" "/etc/letsencrypt/renewal/$VPN_DOMAIN.conf" || true
        fi
        if grep -q "^deploy_hook" "/etc/letsencrypt/renewal/$VPN_DOMAIN.conf"; then
            sed -i "s|^deploy_hook = .*|deploy_hook = systemctl reload nginx|" "/etc/letsencrypt/renewal/$VPN_DOMAIN.conf" || true
        else
            echo "deploy_hook = systemctl reload nginx" >> "/etc/letsencrypt/renewal/$VPN_DOMAIN.conf" || true
        fi
    fi
}

# ===== 5. УСТАНОВКА 3X-UI ПАНЕЛИ =====
setup_3xui() {
    log "Установка 3X-UI панели..."

    local cert_full="/etc/letsencrypt/live/$VPN_DOMAIN/fullchain.pem"
    local cert_key="/etc/letsencrypt/live/$VPN_DOMAIN/privkey.pem"

    local ssl_opt="3"
    if [[ ! -f "$cert_full" || ! -f "$cert_key" ]]; then
        log "Сертификаты не найдены, пропускаем SSL в 3X-UI"
        ssl_opt="4"
    fi

    local tmpfile
    tmpfile=$(mktemp /tmp/3xui_XXXXXX)

    printf '%s\n' \
        "" \
        "y" \
        "$PANEL_PORT" \
        "$ssl_opt" \
        "$VPN_DOMAIN" \
        "$cert_full" \
        "$cert_key" \
        | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) 2>&1 | tee "$tmpfile" || true

    local parsed_user parsed_pass parsed_port parsed_wbp parsed_url
    local clean
    clean=$(sed 's/\x1b\[[0-9;]*m//g' "$tmpfile")
    parsed_user=$(echo "$clean" | sed -n 's/^Username:[[:space:]]*//p' | tr -d '[:space:]')
    parsed_pass=$(echo "$clean" | sed -n 's/^Password:[[:space:]]*//p' | tr -d '[:space:]')
    parsed_port=$(echo "$clean" | sed -n 's/^Port:[[:space:]]*//p' | tr -d '[:space:]')
    parsed_wbp=$(echo "$clean" | sed -n 's/^WebBasePath:[[:space:]]*//p' | tr -d '[:space:]')
    parsed_url=$(echo "$clean" | sed -n 's/^Access URL:[[:space:]]*//p' | tr -d '[:space:]')

    rm -f "$tmpfile"

    [[ -n "$parsed_user" ]] && PANEL_USER="$parsed_user"
    [[ -n "$parsed_pass" ]] && PANEL_PASS="$parsed_pass"
    [[ -n "$parsed_port" ]] && PANEL_PORT="$parsed_port"
    [[ -n "$parsed_wbp" ]] && PANEL_WEB_BASE_PATH="$parsed_wbp"
    [[ -n "$parsed_url" ]] && PANEL_ACCESS_URL="$parsed_url"

    ufw allow "${PANEL_PORT}/tcp"
    log "3X-UI панель установлена на порту $PANEL_PORT"
}

# ===== ФИНАЛЬНЫЙ ВЫВОД =====
print_summary() {
    echo ""
    echo "=============================================="
    echo "      УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО"
    echo "=============================================="
    echo "IP сервера:   $VPN_IP"
    echo "Домен:        $VPN_DOMAIN"
    echo ""
    echo "--- Панель 3X-UI ---"
    echo "Access URL:   $PANEL_ACCESS_URL"
    echo "Логин:        $PANEL_USER"
    echo "Пароль:       $PANEL_PASS"
    echo "Порт:         $PANEL_PORT"
    echo "WebBasePath:  $PANEL_WEB_BASE_PATH"
    echo ""
    echo "ВАЖНО: Зайдите в панель 3X-UI и создайте подключения."
    echo "=============================================="
}

# ===== MAIN =====
check_root
prompt_vars
setup_base
gen_creds
setup_fail2ban
setup_ssl
setup_nginx
setup_3xui
print_summary
