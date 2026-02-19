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
    exit 1
fi

# --- آپدیت و نصب پیش‌نیازها ---
echo -e "${YELLOW}\nمرحله 2: آپدیت سیستم و نصب پیش‌نیازها...${NC}"
apt update
apt install -y curl wget gnupg lsb-release nginx certbot python3-certbot-nginx coturn

# --- نصب Synapse ---
echo -e "${YELLOW}\nمرحله 3: نصب Synapse...${NC}"
wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] \
https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
| tee /etc/apt/sources.list.d/matrix-org.list

apt update
apt install -y matrix-synapse-py3

# --- کانفیگ Registration ---
echo -e "${YELLOW}\nمرحله 4: تنظیم Registration Shared Secret...${NC}"
# تولید خودکار کد مخفی
REG_SECRET=$(openssl rand -hex 32)
echo -e "Secret تولید شده: ${GREEN}$REG_SECRET${NC}"

cat <<EOF > /etc/matrix-synapse/conf.d/registration.yaml
enable_registration: true
enable_registration_without_verification: true
registration_shared_secret: "$REG_SECRET"
EOF

# --- ریستارت و ساخت یوزر ادمین ---
echo -e "${YELLOW}\nمرحله 5: راه‌اندازی سرویس و ساخت یوزر ادمین...${NC}"
systemctl restart matrix-synapse

echo -e "${GREEN}اکنون باید یک یوزر ادمین بسازید.${NC}"
echo -e "${YELLOW}توجه: وقتی از شما خواسته شد، یک نام کاربری و رمز عبور وارد کنید و برای گزینه Admin عدد 1 (Yes) را بزنید.${NC}"
read -p "برای شروع ساخت یوزر ادمین اینتر بزنید..." DUMMY

register_new_matrix_user -c /etc/matrix-synapse/conf.d/registration.yaml http://localhost:8008

# --- دریافت SSL ---
echo -e "${YELLOW}\nمرحله 6: دریافت گواهی SSL...${NC}"
systemctl stop nginx

# نکته: دامین چت اولین دامین است تا مسیر سرتیفیکیت بر اساس آن ساخته شود
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

# --- نصب Element Web (Dynamic Version) ---
echo -e "${YELLOW}\nمرحله 8: نصب Element Web (آخرین نسخه)...${NC}"
cd /var/www

if [ ! -d "/var/www/element" ]; then
    echo "در حال پیدا کردن نسخه آخر..."

    # 1. دریافت لینک نهایی (Redirect) صفحه آخرین ورژن
    REDIRECT_URL=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/vector-im/element-web/releases/latest)

    # 2. استخراج نام ورژن از انتهای لینک (مثلاً v1.11.86)
    VERSION=$(basename "$REDIRECT_URL")
    echo "نسخه پیدا شد: $VERSION"

    # 3. ساخت لینک دانلود
    DOWNLOAD_LINK="https://github.com/vector-im/element-web/releases/download/$VERSION/element-$VERSION.tar.gz"
    echo "لینک دانلود: $DOWNLOAD_LINK"

    # 4. دانلود فایل
    wget "$DOWNLOAD_LINK" -O element-latest.tar.gz

    if [ -f "element-latest.tar.gz" ]; then
        echo "✅ دانلود با موفقیت انجام شد، در حال اکسترکت..."
        
        tar -xvf element-latest.tar.gz > /dev/null
        
        # پیدا کردن نام پوشه اکسترکت شده (معمولا element-vX.X.X) و تغییر نام به element
        EXTRACTED_DIR="element-$VERSION"
        
        if [ -d "$EXTRACTED_DIR" ]; then
            mv "$EXTRACTED_DIR" element
            echo "✅ پوشه به 'element' تغییر نام یافت."
        else
            # اگر فرمت نام پوشه متفاوت بود، اولین پوشه element-* را پیدا کن
            echo "⚠️ نام پوشه استاندارد نبود، تلاش برای پیدا کردن پوشه..."
            mv element-v* element 2>/dev/null
        fi

        # پاکسازی فایل فشرده
        rm element-latest.tar.gz
    else
        echo "❌ دانلود انجام نشد. اسکریپت متوقف می‌شود."
        exit 1
    fi
