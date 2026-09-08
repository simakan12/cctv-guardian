# ============================================
# Step 11: Setup Nginx (Reverse Proxy)
# ============================================
SEC "11: Setup Nginx (Reverse Proxy - Optional)"
echo ""
echo "Pilih setup Nginx:"
echo "  1) Ya - setup reverse proxy + HTTPS otomatis"
echo "  2) Tidak - jalanin langsung di port $APP_PORT"
echo ""
read -p "Pilihan [1/2]: " NGINX_CHOICE

if [ "$NGINX_CHOOSE" = "1" ] || [ "$NGINX_CHOICE" = "y" ] || [ "$NGINX_CHOICE" = "Y" ]; then
    read -p "Masukkan domain (contoh: cctv. domain.com): " NGINX_DOMAIN
    [ -z "$NGINX_DOMAIN" ] && ERR "Domain kosong!" && exit 1

    cat > /etc/nginx/sites-available/${APP_NAME} << NXEOF
server {
    listen 80;
    server_name ${NGINX_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 0;
    }

    location /static/ {
        alias ${APP_DIR}/backend/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
NXEOF

    ln -sf /etc/nginx/sites-available/${APP_NAME} /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl restart nginx
    OK "Nginx config created for ${NGINX_DOMAIN}"

    echo ""
    read -p "Setup Let's Encrypt SSL? (y/n): " SSL_CHOICE
    if [ "$SSL_CHOICE" = "y" ] || [ "$SSL_CHOICE" = "Y" ]; then
        apt-get install -y certbot python3-certbot-nginx -qq
        certbot --nginx -d ${NGINX_DOMAIN} --non-interactive --agree-tos --email ${ADMIN_EMAIL} --redirect
        OK "SSL installed for ${NGINX_DOMAIN}"
    fi
    WEB_URL="https://${NGINX_DOMAIN}"
else
    WEB_URL="http://$(hostname -I | awk '{print $1}'):${APP_PORT}"
    OK "Nginx dilewati. Akses: ${WEB_URL}"
fi

# ============================================
# Step 12: Setup Firewall (UFW)
# ============================================
SEC "12: Setup Firewall (UFW - Optional)"
echo ""
read -p "Setup UFW firewall? (y/n): " UFW_CHOICE
if [ "$UFW_CHOOSE" = "y" ] || [ "$UFW_CHOICE" = "Y" ]; then
    ufw --force enable
    ufw allow 22/tcp comment "SSH"
    ufw allow ${APP_PORT}/tcp comment "CCTV Guardian"
    if [ "$NGINX_CHOOSE" = "1" ] || [ "$NGINX_CHOOSE" = "y" ] || [ "$NGINX_CHOOSE" = "Y" ]; then
        ufw allow 'Nginx Full'
    fi
    OK "UFW firewall enabled"
else
    OK "Firewall dilewati"
fi

# ============================================
# Step 13: Setup Supervisor
# ============================================
SEC "13: Setup Supervisor Service"
cat > /etc/supervisor/conf.d/${APP_NAME}.conf << SUPEOF
[program:${APP_NAME}]
command=${APP_DIR}/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port ${APP_PORT}
directory=${APP_DIR}
user=cctvapp
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
stderr_logfile=/var/log/${APP_NAME}/err.log
stdout_logfile=/var/log/${APP_NAME}/out.log
environment=PYTHONUNBUFFERED="1"
SUPEOF

mkdir -p /var/log/${APP_NAME}
chown -R cctvapp:cctvapp /var/log/${APP_NAME} 2>/dev/null || chown -R cctvapp /var/log/${APP_NAME} 2>/dev/null || true
supervisorctl reread
supervisorctl update
OK "Supervisor configured"

# ============================================
# Step 14: Initialize Database
# ============================================
SEC "14: Initialize Database"
source ${APP_DIR}/venv/bin/activate
cd ${APP_DIR}
python3 -c "
from backend.database import Base, engine
Base.metadata.create_all(bind=engine)
print('Database tables created')
" 2>&1 || ERR "Gagal init database"
OK "Database initialized"

# ============================================
# Step 15: Create Admin User
# ============================================
SEC "15: Create Admin User"
ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
source ${APP_DIR}/venv/bin/activate
cd ${APP_DIR}
python3 -c "
import sys
sys.path.insert(0, '${APP_DIR}')
from backend.database import SessionLocal
from backend.models import User
from backend.auth import hash_password

db = SessionLocal()
existing = db.query(User).filter(User.username == 'admin').first()
if existing:
    print('Admin user sudah ada')
    print(f'Username: admin')
    print(f'Password: ${ADMIN_PASS} (ganti segera)')
else:
    admin = User(
        username='admin',
        password_hash=hash_password('${ADMIN_PASS}'),
        role='admin',
        is_active=True
    )
    db.add(admin)
    db.commit()
    print('Admin user dibuat')
    print(f'Username: admin')
    print(f'Password: ${ADMIN_PASS} (SIMPAN!)')
db.close()
" 2>&1 || ERR "Gagal buat admin user"
OK "Admin user configured"
ADMIN_PASSWORD="$ADMIN_PASS"

# ============================================
# Step 16: Start Application
# ============================================
SEC "16: Start Application"
sleep 2
supervisorctl start ${APP_NAME}
sleep 3

if supervisorctl status ${APP_NAME} | grep -q "RUNNING"; then
    OK "Aplikasi berjalan!"
    APP_STATUS="running"
else
    WARN "Cek log: supervisorctl status ${APP_NAME}"
    supervisorctl status ${APP_NAME}
    APP_STATUS="unknown"
fi

# ============================================
# Step 17: Create Info File
# ============================================
SEC "17: Buat Info File"
cat > ${APP_DIR}/INFO.txt << INFOEOF
========================================
  CCTV Guardian - Informasi Server
========================================

Tanggal Instalasi: $(date '+%d %B %Y %H:%M:%S WIB')

---

1. AKSES WEB
   URL   : ${WEB_URL}
   Port  : ${APP_PORT}
   Protokol: $(echo $WEB_URL | grep -q https && echo "HTTPS" || echo "HTTP")

2. LOGIN WEB
   Username : admin
   Password : ${ADMIN_PASSWORD}
   ⚠️  Ganti password segera setelah login!

3. SERVICE STATUS
   Cek status  : supervisorctl status ${APP_NAME}
   Start       : supervisorctl start ${APP_NAME}
   Stop        : supervisorctl stop ${APP_NAME}
   Restart     : supervisorctl restart ${APP_NAME}
   Lihat log   : tail -f /var/log/${APP_NAME}/out.log
   Lihat error : tail -f /var/log/${APP_NAME}/err.log

4. LOG FILE
   Aplikasi    : ${APP_DIR}/logs/app.log
   Supervisor  : /var/log/${APP_NAME}/out.log
   Nginx       : /var/log/nginx/${APP_NAME}-access.log (kalau setup Nginx)
   Error Nginx : /var/log/nginx/${APP_NAME}-error.log (kalau setup Nginx)

5. TROUBLESHOOTING
   - Aplikasi mati: supervisorctl restart ${APP_NAME}
   - Port bermasalah: cek netstat -tlnp | grep ${APP_PORT}
   - Database error: cek ${APP_DIR}/logs/app.log
   - Nginx error: nginx -t && tail /var/log/nginx/error.log
   - Permission: chown -R cctvapp:cctvapp ${APP_DIR}

6. DIRECTORY
   Aplikasi    : ${APP_DIR}
   Virtual Env : ${APP_DIR}/venv
   Database    : ${APP_DIR}/data.db
   Recordings  : ${APP_DIR}/recordings/
   Log         : ${APP_DIR}/logs/
   Config      : ${APP_DIR}/.env
   Info File   : ${APP_DIR}/INFO.txt

7. UPDATE APLIKASI
   cd ${APP_DIR}
   git pull  (kalau pakai git)
   supervisorctl restart ${APP_NAME}

8. BACKUP DATABASE
   cp ${APP_DIR}/data.db ${APP_DIR}/backups/data_$(date +%Y%m%d_%H%M%S).db

========================================
  Installasi Selesai!
========================================
INFOEOF

OK "Info file created: ${APP_DIR}/INFO.txt"

# ============================================
# Step 18: Setup MOTD (Message of the Day)
# ============================================
SEC "18: Setup MOTD (Welcome Message di SSH)"
cat > /etc/update-motd.d/00-cctv-guardian << 'MOTDEOF'
#!/bin/sh
echo ""
echo "============================================"
echo "  CCTV Guardian - Server Info"
echo "============================================"
echo ""
echo "URL   : http://SERVER_IP:8000"
echo "User  : admin"
echo "Pass  : (lihat /opt/cctv-guardian/INFO.txt)"
echo ""
echo "Service: supervisorctl status cctv-guardian"
echo "Log    : tail -f /opt/cctv-guardian/logs/app.log"
echo ""
MOTDEOF
chmod +x /etc/update-motd.d/00-cctv-guardian
OK "MOTD configured"

# ============================================
# FINAL SUMMARY
# ============================================
clear
echo ""
echo "============================================"
echo "  CCTV Guardian - INSTALLASI SELESAI"
echo "============================================"
echo ""
echo "  Akses Web : ${WEB_URL}"
echo "  Port       : ${APP_PORT}"
echo ""
echo "  Username : admin"
echo "  Password : ${ADMIN_PASSWORD}"
echo ""
echo "  File Info : ${APP_DIR}/INFO.txt"
echo ""
echo "  Cek service : supervisorctl status cctv-guardian"
echo "  Lihat log   : tail -f /var/log/cctv-guardian/out.log"
echo ""
echo " ➤  Buka browser, akses ${WEB_URL}"
echo " ➤  Login dengan username: admin"
echo " ➤  Password ada di INFO.txt"
echo ""
echo "============================================"
