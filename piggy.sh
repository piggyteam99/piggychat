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

clear
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}    Matrix (Synapse) + Element + Secure TURN (TLS)    ${NC}"
echo -e "${GREEN}    (Hardened Security Version - 2026)               ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo ""

# --- مرحله 1: دریافت اطلاعات ---
echo -e "${YELLOW}مرحله 1: دریافت تنظیمات دامنه و امنیت${NC}"

read -p "لطفاً دامنه اصلی را وارد کنید (مثلاً example.com): " DOMAIN_ROOT
read -p "لطفاً ساب‌دامین چت را وارد کنید (مثلاً chat.$DOMAIN_ROOT): " DOMAIN_CHAT
read -p "لطفاً ساب‌دامین المنت را وارد کنید (مثلاً app.$DOMAIN_ROOT): " DOMAIN_APP
read -p "آدرس IP پابلیک سرور را وارد کنید: " SERVER_IP
read -p "ایمیل برای SSL: " EMAIL_ADDR
read -p "توکن ثبت‌نام اختصاصی خود را وارد کنید: " USER_TOKEN

echo ""
read -p "اطلاعات صحیح است؟ (y/n): " CONFIRM
if [[ $CONFIRM != "y" ]]; then exit 1; fi

# --- مرحله 2: نصب پیش‌نیازها ---
echo -e "${YELLOW}\nمرحله 2: نصب پکیج‌های مورد نیاز...${NC}"
apt update
apt install -y curl wget gnupg lsb-release nginx certbot python3-certbot-nginx coturn sqlite3

# --- مرحله 3: نصب Synapse ---
echo -e "${YELLOW}\nمرحله 3: نصب Synapse...${NC}"
wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/matrix-org.list
apt update
apt install -y matrix-synapse-py3

# --- مرحله 4: تنظیم Registration ---
REG_SECRET=$(openssl rand -hex 32)
cat <<EOF > /etc/matrix-synapse/conf.d/registration.yaml
enable_registration: true
enable_registration_without_verification: true
registration_requires_token: true
registration_shared_secret: "$REG_SECRET"
EOF

# --- مرحله 5: راه‌اندازی و یوزر ادمین ---
systemctl restart matrix-synapse
echo -e "${GREEN}ساخت یوزر ادمین:${NC}"
register_new_matrix_user -c /etc/matrix-synapse/conf.d/registration.yaml http://localhost:8008

# --- مرحله 6: دریافت SSL ---
echo -e "${YELLOW}\nمرحله 6: دریافت گواهی SSL (Let's Encrypt)...${NC}"
systemctl stop nginx
certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL_ADDR" -d "$DOMAIN_CHAT" -d "$DOMAIN_APP" -d "$DOMAIN_ROOT"
systemctl start nginx

# --- مرحله 7: کانفیگ Nginx (Matrix & Element & Well-known) ---
echo -e "${YELLOW}\nمرحله 7: تنظیمات وب‌سرور Nginx...${NC}"

# Matrix Chat
cat <<EOF > /etc/nginx/sites-available/matrix.conf
server {
    listen 80; server_name $DOMAIN_CHAT; return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2; server_name $DOMAIN_CHAT;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_CHAT/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_CHAT/privkey.pem;
    client_max_body_size 500M;
    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }
}
EOF

# Element App
cat <<EOF > /etc/nginx/sites-available/element.conf
server {
    listen 80; server_name $DOMAIN_APP; return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2; server_name $DOMAIN_APP;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_CHAT/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_CHAT/privkey.pem;
    root /var/www/element; index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF

# Well-known
cat <<EOF > /etc/nginx/sites-available/matrix-wellknown.conf
server {
    listen 443 ssl http2; server_name $DOMAIN_ROOT;
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

ln -sf /etc/nginx/sites-available/matrix.conf /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/element.conf /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/matrix-wellknown.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# --- مرحله 8: نصب Element Web ---
cd /var/www
REDIRECT_URL=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/vector-im/element-web/releases/latest)
VERSION=$(basename "$REDIRECT_URL")
wget "https://github.com/vector-im/element-web/releases/download/$VERSION/element-$VERSION.tar.gz" -O element.tar.gz
tar -xvf element.tar.gz > /dev/null
rm -rf element && mv element-$VERSION element
rm element.tar.gz

cat <<EOF > /var/www/element/config.json
{
  "default_server_config": {
    "m.homeserver": { "base_url": "https://$DOMAIN_CHAT", "server_name": "$DOMAIN_ROOT" }
  },
  "brand": "Element",
  "disable_custom_urls": true
}
EOF

# --- مرحله 9: TLS ONLY TURN CONFIGURATION (درخواست جدید شما) ---
echo -e "${YELLOW}\nمرحله 9: فعال‌سازی TURN فقط با TLS (امن‌ترین حالت)...${NC}"

TURN_SECRET=$(openssl rand -hex 32)
sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/g' /etc/default/coturn || true
echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn || true

cat > /etc/turnserver.conf <<EOF
###################################
# TURN TLS ONLY CONFIG
###################################
use-auth-secret
static-auth-secret=$TURN_SECRET
realm=$DOMAIN_CHAT
server-name=$DOMAIN_CHAT
fingerprint

# فقط TLS فعال باشد
tls-listening-port=5349
listening-ip=0.0.0.0
external-ip=$SERVER_IP

# SSL Certificate
cert=/etc/letsencrypt/live/$DOMAIN_CHAT/fullchain.pem
pkey=/etc/letsencrypt/live/$DOMAIN_CHAT/privkey.pem

# امنیت: غیرفعال کردن UDP و TCP ناامن
no-udp
no-tcp

# محدوده پورت media
min-port=49160
max-port=49200

# محدودیت‌ها
total-quota=100
bps-capacity=0
no-loopback-peers
no-multicast-peers
EOF

# اصلاح دسترسی SSL برای Coturn
chown turnserver:turnserver /etc/letsencrypt/live/$DOMAIN_CHAT/* || true
chmod 640 /etc/letsencrypt/live/$DOMAIN_CHAT/* || true
# دسترسی به پوشه‌های اصلی برای عبور سرویس
chmod 755 /etc/letsencrypt/live/
chmod 755 /etc/letsencrypt/archive/

systemctl daemon-reload
systemctl enable coturn
systemctl restart coturn

# تنظیم Synapse برای استفاده اختصاصی از TLS
cat > /etc/matrix-synapse/conf.d/turn.yaml <<EOF
turn_uris:
  - "turns:$DOMAIN_CHAT:5349?transport=tcp"

turn_shared_secret: "$TURN_SECRET"
turn_user_lifetime: 86400000
turn_allow_guests: false
EOF

systemctl restart matrix-synapse
echo -e "${GREEN}TURN TLS-only فعال شد.${NC}"

# --- مرحله 10: تنظیم توکن اختصاصی در دیتابیس ---
echo -e "${YELLOW}\nمرحله 10: تزریق توکن ثبت‌نام اختصاصی...${NC}"
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
    print('\033[0;32m>>> توکن اختصاصی با موفقیت در دیتابیس ثبت شد.\033[0m')
"

echo -e "${GREEN}======================================================"
echo -e "         نصب با موفقیت و امنیت کامل به پایان رسید"
echo -e "======================================================${NC}"
echo -e "آدرس المنت: https://$DOMAIN_APP"
echo -e "توکن ثبت‌نام: $USER_TOKEN"
echo -e "پورت‌های باز فایروال: 80, 443 (TCP) و 5349 (TCP) و 49160-49200 (UDP)"
