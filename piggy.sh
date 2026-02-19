#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}لطفاً اسکریپت را با sudo اجرا کنید${NC}"
  exit
fi

clear

echo -e "${GREEN}"
echo "======================================================"
echo " Matrix Synapse + Element + Coturn Manager"
echo "======================================================"
echo -e "${NC}"

echo "1) نصب کامل"
echo "2) فعال سازی ثبت نام با توکن"
echo "3) حذف کامل"
echo ""
read -p "انتخاب کنید: " OPTION

##############################################
# گزینه 1 : نصب کامل (اسکریپت اصلی شما)
##############################################

if [ "$OPTION" = "1" ]; then

clear
echo -e "${GREEN}شروع نصب کامل...${NC}"

##############################################
# کل اسکریپت اصلی شما بدون تغییر
##############################################

# --- دریافت اطلاعات ---
echo -e "${YELLOW}مرحله 1: دریافت اطلاعات دامنه و سرور${NC}"

read -p "دامنه اصلی: " DOMAIN_ROOT
read -p "دامنه چت: " DOMAIN_CHAT
read -p "دامنه Element: " DOMAIN_APP
read -p "IP سرور: " SERVER_IP
read -p "ایمیل SSL: " EMAIL_ADDR

read -p "تایید؟ y/n: " CONFIRM
[ "$CONFIRM" != "y" ] && exit

##############################################
# نصب پیش نیازها
##############################################

apt update
apt install -y curl wget gnupg lsb-release nginx certbot python3-certbot-nginx coturn sqlite3 openssl

##############################################
# نصب synapse
##############################################

wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] \
https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
| tee /etc/apt/sources.list.d/matrix-org.list

apt update
apt install -y matrix-synapse-py3

##############################################
# registration
##############################################

REG_SECRET=$(openssl rand -hex 32)

cat <<EOF > /etc/matrix-synapse/conf.d/registration.yaml
enable_registration: true
enable_registration_without_verification: true
registration_shared_secret: "$REG_SECRET"
EOF

systemctl restart matrix-synapse

##############################################
# SSL
##############################################

systemctl stop nginx

certbot certonly --standalone \
--agree-tos \
--non-interactive \
-m "$EMAIL_ADDR" \
-d "$DOMAIN_CHAT" \
-d "$DOMAIN_APP" \
-d "$DOMAIN_ROOT"

systemctl start nginx

##############################################
# nginx matrix
##############################################

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

location / {
proxy_pass http://127.0.0.1:8008;
proxy_set_header Host \$host;
proxy_set_header X-Forwarded-For \$remote_addr;
proxy_set_header X-Forwarded-Proto https;
}
}
EOF

ln -sf /etc/nginx/sites-available/matrix.conf /etc/nginx/sites-enabled/

##############################################
# نصب element
##############################################

cd /var/www

REDIRECT_URL=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/vector-im/element-web/releases/latest)

VERSION=$(basename "$REDIRECT_URL")

wget https://github.com/vector-im/element-web/releases/download/$VERSION/element-$VERSION.tar.gz

tar -xzf element-$VERSION.tar.gz

mv element-$VERSION element

##############################################
# config element
##############################################

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

##############################################
# nginx element
##############################################

cat <<EOF > /etc/nginx/sites-available/element.conf
server {
listen 80;
server_name $DOMAIN_APP;
return 301 https://\$host\$request_uri;
}

server {

listen 443 ssl;
server_name $DOMAIN_APP;

ssl_certificate /etc/letsencrypt/live/$DOMAIN_CHAT/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_CHAT/privkey.pem;

root /var/www/element;
index index.html;
}
EOF

ln -sf /etc/nginx/sites-available/element.conf /etc/nginx/sites-enabled/

##############################################
# TURN with SSL (مهم برای تماس صوتی تصویری)
##############################################

TURN_SECRET=$(openssl rand -hex 32)

cat <<EOF > /etc/turnserver.conf

listening-port=3478
tls-listening-port=5349

external-ip=$SERVER_IP

realm=$DOMAIN_CHAT

cert=/etc/letsencrypt/live/$DOMAIN_CHAT/fullchain.pem
pkey=/etc/letsencrypt/live/$DOMAIN_CHAT/privkey.pem

use-auth-secret
static-auth-secret=$TURN_SECRET

fingerprint
total-quota=100

min-port=49160
max-port=49200
EOF

systemctl enable coturn
systemctl restart coturn

##############################################
# synapse turn config SSL
##############################################

cat <<EOF > /etc/matrix-synapse/conf.d/turn.yaml

turn_uris:
  - "turn:$DOMAIN_CHAT:3478?transport=udp"
  - "turns:$DOMAIN_CHAT:5349?transport=tcp"

turn_shared_secret: "$TURN_SECRET"

turn_user_lifetime: 86400000

turn_allow_guests: false

EOF

systemctl restart matrix-synapse
systemctl restart nginx

echo -e "${GREEN}نصب کامل شد${NC}"

fi

##############################################
# گزینه 2 : فعال سازی ثبت نام با توکن
##############################################

if [ "$OPTION" = "2" ]; then

echo -e "${RED}"
echo "هشدار:"
echo "فعال کردن توکن ممکن است در Element ارور نمایش دهد"
echo -e "${NC}"

read -p "ادامه؟ y/n: " CONFIRM
[ "$CONFIRM" != "y" ] && exit

read -p "توکن مورد نظر را وارد کنید: " TOKEN

REG_SECRET=$(openssl rand -hex 32)

cat <<EOF > /etc/matrix-synapse/conf.d/registration.yaml
enable_registration: true
registration_requires_token: true
registration_shared_secret: "$REG_SECRET"
EOF

systemctl restart matrix-synapse
sleep 3

python3 <<EOF
import sqlite3

con=sqlite3.connect("/var/lib/matrix-synapse/homeserver.db")
cur=con.cursor()

cur.execute("DELETE FROM registration_tokens WHERE token=?",("$TOKEN",))
cur.execute("INSERT INTO registration_tokens (token, uses_allowed, pending, completed) VALUES (?, NULL, 0, 0)",("$TOKEN",))

con.commit()
con.close()
EOF

systemctl restart matrix-synapse

echo -e "${GREEN}توکن ساخته شد${NC}"

fi

##############################################
# گزینه 3 : حذف کامل
##############################################

if [ "$OPTION" = "3" ]; then

echo -e "${RED}حذف کامل...${NC}"

systemctl stop matrix-synapse || true
systemctl stop coturn || true
systemctl stop nginx || true

apt purge -y matrix-synapse-py3 coturn nginx certbot

rm -rf /etc/matrix-synapse
rm -rf /var/lib/matrix-synapse
rm -rf /var/www/element

rm -rf /etc/nginx/sites-enabled/*
rm -rf /etc/nginx/sites-available/*

rm -rf /etc/letsencrypt

apt autoremove -y

echo -e "${GREEN}حذف کامل شد${NC}"

fi
