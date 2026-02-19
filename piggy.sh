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
echo -e "${GREEN}    Matrix (Synapse) + Element + Coturn Installer     ${NC}"
echo -e "${GREEN}    (Auto-Update Element Version)                     ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo ""

# --- دریافت اطلاعات از کاربر ---

echo -e "${YELLOW}مرحله 1: دریافت اطلاعات دامنه و سرور${NC}"

read -p "لطفاً دامنه اصلی را وارد کنید (مثلاً example.com): " DOMAIN_ROOT
read -p "لطفاً ساب‌دامین چت را وارد کنید (مثلاً chat.$DOMAIN_ROOT): " DOMAIN_CHAT
read -p "لطفاً ساب‌دامین المنت را وارد کنید (مثلاً app.$DOMAIN_ROOT): " DOMAIN_APP
read -p "آدرس IP پابلیک سرور را وارد کنید: " SERVER_IP
read -p "ایمیل خود را برای دریافت گواهی SSL وارد کنید: " EMAIL_ADDR

# ✅ تغییر دوم (قسمت 1): درخواست توکن از کاربر
read -p "لطفاً Registration Token مورد نظر را وارد کنید (مثلاً piggy): " REG_TOKEN

echo ""
echo -e "اطلاعات وارد شده:"
echo -e "Root Domain: ${GREEN}$DOMAIN_ROOT${NC}"
echo -e "Chat Domain: ${GREEN}$DOMAIN_CHAT${NC}"
echo -e "App Domain:  ${GREEN}$DOMAIN_APP${NC}"
echo -e "Server IP:   ${GREEN}$SERVER_IP${NC}"
echo -e "Email:       ${GREEN}$EMAIL_ADDR${NC}"
echo -e "Token:       ${GREEN}$REG_TOKEN${NC}"
echo ""

read -p "آیا اطلاعات بالا صحیح است؟ (y/n): " CONFIRM
if [[ $CONFIRM != "y" ]]; then
    echo -e "${RED}نصب لغو شد.${NC}"
    exit 1
fi

# --- آپدیت و نصب پیش‌نیازها ---
echo -e "${YELLOW}\nمرحله 2: آپدیت سیستم و نصب پیش‌نیازها...${NC}"
apt update
apt install -y curl wget gnupg lsb-release nginx certbot python3-certbot-nginx coturn sqlite3 python3

# --- نصب Synapse ---
echo -e "${YELLOW}\nمرحله 3: نصب Synapse...${NC}"
wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] \
https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
| tee /etc/apt/sources.list.d/matrix-org.list

apt update
apt install -y matrix-synapse-py3

# --- کانفیگ Registration ---
echo -e "${YELLOW}\nمرحله 4: تنظیم Registration Shared Secret و Token...${NC}"

REG_SECRET=$(openssl rand -hex 32)
echo -e "Secret تولید شده: ${GREEN}$REG_SECRET${NC}"

cat <<EOF > /etc/matrix-synapse/conf.d/registration.yaml
enable_registration: true
enable_registration_without_verification: true
registration_requires_token: true
registration_shared_secret: "$REG_SECRET"
EOF

systemctl restart matrix-synapse
sleep 5

# ✅ تغییر دوم (قسمت 2): اضافه کردن توکن به دیتابیس
echo -e "${YELLOW}در حال ثبت Registration Token در دیتابیس...${NC}"

python3 - <<EOF
import sqlite3
import os
import sys

db_path = '/var/lib/matrix-synapse/homeserver.db'
token = "$REG_TOKEN"

if not os.path.exists(db_path):
    print("خطا: دیتابیس پیدا نشد!")
    sys.exit(1)

con = sqlite3.connect(db_path)
cur = con.cursor()

cur.execute("DELETE FROM registration_tokens WHERE token=?", (token,))
cur.execute(
    "INSERT INTO registration_tokens (token, uses_allowed, pending, completed) VALUES (?, NULL, 0, 0)",
    (token,)
)

con.commit()
con.close()

print("توکن با موفقیت ثبت شد:", token)
EOF

# --- ریستارت و ساخت یوزر ادمین ---
echo -e "${YELLOW}\nمرحله 5: راه‌اندازی سرویس و ساخت یوزر ادمین...${NC}"
systemctl restart matrix-synapse

echo -e "${GREEN}اکنون باید یک یوزر ادمین بسازید.${NC}"
read -p "برای شروع ساخت یوزر ادمین اینتر بزنید..." DUMMY

