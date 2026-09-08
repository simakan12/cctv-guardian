#!/bin/bash

# ============================================
# CCTV Guardian - Complete Setup Script
# Sistem: Debian/Ubuntu Server
# ============================================

set -e

echo "========================================"
echo "  CCTV Guardian - Setup Script"
echo "========================================"
echo ""

# ============================================
# Configuration Variables
# ============================================

# App settings
APP_NAME="cctv-guardian"
APP_DIR="/opt/$APP_NAME"
APP_PORT=8000
APP_USER="cctvapp"

# Default credentials (GANTI SAAT INSTALLSI)
DEFAULT_ADMIN_USER="admin"
# Generate random password otomatis, atau set manual di sini
DEFAULT_ADMIN_PASS=$(openssl rand -base64 16 | tr -d '=+/' | head -c 16)

# RTSP Camera URL (GANTI SESUAI CAMERA MASING-MASING)
RTSP_URL_1="rtsp://admin:password@192.168.1.100:554/stream"

# Admin email untuk notifikasi (opsional)
ADMIN_EMAIL="admin@example.com"

# SSL (gunakan Let's Encrypt kalau ada domain)
ENABLE_SSL="y"
SSL_DOMAIN="cctv.example.com"
ADMIN_EMAIL_SSL="admin@example.com"

# ============================================
# Color Codes
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_section() { echo ""; echo -e "${BOLD}$1${NC}"; echo "========================================"; }

# ============================================
# Pre-Flight Checks
# ============================================

print_section "Pre-Flight Checks"

# Cek OS
if [[ -f /etc/debian_version ]] || [[ -f /etc/os-release ]]; then
    print_status "OS: Debian/Ubuntu detected"
else
    print_error "This script only supports Debian/Ubuntu"
    exit 1
fi

# Cek root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root (sudo ./setup.sh)"
    exit 1
fi

# Cek internet connection
if ! ping -c 1 8.8.8.8 &>/dev/null; then
    print_error "No internet connection. Please check your network."
    exit 1
fi

print_status "Pre-flight checks passed"

# ============================================
# Step 1: Update System
# ============================================

print_section "Step 1: Updating System Packages"

echo "Updating apt repositories..."
apt update -y
apt upgrade -y
apt autoremove -y

print_status "System packages updated"

# ============================================
# Step 2: Install System Dependencies
# ============================================

print_section "Step 2: Installing System Dependencies"

echo "Installing required packages..."

apt install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    python3-setuptools \
    build-essential \
    ffmpeg \
    git \
    curl \
    wget \
    unzip \
    nginx \
    supervisor \
    fail2ban \
    ufw \
    certbot \
    python3-certbot-nginx \
    jq

print_status "System dependencies installed"

# ============================================
# Step 3: Create Application User
# ============================================

print_section "Step 3: Creating Application User"

if id "$APP_USER" &>/dev/null; then
    print_info "User '$APP_USER' already exists"
else
    useradd -m -s /bin/bash "$APP_USER"
    print_status "User '$APP_USER' created"
fi

# ============================================
# Step 4: Create Application Directory
# ============================================

print_section "Step 4: Setting Up Application Directory"

mkdir -p "$APP_DIR"/{backend,templates,static/css,static/js,recordings,logs,backups}
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

print_status "Application directory created at $APP_DIR"

# ============================================
# Step 5: Create Python Virtual Environment
# ============================================

print_section "Step 5: Creating Python Virtual Environment"

cd "$APP_DIR"

if [ ! -d "venv" ]; then
    sudo -u "$APP_USER" python3 -m venv venv
    print_status "Virtual environment created"
else
    print_info "Virtual environment already exists"
fi

# ============================================
# Step 6: Install Python Dependencies
# ============================================

print_section "Step 6: Installing Python Dependencies"

sudo -u "$APP_USER" bash -c "cd $APP_DIR && source venv/bin/activate && pip install --upgrade pip --quiet"

# Install all Python packages
sudo -u "$APP_USER" bash -c "cd $APP_DIR && source venv/bin/activate && pip install -r requirements.txt --quiet"

print_status "Python dependencies installed"

# ============================================
# Step 7: Create Configuration Files
# ============================================

print_section "Step 7: Creating Configuration Files"

# .env file
cat > "$APP_DIR/.env" << EOF
# CCTV Guardian Configuration
# ============================================

# Application
APP_NAME="CCTV Guardian"
APP_VERSION="1.0.0"
DEBUG=false
HOST=0.0.0.0
PORT=$APP_PORT

# Authentication
AUTH_SECRET=$(openssl rand -hex 32)
AUTH_SESSION_TIMEOUT=24

# RTSP Camera Configuration
RTSP_URL_1="$RTSP_URL_1"
RTSP_URL_2=""

