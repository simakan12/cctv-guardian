#!/bin/bash

echo "=================================================================="
echo "[+] MENAMBAHKAN FITUR SPEED 0.75x, 16x, DAN 32x KE PLAYER..."
echo "=================================================================="

cd /opt/cctv-guardian

cat << 'EOF' > patch_speed.py
import re

filepath = "backend/templates/recordings.html"
with open(filepath, "r") as f:
    html = f.read()

# Target tag dropdown yang lama
old_select = '<select id="sCtrl" class="form-select form-select-sm fw-bold border-secondary" style="width: 150px; background-color: var(--bs-body-bg); color: var(--bs-body-color);" onchange="cs()"><option value="0.5">0.5x</option><option value="1" selected>1x Normal</option><option value="2">2x</option><option value="4">4x</option><option value="8">8x</option></select>'

# Menu dropdown baru dengan tambahan 0.75, 16, dan 32
new_select = '<select id="sCtrl" class="form-select form-select-sm fw-bold border-secondary" style="width: 150px; background-color: var(--bs-body-bg); color: var(--bs-body-color);" onchange="cs()"><option value="0.5">0.5x</option><option value="0.75">0.75x</option><option value="1" selected>1x Normal</option><option value="2">2x</option><option value="4">4x</option><option value="8">8x</option><option value="16">16x</option><option value="32">32x</option></select>'

if old_select in html:
    html = html.replace(old_select, new_select)
    with open(filepath, "w") as f:
        f.write(html)
    print("[V] Opsi speed 0.75x, 16x, dan 32x berhasil ditambahkan dengan mulus!")
else:
    # Metode fallback (sapu jagat) kalau format spasinya agak beda
    html = re.sub(r'<select id="sCtrl".*?</select>', new_select, html)
    with open(filepath, "w") as f:
        f.write(html)
    print("[V] Opsi speed berhasil disuntik ulang pakai metode paksa!")
EOF

python3 patch_speed.py
rm patch_speed.py

echo "[+] Merestart Web VMS untuk menerapkan UI baru..."
supervisorctl restart cctv-guardian_web

echo "=================================================================="
echo "[+] SELESAI! Silakan buka menu Riwayat Rekaman."
echo "=================================================================="