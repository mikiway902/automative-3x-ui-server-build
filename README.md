# automative-3x-ui-server-build
Автоматизированный скрипт создания сервера 3x-ui

# Деплой setup_vpn.sh

## Требования

- Ubuntu 20.04+ / Debian 11+
- root-доступ (или sudo)
- Открытые порты 80 и 443 на файрволле хостинг-провайдера
- Домен, направленный на IP сервера
- Исходящий доступ в интернет

## Варианты деплоя

### 1. Ручной — scp + ssh (рекомендуется)

```bash
# Локально: копируем скрипт на сервер
scp setup_vpn.sh root@<ip-сервера>:/root/

# Заходим на сервер
ssh root@<ip-сервера>

# Запускаем
chmod +x /root/setup_vpn.sh
./root/setup_vpn.sh
```

Скрипт сам запросит IP, домен и email.

### 2. Через wget/curl из репозитория

```bash
ssh root@<ip-сервера>

# Скачать
wget -O setup_vpn.sh <https://github.com/mikiway902/automative-3x-ui-server-build/setup_vpn.sh> 2>/dev/null || \
  curl -o setup_vpn.sh <https://github.com/mikiway902/automative-3x-ui-server-build/setup_vpn.sh>

# Запустить
chmod +x setup_vpn.sh
./setup_vpn.sh
```

`curl | bash` не подходит — скрипт интерактивный.

### 3. Полностью неинтерактивно (для автоматизации)

Пробросить ответы через пайп:

```bash
printf '%s\n' \
  "<ip-сервера>" \
  "<domain.com>" \
  "<email@example.com>" \
  | ./setup_vpn.sh
```

### 4. Через Ansible

**inventory.ini:**
```ini
[vpn]
<ip-сервера> ansible_user=root
```

**deploy-vpn.yml:**
```yaml
- name: Deploy VPN server
  hosts: vpn
  vars:
    vpn_ip: "<ip-сервера>"
    vpn_domain: "<domain.com>"
    vpn_email: "<email@example.com>"
  tasks:
    - name: Copy setup script
      copy:
        src: setup_vpn.sh
        dest: /root/setup_vpn.sh
        mode: 0755

    - name: Run setup script
      command: |
        printf '%s\n' "{{ vpn_ip }}" "{{ vpn_domain }}" "{{ vpn_email }}" |
        /root/setup_vpn.sh
      args:
        creates: /usr/local/x-ui/x-ui
```

```bash
ansible-playbook -i inventory.ini deploy-vpn.yml
```

### 5. Cloud-init / User-data (VPS)

При создании сервера у провайдера (DigitalOcean, Vultr, Hetzner и т.д.) вставьте в user-data:

```yaml
#cloud-config
runcmd:
  - wget -O /root/setup_vpn.sh <https://github.com/mikiway902/automative-3x-ui-server-build/setup_vpn.sh>
  - chmod +x /root/setup_vpn.sh
  - printf '%s\n' "<ip-сервера>" "<domain.com>" "<email@example.com>" | /root/setup_vpn.sh
```

**Важно:** предварительно замените `<ip-сервера>`, `<domain.com>` и `<email@example.com>` на реальные значения. Публичный IP обычно известен только после создания сервера, поэтому этот способ подходит если IP статический и известен заранее.

### 6. Packer (образ VM)

```hcl
variable "vpn_ip"    { type = string }
variable "vpn_domain" { type = string }
variable "vpn_email"  { type = string }

source "ansible" "vpn" {
  playbook_file = "deploy-vpn.yml"
  extra_arguments = [
    "--extra-vars", "vpn_ip=${var.vpn_ip} vpn_domain=${var.vpn_domain} vpn_email=${var.vpn_email}"
  ]
}
```

## После установки

1. Сохраните выведенные логин, пароль и Access URL
2. Откройте `https://<домен>:2222/<webBasePath>` в браузере
3. Создайте inbounds (входящие подключения) в панели 3X-UI

## Известные ограничения

- Скрипт рассчитан на чистый сервер. На уже настроенной системе возможны конфликты (nginx, порт 80/443)
- Let's Encrypt требует реального домена — для установки по IP используйте option 4 (Skip SSL) в 3x-ui и настройте cerbot вручную