register_new_matrix_user -c /etc/matrix-synapse/conf.d/registration.yaml http://localhost:8008

# --- دریافت SSL ---
echo -e "${YELLOW}\nمرحله 6: دریافت گواهی SSL...${NC}"
systemctl stop nginx

certbot certonly --standalone \
  --non-interactive --agree-tos -m "$EMAIL_ADDR" \
  -d "$DOMAIN_CHAT" \
  -d "$DOMAIN_APP" \
  -d "$DOMAIN_ROOT"

systemctl start nginx

# --- کانفیگ Nginx برای Matrix ---
echo -e "${YELLOW}\nمرحله 7: تنظیم Nginx برای Matrix (Synapse)...${NC}"

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

ln -s /etc/nginx/sites-available/matrix.conf /etc/nginx/sites-enabled/matrix.conf

# --- نصب Element Web ---
echo -e "${YELLOW}\nمرحله 8: نصب Element Web (آخرین نسخه)...${NC}"
cd /var/www

if [ ! -d "/var/www/element" ]; then

REDIRECT_URL=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/vector-im/element-web/releases/latest)
VERSION=$(basename "$REDIRECT_URL")

wget "https://github.com/vector-im/element-web/releases/download/$VERSION/element-$VERSION.tar.gz" -O element-latest.tar.gz

tar -xvf element-latest.tar.gz > /dev/null
mv element-$VERSION element
rm element-latest.tar.gz

fi

cat <<EOF > /var/www/element/config.json
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://$DOMAIN_CHAT",
      "server_name": "$DOMAIN_ROOT"
    }
  }
}
EOF

# --- کانفیگ Element Nginx ---
echo -e "${YELLOW}\nمرحله 9: تنظیم Nginx برای Element...${NC}"

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
}
EOF

ln -s /etc/nginx/sites-available/element.conf /etc/nginx/sites-enabled/element.conf

# --- Well-known ---
echo -e "${YELLOW}\nمرحله 10: تنظیم Well-known...${NC}"

cat <<EOF > /etc/nginx/sites-available/matrix-wellknown.conf
server {
listen 443 ssl;
server_name $DOMAIN_ROOT;

ssl_certificate /etc/letsencrypt/live/$DOMAIN_CHAT/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_CHAT/privkey.pem;

location /.well-known/matrix/server {
return 200 '{"m.server":"$DOMAIN_CHAT:443"}';
}

location /.well-known/matrix/client {
return 200 '{"m.homeserver":{"base_url":"https://$DOMAIN_CHAT"}}';
}
}
EOF

ln -s /etc/nginx/sites-available/matrix-wellknown.conf /etc/nginx/sites-enabled/

rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# --- تنظیم coturn ---
echo -e "${YELLOW}\nمرحله 11: تنظیم TURN Server...${NC}"

sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn

TURN_SECRET=$(openssl rand -hex 32)

cat <<EOF > /etc/turnserver.conf
listening-port=3478
tls-listening-port=5349
external-ip=$SERVER_IP
realm=$DOMAIN_CHAT
server-name=$DOMAIN_CHAT
use-auth-secret
static-auth-secret=$TURN_SECRET
cert=/etc/letsencrypt/live/$DOMAIN_CHAT/fullchain.pem
pkey=/etc/letsencrypt/live/$DOMAIN_CHAT/privkey.pem
EOF

# ✅ تغییر اول: اصلاح دسترسی SSL برای turnserver
echo -e "${YELLOW}اصلاح دسترسی SSL برای TURN...${NC}"

chown -R turnserver:turnserver /etc/letsencrypt/archive/
chown -R turnserver:turnserver /etc/letsencrypt/live/

chmod 755 /etc/letsencrypt/live/
chmod 755 /etc/letsencrypt/archive/

systemctl restart coturn

# --- اتصال TURN به Synapse ---
echo -e "${YELLOW}\nمرحله 12: اتصال TURN به Synapse...${NC}"

cat <<EOF > /etc/matrix-synapse/conf.d/turn.yaml
turn_uris:
  - "turn:$DOMAIN_CHAT:3478?transport=udp"
  - "turns:$DOMAIN_CHAT:5349?transport=tcp"
turn_shared_secret: "$TURN_SECRET"
EOF

systemctl restart matrix-synapse

# --- پایان ---
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}نصب کامل شد${NC}"
echo -e "${GREEN}======================================================${NC}"
echo "Element: https://$DOMAIN_APP"
echo "Homeserver: https://$DOMAIN_CHAT"
echo "Registration Token: $REG_TOKEN"
