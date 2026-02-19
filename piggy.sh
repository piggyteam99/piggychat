#!/bin/bash

# توقف اسکریپت در صورت بروز خطا
set -e

# رنگ‌ها برای نمایش پیام‌ها
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# چک کردن دسترسی روت
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}لطفاً اسکریپت را با دسترسی root اجرا کنید (sudo).${NC}"
  exit
fi

# تابع نمایش منو
show_menu() {
    clear
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}      Matrix (Synapse) Management Script             ${NC}"
    echo -e "${GREEN}======================================================${NC}"
    echo -e "1) ${YELLOW}نصب کامل (Synapse + Element + Coturn + SSL)${NC}"
    echo -e "2) ${YELLOW}فعال‌سازی توکن ثبت‌نام (Registration Token)${NC}"
    echo -e "3) ${RED}حذف کامل تمامی سرویس‌های نصب شده${NC}"
    echo -e "4) خروج"
    echo -ne "\nلطفاً یک گزینه را انتخاب کنید: "
    read opt
}

# --- بخش اول: تابع نصب کامل ---
install_matrix() {
    echo -e "${YELLOW}مرحله 1: دریافت اطلاعات دامنه و سرور${NC}"
    read -p "لطفاً دامنه اصلی را وارد کنید (مثلاً example.com): " DOMAIN_ROOT
    read -p "لطفاً ساب‌دامین چت را وارد کنید (مثلاً chat.$DOMAIN_ROOT): " DOMAIN_CHAT
    read -p "لطفاً ساب‌دامین المنت را وارد کنید (مثلاً app.$DOMAIN_ROOT): " DOMAIN_APP
    read -p "آدرس IP پابلیک سرور را وارد کنید: " SERVER_IP
    read -p "ایمیل خود را برای دریافت گواهی SSL وارد کنید: " EMAIL_ADDR

    echo ""
    echo -e "اطلاعات وارد شده:"
    echo -e "Root Domain: ${GREEN}$DOMAIN_ROOT${NC}"
    echo -e "Chat Domain: ${GREEN}$DOMAIN_CHAT${NC}"
    echo -e "App Domain:  ${GREEN}$DOMAIN_APP${NC}"
    echo -e "Server IP:   ${GREEN}$SERVER_IP${NC}"
    echo -e "Email:       ${GREEN}$EMAIL_ADDR${NC}"
    echo ""

    read -p "آیا اطلاعات بالا صحیح است؟ (y/n): " CONFIRM
    if [[ $CONFIRM != "y" ]]; then
        echo -e "${RED}نصب لغو شد.${NC}"
        return
    fi

    echo -e "${YELLOW}\nمرحله 2: آپدیت سیستم و نصب پیش‌نیازها...${NC}"
    apt update
    apt install -y curl wget gnupg lsb-release nginx certbot python3-certbot-nginx coturn sqlite3

    echo -e "${YELLOW}\nمرحله 3: نصب Synapse...${NC}"
    wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/matrix-org.list
    apt update
    apt install -y matrix-synapse-py3

    echo -e "${YELLOW}\nمرحله 4: تنظیم Registration Shared Secret...${NC}"
    REG_SECRET=$(openssl rand -hex 32)
    cat <<EOF > /etc/matrix-synapse/conf.d/registration.yaml
enable_registration: true
enable_registration_without_verification: true
registration_shared_secret: "$REG_SECRET"
EOF

    echo -e "${YELLOW}\nمرحله 5: راه‌اندازی سرویس و ساخت یوزر ادمین...${NC}"
    systemctl restart matrix-synapse
    echo -e "${GREEN}اکنون باید یک یوزر ادمین بسازید.${NC}"
    register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008

    echo -e "${YELLOW}\nمرحله 6: دریافت گواهی SSL...${NC}"
    systemctl stop nginx
    certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL_ADDR" -d "$DOMAIN_CHAT" -d "$DOMAIN_APP" -d "$DOMAIN_ROOT"
    systemctl start nginx

    # --- تنظیم Nginx برای Matrix ---
    cat <<EOF > /etc/nginx/sites-available/matrix.conf
server {
    listen 80;
    server_name $DOMAIN_CHAT;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $DOMAIN_CHAT;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_CHAT/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_CHAT/privkey.pem;
    client_max_body_size 5000M;
    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/matrix.conf /etc/nginx/sites-enabled/matrix.conf

    # --- نصب Element Web ---
    cd /var/www
    REDIRECT_URL=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/vector-im/element-web/releases/latest)
    VERSION=$(basename "$REDIRECT_URL")
    wget "https://github.com/vector-im/element-web/releases/download/$VERSION/element-$VERSION.tar.gz" -O element-latest.tar.gz
    tar -xvf element-latest.tar.gz > /dev/null
    rm -rf element && mv "element-$VERSION" element
    rm element-latest.tar.gz

    cat <<EOF > /var/www/element/config.json
{
  "default_server_config": {
    "m.homeserver": { "base_url": "https://$DOMAIN_CHAT", "server_name": "$DOMAIN_ROOT" }
  },
  "disable_custom_urls": false,
  "disable_guests": true,
  "brand": "Element"
}
EOF

    # --- تنظیم Nginx برای Element ---
    cat <<EOF > /etc/nginx/sites-available/element.conf
server {
    listen 80;
    server_name $DOMAIN_APP;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $DOMAIN_APP;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_CHAT/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_CHAT/privkey.pem;
    root /var/www/element;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
    ln -sf /etc/nginx/sites-available/element.conf /etc/nginx/sites-enabled/element.conf

    # --- تنظیم Well-known ---
    cat <<EOF > /etc/nginx/sites-available/matrix-wellknown.conf
server {
    listen 80;
    server_name $DOMAIN_ROOT;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $DOMAIN_ROOT;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_CHAT/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_CHAT/privkey.pem;
    location = /.well-known/matrix/client {
        add_header Content-Type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.homeserver":{"base_url":"https://$DOMAIN_CHAT"}}';
    }
    location = /.well-known/matrix/server {
        add_header Content-Type application/json;
        return 200 '{"m.server":"$DOMAIN_CHAT:443"}';
    }
}
EOF
    ln -sf /etc/nginx/sites-available/matrix-wellknown.conf /etc/nginx/sites-enabled/matrix-wellknown.conf
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx

    # --- تنظیم Coturn (با SSL برای تماس) ---
    echo -e "${YELLOW}\nمرحله 11: تنظیم و فعال‌سازی TURN با SSL...${NC}"
    TURN_SECRET=$(openssl rand -hex 32)
    cat <<EOF > /etc/turnserver.conf
syslog
listening-port=3478
tls-listening-port=5349
listening-ip=0.0.0.0
external-ip=$SERVER_IP
realm=$DOMAIN_CHAT
server-name=$DOMAIN_CHAT
fingerprint
cert=/etc/letsencrypt/live/$DOMAIN_CHAT/fullchain.pem
pkey=/etc/letsencrypt/live/$DOMAIN_CHAT/privkey.pem
use-auth-secret
static-auth-secret=$TURN_SECRET
min-port=49160
max-port=49200
verbose
EOF
    sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/g' /etc/default/coturn
    systemctl restart coturn

    # معرفی به Synapse
    cat <<EOF > /etc/matrix-synapse/conf.d/turn.yaml
turn_uris:
  - "turn:$DOMAIN_CHAT:3478?transport=udp"
  - "turn:$DOMAIN_CHAT:3478?transport=tcp"
  - "turns:$DOMAIN_CHAT:5349?transport=udp"
  - "turns:$DOMAIN_CHAT:5349?transport=tcp"
turn_shared_secret: "$TURN_SECRET"
turn_user_lifetime: 86400000
turn_allow_guests: false
EOF
    systemctl restart matrix-synapse
    echo -e "${GREEN}نصب با موفقیت به پایان رسید!${NC}"
}

# --- بخش دوم: فعال‌سازی توکن ---
enable_token() {
    echo -e "${RED}⚠️ هشدار: با فعال‌سازی توکن، ثبت‌نام عمومی در اپلیکیشن (بدون توکن) با خطا مواجه خواهد شد.${NC}"
    read -p "آیا از ادامه مطمئن هستید؟ (y/n): " CONFIRM_TOKEN
    if [[ $CONFIRM_TOKEN != "y" ]]; then return; fi

    read -p "لطفاً توکن مورد نظر خود را وارد کنید (مثلاً piggy): " USER_TOKEN
    
    echo -e "${YELLOW}>>> در حال اصلاح فایل کانفیگ...${NC}"
    REG_SECRET=$(openssl rand -hex 32)
    cat <<EOF > /etc/matrix-synapse/conf.d/registration.yaml
enable_registration: true
registration_requires_token: true
registration_shared_secret: "$REG_SECRET"
EOF

    systemctl restart matrix-synapse
    echo -e "${YELLOW}>>> در حال اضافه کردن توکن به دیتابیس...${NC}"
    sleep 3
    
    python3 -c "
import sqlite3
import os
db_path = '/var/lib/matrix-synapse/homeserver.db'
if os.path.exists(db_path):
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute(\"DELETE FROM registration_tokens WHERE token='$USER_TOKEN'\")
    cur.execute(\"INSERT INTO registration_tokens (token, uses_allowed, pending, completed) VALUES ('$USER_TOKEN', NULL, 0, 0)\")
    con.commit()
    con.close()
    print('✅ توکن با موفقیت فعال شد.')
else:
    print('❌ دیتابیس پیدا نشد!')
"
}

# --- بخش سوم: حذف کامل ---
full_uninstall() {
    echo -e "${RED}❌ هشدار: تمام داده‌ها، دیتابیس‌ها و تنظیمات حذف خواهند شد!${NC}"
    read -p "آیا مطمئن هستید؟ (y/n): " UN_CONFIRM
    if [[ $UN_CONFIRM != "y" ]]; then return; fi

    systemctl stop matrix-synapse coturn nginx
    apt purge -y matrix-synapse-py3 coturn nginx certbot python3-certbot-nginx
    apt autoremove -y
    rm -rf /etc/matrix-synapse /var/lib/matrix-synapse /etc/turnserver.conf /var/www/element /etc/nginx/sites-enabled/matrix* /etc/nginx/sites-available/matrix*
    echo -e "${GREEN}تمام سرویس‌ها با موفقیت حذف شدند.${NC}"
}

# اجرای منوی اصلی
while true; do
    show_menu
    case $opt in
        1) install_matrix ;;
        2) enable_token ;;
        3) full_uninstall ;;
        4) exit 0 ;;
        *) echo -e "${RED}گزینه نامعتبر!${NC}" ; sleep 2 ;;
    esac
    echo -e "\nبرای بازگشت به منو اینتر بزنید..."
    read
done