else
    echo "پوشه Element از قبل وجود دارد، رد شدن از دانلود..."
fi

# تنظیم کانفیگ المنت
cat <<EOF > /var/www/element/config.json
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://$DOMAIN_CHAT",
      "server_name": "$DOMAIN_ROOT"
    }
  },
  "disable_custom_urls": false,
  "disable_guests": true,
  "brand": "Element",
  "integrations_ui_url": "https://scalar.vector.im/",
  "integrations_rest_url": "https://scalar.vector.im/api",
  "enable_presence_by_hs_url": {
    "https://$DOMAIN_CHAT": true
  }
}
EOF

# --- کانفیگ Nginx برای Element ---
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

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -s /etc/nginx/sites-available/element.conf /etc/nginx/sites-enabled/element.conf

# --- کانفیگ Nginx برای Well-known ---
echo -e "${YELLOW}\nمرحله 10: تنظیم Nginx برای Well-known...${NC}"

# نام فایل کانفیگ به matrix-wellknown.conf تغییر یافت تا عمومی باشد
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
        return 200 '{"m.homeserver":{"base_url":"https://$DOMAIN_CHAT"}}';
    }

    location = /.well-known/matrix/server {
        add_header Content-Type application/json;
        return 200 '{"m.server":"$DOMAIN_CHAT:443"}';
    }

    location / {
        return 404;
    }
}
EOF

ln -s /etc/nginx/sites-available/matrix-wellknown.conf /etc/nginx/sites-enabled/matrix-wellknown.conf

# حذف دیفالت و ریلود
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# --- تنظیم coturn ---
echo -e "${YELLOW}\nمرحله 11: تنظیم و فعال‌سازی TURN Server (Coturn)...${NC}"

# فعال سازی در دیفالت
sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/g' /etc/default/coturn
# اگر کامنت نشده بود و صرفا نبود:
if ! grep -q "TURNSERVER_ENABLED=1" /etc/default/coturn; then
    echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn
fi

# تولید secret برای turn
TURN_SECRET=$(openssl rand -hex 32)
echo -e "TURN Secret تولید شده: ${GREEN}$TURN_SECRET${NC}"

mv /etc/turnserver.conf /etc/turnserver.conf.backup 2>/dev/null || true

cat <<EOF > /etc/turnserver.conf
syslog
no-rfc5780
no-stun-backward-compatibility
response-origin-only-with-rfc5780

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

total-quota=100
bps-capacity=0

no-loopback-peers
no-multicast-peers

verbose
EOF

systemctl restart coturn

# --- اتصال TURN به Synapse ---
echo -e "${YELLOW}\nمرحله 12: معرفی TURN به Synapse...${NC}"

cat <<EOF > /etc/matrix-synapse/conf.d/turn.yaml
turn_uris:
  - "turn:$DOMAIN_CHAT:3478?transport=udp"
  - "turns:$DOMAIN_CHAT:5349?transport=tcp"

turn_shared_secret: "$TURN_SECRET"
turn_user_lifetime: 86400000
turn_allow_guests: false
EOF

systemctl restart matrix-synapse

# --- پایان ---
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}                 نصب با موفقیت انجام شد               ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo ""
echo -e "بررسی وضعیت نهایی:"
curl -k "https://$DOMAIN_CHAT/_matrix/client/versions"
echo ""
echo -e "${YELLOW}آدرس‌ها:${NC}"
echo -e "Element Web: https://$DOMAIN_APP"
echo -e "Homeserver:  https://$DOMAIN_CHAT"
echo ""
echo -e "${YELLOW}نکته:${NC} پورت‌های 80, 443, 3478, 5349, و رنج 49160-49200 را در فایروال باز کنید."
