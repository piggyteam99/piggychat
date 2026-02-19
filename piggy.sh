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
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN} Matrix Synapse + Element + Coturn Secure Installer ${NC}"
echo -e "${GREEN} TLS ONLY + TOKEN REGISTRATION + SSL FIX ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo ""

########################################
# مرحله 1 دریافت اطلاعات
########################################

echo -e "${YELLOW}مرحله 1: دریافت اطلاعات${NC}"

read -p "دامنه اصلی: " DOMAIN_ROOT
read -p "ساب دامنه Synapse (chat): " DOMAIN_CHAT
read -p "ساب دامنه Element (app): " DOMAIN_APP
read -p "IP سرور: " SERVER_IP
read -p "ایمیل SSL: " EMAIL_ADDR
read -p "توکن ثبت نام (مثال: piggy): " REG_TOKEN

echo ""
echo -e "${GREEN}دامنه اصلی:${NC} $DOMAIN_ROOT"
echo -e "${GREEN}Chat:${NC} $DOMAIN_CHAT"
echo -e "${GREEN}App:${NC} $DOMAIN_APP"
echo -e "${GREEN}IP:${NC} $SERVER_IP"
echo -e "${GREEN}Token:${NC} $REG_TOKEN"

read -p "آیا صحیح است؟ (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && exit 1


########################################
# نصب پیش نیاز
########################################

echo -e "${YELLOW}Installing packages...${NC}"

apt update
apt install -y \
curl wget gnupg lsb-release \
nginx certbot python3-certbot-nginx \
coturn sqlite3 python3


########################################
# نصب Synapse
########################################

echo -e "${YELLOW}Installing Synapse...${NC}"

wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg \
https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] \
https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
> /etc/apt/sources.list.d/matrix-org.list

apt update
apt install -y matrix-synapse-py3


########################################
# تنظیم registration + token
########################################

echo -e "${YELLOW}Configuring registration token...${NC}"

REG_SECRET=$(openssl rand -hex 32)

cat > /etc/matrix-synapse/conf.d/registration.yaml <<EOF
enable_registration: true
registration_requires_token: true
registration_shared_secret: "$REG_SECRET"
EOF

systemctl restart matrix-synapse
sleep 5


########################################
# اضافه کردن توکن به دیتابیس
########################################

echo -e "${YELLOW}Adding token to database...${NC}"

python3 <<EOF
import sqlite3
db="/var/lib/matrix-synapse/homeserver.db"
con=sqlite3.connect(db)
cur=con.cursor()
cur.execute("DELETE FROM registration_tokens WHERE token=?",("$REG_TOKEN",))
cur.execute("INSERT INTO registration_tokens (token, uses_allowed, pending, completed) VALUES (?,NULL,0,0)",("$REG_TOKEN",))
con.commit()
con.close()
EOF

echo -e "${GREEN}Token added successfully${NC}"


########################################
# SSL
########################################

echo -e "${YELLOW}Getting SSL...${NC}"

systemctl stop nginx || true

certbot certonly \
--standalone \
--agree-tos \
--non-interactive \
-m "$EMAIL_ADDR" \
-d "$DOMAIN_CHAT" \
-d "$DOMAIN_APP" \
-d "$DOMAIN_ROOT"

systemctl start nginx


########################################
# FIX SSL PERMISSIONS FOR TURN
########################################

echo -e "${YELLOW}Fixing SSL permissions for coturn...${NC}"

chown -R turnserver:turnserver /etc/letsencrypt/archive/
chown -R turnserver:turnserver /etc/letsencrypt/live/

chmod 755 /etc/letsencrypt/live/
chmod 755 /etc/letsencrypt/archive/


########################################
# NGINX Synapse
########################################

cat > /etc/nginx/sites-available/matrix.conf <<EOF
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
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;
}
}
EOF

ln -sf /etc/nginx/sites-available/matrix.conf /etc/nginx/sites-enabled/


########################################
# Element install
########################################

echo -e "${YELLOW}Installing Element...${NC}"

cd /var/www

REDIRECT=$(curl -Ls -o /dev/null -w %{url_effective} \
https://github.com/vector-im/element-web/releases/latest)

VERSION=$(basename "$REDIRECT")

wget https://github.com/vector-im/element-web/releases/download/$VERSION/element-$VERSION.tar.gz

tar xf element-$VERSION.tar.gz
mv element-$VERSION element

cat > /var/www/element/config.json <<EOF
{
"default_server_config": {
"m.homeserver": {
"base_url": "https://$DOMAIN_CHAT",
"server_name": "$DOMAIN_ROOT"
}
}
}
EOF


########################################
# nginx element
########################################

cat > /etc/nginx/sites-available/element.conf <<EOF
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

ln -sf /etc/nginx/sites-available/element.conf /etc/nginx/sites-enabled/


########################################
# TURN TLS ONLY CONFIG
########################################

echo -e "${YELLOW}Configuring TURN TLS ONLY...${NC}"

TURN_SECRET=$(openssl rand -hex 32)

cat > /etc/turnserver.conf <<EOF
use-auth-secret
static-auth-secret=$TURN_SECRET

realm=$DOMAIN_CHAT
server-name=$DOMAIN_CHAT

fingerprint

tls-listening-port=5349

listening-ip=0.0.0.0
external-ip=$SERVER_IP

cert=/etc/letsencrypt/live/$DOMAIN_CHAT/fullchain.pem
pkey=/etc/letsencrypt/live/$DOMAIN_CHAT/privkey.pem

no-udp
no-tcp

min-port=49160
max-port=49200

total-quota=100
EOF


########################################
# SSL permission final fix
########################################

chown turnserver:turnserver /etc/letsencrypt/live/$DOMAIN_CHAT/*
chmod 640 /etc/letsencrypt/live/$DOMAIN_CHAT/*


########################################
# Enable coturn
########################################

sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn || true
echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn

systemctl daemon-reexec
systemctl enable coturn
systemctl restart coturn


########################################
# Synapse TURN TLS ONLY
########################################

cat > /etc/matrix-synapse/conf.d/turn.yaml <<EOF
turn_uris:
- "turns:$DOMAIN_CHAT:5349?transport=tcp"

turn_shared_secret: "$TURN_SECRET"
turn_user_lifetime: 86400000
turn_allow_guests: false
EOF

systemctl restart matrix-synapse


########################################
# reload nginx
########################################

nginx -t
systemctl reload nginx


########################################
# Done
########################################

echo ""
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}INSTALL COMPLETED SUCCESSFULLY${NC}"
echo -e "${GREEN}====================================================${NC}"

echo ""
echo "Element:"
echo "https://$DOMAIN_APP"

echo ""
echo "Synapse:"
echo "https://$DOMAIN_CHAT"

echo ""
echo "Registration Token:"
echo "$REG_TOKEN"

echo ""
echo "TURN TLS ONLY ENABLED"