# Recording Configuration
LOCAL_SAVE_PATH=$APP_DIR/recordings
MAX_LOCAL_STORAGE_GB=50
CLOUD_UPLOAD_ENABLED=false
CLOUD_PROVIDER=none

# Detection Configuration
DETECTION_MODEL_TYPE="yolov8n"
DETECTION_CONFIDENCE_THRESHOLD=0.5
DETECTION_ENABLED=true

# Alert Configuration
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
EMAIL_ENABLED=false
EMAIL_SENDER=""
EMAIL_PASSWORD=""
EMAIL_RECIPIENT=""

# Log Configuration
LOG_DIR=$APP_DIR/logs
LOG_LEVEL=INFO
EOF

chown "$APP_USER:$APP_USER" "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

print_status ".env configuration file created"

# ============================================
# Step 8: Create Supervisor Configuration
# ============================================

print_section "Step 8: Configuring Supervisor"

cat > /etc/supervisor/conf.d/cctv-guardian.conf << EOF
[program:cctv-guardian]
command=/opt/cctv-guardian/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port $APP_PORT
directory=/opt/cctv-guardian
user=$APP_USER
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
stderr_logfile=/var/log/cctv-guardian/error.log
stdout_logfile=/var/log/cctv-guardian/access.log
environment=PYTHONUNBUFFERED="1"
environment=AUTH_SECRET="$(grep AUTH_SECRET $APP_DIR/.env | cut -d'=' -f2)"
environment=PORT="$APP_PORT"
environment=RTSP_URL_1="$RTSP_URL_1"
environment=LOCAL_SAVE_PATH="$APP_DIR/recordings"
environment=DETECTION_ENABLED=true
environment=DEBUG=false
EOF

mkdir -p /var/log/cctv-guardian
chown "$APP_USER:$APP_USER" /var/log/cctv-guardian

print_status "Supervisor configuration created"

# ============================================
# Step 9: Setup Nginx (Reverse Proxy)
# ============================================

print_section "Step 9: Setting Up Nginx Reverse Proxy"

echo ""
echo "========================================"
echo "  Nginx Configuration"
echo "========================================"
echo ""
echo "Pilih opsi setup Nginx:"
echo "  1) Setup otomatis dengan domain yang sudah disediakan"
echo "  2) Setup manual (belum ada domain)"
echo "  3) Skip (jalankan langsung di port $APP_PORT)"
echo ""

read -p "Pilihan [1/2/3]: " nginx_choice

case $nginx_choice in
    1)
        read -p "Masukkan domain/subdomain (misal: cctv.example.com): " domain
        if [ -z "$domain" ]; then
            print_error "Domain tidak boleh kosong"
            exit 1
        fi
        
        # Buat Nginx config
        cat > /etc/nginx/sites-available/cctv-guardian << EOF
server {
    listen 80;
    server_name $domain;
    
    # Redirect HTTP ke HTTPS (nanti setelah SSL setup)
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support untuk stream real-time
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Static files
        location /static/ {
            alias /opt/cctv-guardian/static/;
            expires 30d;
            add_header Cache-Control "public, immutable";
        }
        
        # Timeouts untuk streaming
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        send_timeout 3600s;
    }
}
EOF

        ln -sf /etc/nginx/sites-available/cctv-guardian /etc/nginx/sites-enabled/
        rm -f /etc/nginx/sites-enabled/default
        
        nginx -t && systemctl reload nginx
        print_status "Nginx config created for $domain"
        
        # Setup SSL jika diminta
        echo ""
        read -p "Setup SSL certificate otomatis dengan Let's Encrypt? (y/n) " ssl_choice
        if [[ $ssl_choice =~ ^[Yy]$ ]]; then
            echo "Menginstall SSL certificate untuk $domain..."
            
            # Update certbot tools
            apt install -y certbot python3-certbot-nginx
            
            certbot --nginx -d "$domain" \
                --non-interactive \
                --agree-tos \
                --email "$ADMIN_EMAIL_SSL" \
                --redirect
            
            print_status "SSL certificate installed for $domain"
            print_info "HTTPS: https://$domain"
        fi
        ;;
        
    2)
        print_info "Silakan setup Nginx manual setelah install selesai."
        print_info "Contoh config Nginx ada di: /etc/nginx/sites-available/cctv-guardian.example"
        ;;
        
    3)
        print_info "Nginx skipped. Aplikasi akan jalan langsung di port $APP_PORT"
        print_info "Akses langsung: http://$(hostname -I | awk '{print $1}'):$APP_PORT"
        ;;
        
    *)
        print_error "Pilihan tidak valid"
        exit 1
        ;;
esac

# ============================================
# Step 10: Setup Firewall (UFW)
# ============================================

print_section "Step 10: Configuring Firewall (UFW)"

echo ""
echo "========================================"
echo "  Firewall Configuration"
echo "========================================"
echo ""

if command -v ufw &> /dev/null; then
    echo "Konfigurasi UFW:"
    echo "  1) Enable firewall dan buka port yang diperlukan"
    echo "  2) Skip (belum setup firewall)"
    echo ""
    
    read -p "Pilihan [1/2]: " firewall_choice
    
    if [[ $firewall_choice =~ ^[Yy]$ ]]; then
        ufw --force enable
        
        # Buka SSH (jangan ditutup sebelum yakin bisa akses)
        ufw allow 22/tcp comment "SSH"
        print_status "SSH port (22) opened"
        
        # Buka Nginx HTTP/HTTPS
        if [[ $nginx_choice == "1" ]]; then
            ufw allow 'Nginx Full'
            print_status "Nginx ports (80, 443) opened"
        fi
        
        # Buka aplikasi port
        ufw allow "$APP_PORT/tcp" comment "CCTV Guardian"
        print_status "Application port ($APP_PORT) opened"
        
        ufw status
    else
        print_warning "Firewall tidak di-setup. Buka port manual jika perlu."
    fi
else
    print_warning "UFW not found. Install with: apt install ufw"
fi

# ============================================
# Step 11: Init Database & Create Admin User
# ============================================

print_section "Step 11: Initializing Database & Creating Admin User"

cd "$APP_DIR"

# Initialize database tables
sudo -u "$APP_USER" bash -c "cd $APP_DIR && source venv/bin/activate && python -c \"
from backend.database import Base, engine
Base.metadata.create_all(bind=engine)
print('Database tables created successfully')
\""

print_status "Database tables created"

# Create admin user
sudo -u "$APP_USER" bash -c "cd $APP_DIR && source venv/bin/activate && python -c \"
from backend.database import SessionLocal, User
from backend.auth import hash_password

db = SessionLocal()
existing = db.query(User).filter(User.username == '$DEFAULT_ADMIN_USER').first()

if existing:
    print(f'Admin user \"$DEFAULT_ADMIN_USER\" already exists')
else:
    new_user = User(
        username='$DEFAULT_ADMIN_USER',
        password_hash=hash_password('$DEFAULT_ADMIN_PASS'),
        role='admin',
        is_active=True
    )
    db.add(new_user)
    db.commit()
    print(f'Admin user created: $DEFAULT_ADMIN_USER')
    print(f'Password: $DEFAULT_ADMIN_PASS')
db.close()
\""

print_status "Admin user configured"

# ============================================
# Step 12: Start Application
# ============================================

print_section "Step 12: Starting Application"

# Reload supervisor
supervisorctl reread
supervisorctl update

# Start application
sleep 2
supervisorctl start cctv-guardian

# Cek status
sleep 3
if supervisorctl status cctv-guardian | grep -q "RUNNING"; then
    print_status "Application is running"
else
    print_warning "Application may not be running properly. Check logs."
fi

# ============================================
# Final Summary
# ============================================

print_section "Setup Complete!"

echo ""
echo "========================================"
echo "  CCTV Guardian - Installed Successfully"
echo "========================================"
echo ""
echo "Aplikasi berjalan di:"
echo "  - Direct: http://$(hostname -I | awk '{print $1}'):$APP_PORT"
if [[ $nginx_choice == "1" ]]; then
    echo "  - Domain: http://$domain"
    if [[ $ssl_choice =~ ^[Yy]$ ]]; then
        echo "  - HTTPS:  https://$domain"
    fi
fi
echo ""
echo "Default Admin Login:"
echo "  Username: $DEFAULT_ADMIN_USER"
echo "  Password: $DEFAULT_ADMIN_PASS"
echo ""
echo "IMPORTANT - Segera lakukan setelah login:"
echo "  1. Ganti password admin di halaman User Management"
echo "  2. Update RTSP URL camera di halaman Settings"
echo "  3. Test koneksi camera"
echo ""
echo "FILE LOKASI:"
echo "  - Aplikasi: $APP_DIR"
echo "  - Logs: /var/log/cctv-guardian/"
echo "  - Recordings: $APP_DIR/recordings/"
echo "  - Config: $APP_DIR/.env"
echo ""
echo "PERINTAH PERAWATAN:"
echo "  - Lihat logs: tail -f /var/log/cctv-guardian/access.log"
echo "  - Restart app: supervisorctl restart cctv-guardian"
echo "  - Stop app: supervisorctl stop cctv-guardian"
echo "  - Start app: supervisorctl start cctv-guardian"
echo "  - Status: supervisorctl status cctv-guardian"
echo "  - Cek logs nginx: tail -f /var/log/nginx/error.log"
echo ""
echo "TROUBLESHOOTING:"
echo "  - Jika app crash: cek logs di /var/log/cctv-guardian/error.log"
echo "  - Jika nginx error: nginx -t && systemctl restart nginx"
echo "  - Jika tidak bisa akses: cek firewall (ufw status)"
echo ""

read -p "Tekan Enter untuk selesai..."
