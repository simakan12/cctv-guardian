#!/bin/bash

echo "=================================================================="
echo "    [+] CCTV GUARDIAN - THE ULTIMATE MASTER INSTALLER [+]         "
echo "=================================================================="
echo "[+] Membersihkan sisa-sisa proses lama..."
killall -9 ffmpeg 2>/dev/null
pkill -9 -f uvicorn 2>/dev/null
systemctl stop supervisor 2>/dev/null

echo "[+] Membangun ulang struktur direktori utama..."
mkdir -p /opt/cctv-guardian/backend/templates
mkdir -p /opt/cctv-guardian/backend/static/recordings
mkdir -p /opt/cctv-guardian/backend/static/hls
cd /opt/cctv-guardian

echo "[+] Menginstall paket dependensi (Mohon tunggu sebentar)..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq python3-pip python3-sqlalchemy python3-opencv python3-fastapi python3-uvicorn python3-jinja2 python3-multipart python3-requests supervisor ffmpeg curl >/dev/null 2>&1

echo ""
echo "------------------------------------------------------------------"
echo "KONFIGURASI FOLDER LIVE STREAM (HLS)"
echo "Tekan ENTER jika ingin menggunakan folder SSD default bawaan,"
echo "atau ketik path custom lu (DILARANG PAKAI RAM DISK /dev/shm!)."
echo "------------------------------------------------------------------"
read -p "Masukkan path HLS [Default: /opt/cctv-guardian/backend/static/hls]: " INPUT_HLS_PATH

if [ -z "$INPUT_HLS_PATH" ]; then
    HLS_PATH="/opt/cctv-guardian/backend/static/hls"
else
    HLS_PATH="$INPUT_HLS_PATH"
fi
mkdir -p "$HLS_PATH"
echo "[*] Path HLS dikunci ke: $HLS_PATH"

echo "[+] Membangun fondasi Database..."
touch backend/__init__.py

cat << 'EOF' > backend/database.py
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.ext.declarative import declarative_base

SQLALCHEMY_DATABASE_URL = "sqlite:///./sql_app.db"
engine = create_engine(SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()
EOF

cat << 'EOF' > backend/models.py
from sqlalchemy import Column, Integer, String, Boolean
from backend.database import Base

class Camera(Base):
    __tablename__ = "cameras"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, index=True)
    rtsp_url = Column(String)
    ai_enabled = Column(Boolean, default=False)
    ai_sensitivity = Column(Integer, default=50)
    record_mode = Column(String, default="none")
    storage_type = Column(String, default="local")
    live_quality = Column(String, default="360p")
    telegram_alert = Column(Boolean, default=False)

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True, index=True)
    username = Column(String, unique=True, index=True)
    password = Column(String)
    role = Column(String, default="tamu")
    is_active = Column(Boolean, default=True)

class Setting(Base):
    __tablename__ = "settings"
    id = Column(Integer, primary_key=True, index=True)
    key = Column(String, unique=True, index=True)
    value = Column(String)
EOF

echo "[+] Membangun Mesin Backend Utama (main.py)..."
cat << 'EOF' > backend/main.py
import cv2, time, os, shutil, threading, subprocess, requests
from datetime import datetime
from fastapi import FastAPI, Depends, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session
from sqlalchemy import text
from backend.database import SessionLocal, engine
from backend.models import Base, Camera, User, Setting
from starlette.middleware.sessions import SessionMiddleware

Base.metadata.create_all(bind=engine)

HLS_PATH = "__HLS_CUSTOM_PATH__"
os.makedirs(HLS_PATH, exist_ok=True)

def run_migrations():
    with engine.connect() as conn:
        try: conn.execute(text("ALTER TABLE cameras ADD COLUMN telegram_alert BOOLEAN DEFAULT 0")); conn.commit()
        except: pass
run_migrations()

def get_storage_path():
    db = SessionLocal()
    s = db.query(Setting).filter(Setting.key == "storage_path").first()
    db.close()
    return s.value if s and s.value else "/opt/cctv-guardian/backend/static/recordings"

def get_max_storage_gb():
    db = SessionLocal()
    s = db.query(Setting).filter(Setting.key == "max_storage_gb").first()
    db.close()
    return int(s.value) if s and s.value.isdigit() else 20

def cleanup_old_recordings():
    try:
        folder_path = get_storage_path()
        max_bytes = get_max_storage_gb() * 1024 * 1024 * 1024
        files = [os.path.join(folder_path, f) for f in os.listdir(folder_path) if f.endswith(".mp4")]
        total_size = sum(os.path.getsize(f) for f in files)
        if total_size > max_bytes:
            files.sort(key=os.path.getmtime)
            for f in files:
                if total_size <= max_bytes: break
                total_size -= os.path.getsize(f)
                os.remove(f)
    except: pass

def send_telegram_msg(token, chat_id, message):
    try:
        url = f"https://api.telegram.org/bot{token}/sendMessage"
        requests.post(url, data={"chat_id": chat_id, "text": message, "parse_mode": "Markdown"}, timeout=5)
    except: pass

active_threads = {}

def process_camera(cam_id):
    hls_dir = os.path.join(HLS_PATH, str(cam_id))
    os.makedirs(hls_dir, exist_ok=True)
    hls_process = None; cap = None; fgbg = None
    motion_timer = 0; recording_process = None; record_start_time = 0
    last_telegram_alert = 0; frame_counter = 0; empty_frames_count = 0
    rtsp_url = ""; ai_enabled = False; record_mode = "none"
    ai_sensitivity = 50; telegram_alert = False; cam_name = f"cam_{cam_id}"

    while True:
        if frame_counter % 20 == 0:
            db = SessionLocal()
            cam = db.query(Camera).filter(Camera.id == cam_id).first()
            if not cam: db.close(); break
            if rtsp_url != "" and cam.rtsp_url != rtsp_url:
                if hls_process: hls_process.kill(); hls_process.wait(); hls_process = None
                if recording_process: recording_process.terminate(); recording_process.wait(); recording_process = None
                if cap: cap.release(); cap = None
                try: shutil.rmtree(hls_dir)
                except: pass
                os.makedirs(hls_dir, exist_ok=True)
            rtsp_url = cam.rtsp_url; ai_enabled = cam.ai_enabled
            record_mode = cam.record_mode; ai_sensitivity = getattr(cam, 'ai_sensitivity', 50)
            telegram_alert = getattr(cam, 'telegram_alert', False)
            cam_name = cam.name.replace(" ", "_").replace("/", "")
            db.close()
        
        ai_required = (ai_enabled or record_mode == 'motion' or telegram_alert)
        frame_counter += 1

        if hls_process is None or hls_process.poll() is not None:
            os.makedirs(hls_dir, exist_ok=True)
            session_id = int(time.time())
            input_flags = ['-rtsp_transport', 'tcp'] if rtsp_url.startswith('rtsp') else ['-reconnect', '1', '-reconnect_at_eof', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '10']
            hls_cmd = ['ffmpeg', '-y', '-fflags', '+genpts'] + input_flags + ['-err_detect', 'ignore_err', '-i', rtsp_url, '-c:v', 'copy', '-an', '-f', 'hls', '-hls_time', '2', '-hls_list_size', '3', '-hls_flags', 'delete_segments', '-hls_segment_filename', f'{hls_dir}/seg_{session_id}_%03d.ts', f'{hls_dir}/index.m3u8']
            hls_log = open(f'{hls_dir}/ffmpeg_hls.log', 'w')
            hls_process = subprocess.Popen(hls_cmd, stdout=hls_log, stderr=subprocess.STDOUT)

        motion_detected = False
        if ai_required:
            if cap is None:
                cap = cv2.VideoCapture(rtsp_url, cv2.CAP_FFMPEG)
                cap.set(cv2.CAP_PROP_BUFFERSIZE, 2)
            ret, frame = cap.read()
            if not ret or frame is None:
                empty_frames_count += 1
                if empty_frames_count > 50: cap.release(); cap = None; empty_frames_count = 0
                time.sleep(0.05)
            else:
                empty_frames_count = 0; frame_ai = cv2.resize(frame, (640, 360))
                if fgbg is None: fgbg = cv2.createBackgroundSubtractorMOG2(history=500, varThreshold=16, detectShadows=False)
                fgmask = fgbg.apply(cv2.GaussianBlur(cv2.cvtColor(frame_ai, cv2.COLOR_BGR2GRAY), (5, 5), 0))
                contours, _ = cv2.findContours(fgmask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
                for c in contours:
                    if cv2.contourArea(c) > (101 - ai_sensitivity) * 20: motion_detected = True; break
        else:
            if cap is not None: cap.release(); cap = None
            time.sleep(0.5)

        if motion_detected:
            motion_timer = 200
            if telegram_alert and (time.time() - last_telegram_alert > 60):
                db_t = SessionLocal()
                t_token = db_t.query(Setting).filter(Setting.key == "telegram_token").first()
                t_chat = db_t.query(Setting).filter(Setting.key == "telegram_chat_id").first()
                db_t.close()
                if t_token and t_chat and t_token.value and t_chat.value:
                    threading.Thread(target=send_telegram_msg, args=(t_token.value, t_chat.value, f"🚨 *ALARM CCTV GUARDIAN*\nPergerakan terdeteksi: *{cam_name}*"), daemon=True).start()
                last_telegram_alert = time.time()

        should_record = True if record_mode == '24_7' else (True if record_mode == 'motion' and motion_timer > 0 else False)
        if record_mode == 'motion' and motion_timer > 0: motion_timer -= 1

        if should_record:
            if recording_process is None:
                os.makedirs(get_storage_path(), exist_ok=True)
                filepath = os.path.join(get_storage_path(), f"{cam_name}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.mp4")
                input_flags = ['-rtsp_transport', 'tcp'] if rtsp_url.startswith('rtsp') else ['-reconnect', '1', '-reconnect_at_eof', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '10']
                cmd = ['ffmpeg', '-y', '-fflags', '+genpts'] + input_flags + ['-err_detect', 'ignore_err', '-i', rtsp_url, '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '28', '-r', '10', '-pix_fmt', 'yuv420p', '-vsync', '1', '-movflags', 'frag_keyframe+empty_moov', '-an', '-t', '900', filepath]
                rec_log = open(f'{hls_dir}/ffmpeg_record.log', 'w')
                recording_process = subprocess.Popen(cmd, stdout=rec_log, stderr=subprocess.STDOUT)
                record_start_time = time.time()
            else:
                if recording_process.poll() is not None or time.time() - record_start_time >= 1800:
                    if recording_process.poll() is None: recording_process.terminate(); recording_process.wait()
                    recording_process = None; cleanup_old_recordings()
        else:
            if recording_process is not None:
                recording_process.terminate(); recording_process.wait(); recording_process = None; cleanup_old_recordings()

    if recording_process: recording_process.terminate(); recording_process.wait()
    if hls_process: hls_process.kill(); hls_process.wait()
    if cap: cap.release()
    try: shutil.rmtree(hls_dir)
    except: pass
    time.sleep(3)

def seed_admin():
    db = SessionLocal()
    if not db.query(User).filter(User.username == 'admin').first(): db.add(User(username='admin', password='adminpassword', role='admin', is_active=True))
    if not db.query(Setting).filter(Setting.key == 'max_storage_gb').first(): db.add(Setting(key='max_storage_gb', value='20'))
    if not db.query(Setting).filter(Setting.key == 'storage_path').first(): db.add(Setting(key='storage_path', value='/opt/cctv-guardian/backend/static/recordings'))
    db.commit(); db.close()

app = FastAPI(title="CCTV Guardian")
app.add_middleware(SessionMiddleware, secret_key="cctv-guardian-secret-final")

app.mount("/static", StaticFiles(directory="backend/static"), name="static")
app.mount("/hls", StaticFiles(directory=HLS_PATH), name="hls")
templates = Jinja2Templates(directory="backend/templates")

@app.on_event("startup")
def startup_event():
    seed_admin()
    db = SessionLocal()
    for cam in db.query(Camera).all():
        t = threading.Thread(target=process_camera, args=(cam.id,), daemon=True)
        t.start(); active_threads[cam.id] = t
    db.close()

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

@app.get("/play_video/{filename}")
def play_video(filename: str, request: Request):
    if "user_id" not in request.session: return HTMLResponse(status_code=403)
    file_path = os.path.join(get_storage_path(), filename)
    if os.path.exists(file_path): return FileResponse(file_path, media_type="video/mp4")
    return HTMLResponse(status_code=404, content="File Tidak Ditemukan")

@app.get("/", response_class=HTMLResponse)
def root(request: Request): return RedirectResponse(url="/dashboard", status_code=303)

@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request): return templates.TemplateResponse("login.html", {"request": request})

@app.post("/login")
def login(request: Request, username: str=Form(...), password: str=Form(...), db: Session=Depends(get_db)):
    user = db.query(User).filter(User.username == username.strip()).first()
    if user and password.strip() == user.password:
        request.session["user_id"] = user.id; request.session["role"] = user.role
        return RedirectResponse(url="/dashboard", status_code=303)
    return templates.TemplateResponse("login.html", {"request": request, "error": "Username atau Password Salah!"})

@app.get("/logout")
def logout(request: Request): request.session.clear(); return RedirectResponse(url="/login", status_code=303)

@app.get("/dashboard", response_class=HTMLResponse)
def dashboard(request: Request, db: Session=Depends(get_db)):
    if "user_id" not in request.session: return RedirectResponse(url="/login", status_code=303)
    def get_val(key, default):
        s = db.query(Setting).filter(Setting.key == key).first()
        return s.value if s else default
    return templates.TemplateResponse("dashboard.html", {"request": request, "cameras": db.query(Camera).all(), "auto_rotate": get_val("auto_rotate", "false"), "rotate_interval": int(get_val("rotate_interval", "10")), "grid_size": int(get_val("grid_size", "6"))})

@app.get("/cameras", response_class=HTMLResponse)
def cameras_page(request: Request, db: Session=Depends(get_db)):
    if request.session.get("role") != "admin": return RedirectResponse(url="/dashboard", status_code=303)
    return templates.TemplateResponse("cameras.html", {"request": request, "cameras": db.query(Camera).all()})

@app.post("/cameras")
def add_camera(request: Request, name: str=Form(...), rtsp_url: str=Form(...), ai_enabled: bool=Form(False), ai_sensitivity: int=Form(50), record_mode: str=Form("none"), telegram_alert: bool=Form(False), db: Session=Depends(get_db)):
    if request.session.get("role") != "admin": return RedirectResponse(url="/dashboard", status_code=303)
    new_cam = Camera(name=name, rtsp_url=rtsp_url, ai_enabled=ai_enabled, ai_sensitivity=ai_sensitivity, record_mode=record_mode, telegram_alert=telegram_alert)
    db.add(new_cam); db.commit()
    t = threading.Thread(target=process_camera, args=(new_cam.id,), daemon=True); t.start(); active_threads[new_cam.id] = t
    return RedirectResponse(url="/cameras", status_code=303)

@app.post("/cameras/edit/{camera_id}")
def edit_camera(camera_id: int, request: Request, name: str=Form(...), rtsp_url: str=Form(...), ai_enabled: bool=Form(False), ai_sensitivity: int=Form(50), record_mode: str=Form("none"), telegram_alert: bool=Form(False), db: Session=Depends(get_db)):
    if request.session.get("role") != "admin": return RedirectResponse(url="/dashboard", status_code=303)
    cam = db.query(Camera).filter(Camera.id == camera_id).first()
    if cam:
        cam.name = name; cam.rtsp_url = rtsp_url; cam.ai_enabled = ai_enabled; cam.ai_sensitivity = ai_sensitivity; cam.record_mode = record_mode; cam.telegram_alert = telegram_alert
        db.commit()
    return RedirectResponse(url="/cameras", status_code=303)

@app.post("/cameras/delete/{camera_id}")
def delete_camera(camera_id: int, request: Request, db: Session=Depends(get_db)):
    if request.session.get("role") != "admin": return RedirectResponse(url="/dashboard", status_code=303)
    cam = db.query(Camera).filter(Camera.id == camera_id).first()
    if cam: db.delete(cam); db.commit()
    return RedirectResponse(url="/cameras", status_code=303)

@app.get("/recordings", response_class=HTMLResponse)
def recordings_page(request: Request):
    if request.session.get("role") != "admin": return RedirectResponse(url="/dashboard", status_code=303)
    files_data = []; cams_list = set(); folder_path = get_storage_path()
    if os.path.exists(folder_path):
        for f in sorted([f for f in os.listdir(folder_path) if f.endswith(".mp4")], reverse=True):
            try:
                name_part = f[:-20]; date_part = f[-19:-11]; time_part = f[-10:-4]
                cams_list.add(name_part)
                files_data.append({"filename": f, "cam_name": name_part, "date": f"{date_part[:4]}-{date_part[4:6]}-{date_part[6:8]}", "time": f"{time_part[:2]}:{time_part[2:4]}:00", "hour": time_part[:2], "minute": time_part[2:4]})
            except: pass
    return templates.TemplateResponse("recordings.html", {"request": request, "files": files_data, "cameras": sorted(list(cams_list)), "storage_path": folder_path})

@app.get("/settings", response_class=HTMLResponse)
def settings_page(request: Request, db: Session=Depends(get_db)):
    if request.session.get("role") != "admin": return RedirectResponse(url="/dashboard", status_code=303)
    def get_val(key, default):
        s = db.query(Setting).filter(Setting.key == key).first()
        return s.value if s else default
    return templates.TemplateResponse("settings.html", {"request": request, "current_storage": int(get_val("max_storage_gb", "20")), "storage_path": get_val("storage_path", "/opt/cctv-guardian/backend/static/recordings"), "telegram_token": get_val("telegram_token", ""), "telegram_chat_id": get_val("telegram_chat_id", ""), "auto_rotate": get_val("auto_rotate", "false"), "rotate_interval": int(get_val("rotate_interval", "10")), "grid_size": int(get_val("grid_size", "6"))})

@app.post("/settings/save")
def save_settings(request: Request, max_storage_gb: str=Form(...), storage_path: str=Form(...), telegram_token: str=Form(""), telegram_chat_id: str=Form(""), auto_rotate: str=Form("false"), rotate_interval: str=Form("10"), grid_size: str=Form("6"), db: Session=Depends(get_db)):
    if request.session.get("role") != "admin": return RedirectResponse(url="/dashboard", status_code=303)
    def save_setting(k, v):
        s = db.query(Setting).filter(Setting.key == k).first()
        if not s: db.add(Setting(key=k, value=v))
        else: s.value = v
    save_setting("max_storage_gb", max_storage_gb); save_setting("storage_path", storage_path.strip()); save_setting("telegram_token", telegram_token.strip()); save_setting("telegram_chat_id", telegram_chat_id.strip()); save_setting("auto_rotate", auto_rotate); save_setting("rotate_interval", rotate_interval); save_setting("grid_size", grid_size)
    db.commit(); os.makedirs(storage_path.strip(), exist_ok=True)
    return RedirectResponse(url="/settings", status_code=303)

@app.get("/users", response_class=HTMLResponse)
def users_page(request: Request, db: Session=Depends(get_db)):
    if request.session.get("role") != "admin": return RedirectResponse(url="/dashboard", status_code=303)
    return templates.TemplateResponse("users.html", {"request": request, "users": db.query(User).all()})

@app.post("/users")
def add_user(request: Request, username: str=Form(...), password: str=Form(...), role: str=Form("tamu"), db: Session=Depends(get_db)):
    if request.session.get("role") != "admin": return RedirectResponse(url="/dashboard", status_code=303)
    if not db.query(User).filter(User.username == username).first(): db.add(User(username=username, password=password, role=role)); db.commit()
    return RedirectResponse(url="/users", status_code=303)

@app.post("/users/edit/{user_id}")
def edit_user(user_id: int, request: Request, username: str=Form(...), password: str=Form(""), role: str=Form("tamu"), db: Session=Depends(get_db)):
    if request.session.get("role") != "admin": return RedirectResponse(url="/dashboard", status_code=303)
    user = db.query(User).filter(User.id == user_id).first()
    if user:
        user.username = username; user.role = role
        if password.strip(): user.password = password
        db.commit()
    return RedirectResponse(url="/users", status_code=303)

@app.post("/users/delete/{user_id}")
def delete_user(user_id: int, request: Request, db: Session=Depends(get_db)):
    if request.session.get("role") != "admin": return RedirectResponse(url="/dashboard", status_code=303)
    user = db.query(User).filter(User.id == user_id).first()
    if user and user.username != 'admin': db.delete(user); db.commit()
    return RedirectResponse(url="/users", status_code=303)
EOF

sed -i "s|__HLS_CUSTOM_PATH__|$HLS_PATH|g" backend/main.py

echo "[+] Membangun UI Frontend Enterprise..."
# ==============================================================================
# UI 1. LOGIN.HTML
# ==============================================================================
cat << 'EOF' > backend/templates/login.html
<!DOCTYPE html><html data-bs-theme="dark"><head><meta charset="utf-8"><title>Login - CCTV Guardian</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.1/font/bootstrap-icons.css"></head>
<body class="bg-body d-flex align-items-center justify-content-center" style="height: 100vh;">
    <div class="card shadow-lg border-secondary" style="width: 400px; border-radius: 12px;">
        <div class="card-body p-5 text-center">
            <i class="bi bi-shield-lock-fill text-info" style="font-size: 3.5rem;"></i><h3 class="fw-bold mt-2 text-white">CCTV Guardian</h3><p class="text-muted small">Panel Autentikasi Sistem</p>
            {% if error %}<div class="alert alert-danger py-2 small fw-bold">{{ error }}</div>{% endif %}
            <form method="post" action="/login" class="text-start">
                <div class="mb-3"><label class="form-label small fw-bold text-info"><i class="bi bi-person-fill"></i> Username</label><input type="text" name="username" class="form-control bg-dark text-white border-secondary" required autofocus></div>
                <div class="mb-4"><label class="form-label small fw-bold text-info"><i class="bi bi-key-fill"></i> Password</label><input type="password" name="password" class="form-control bg-dark text-white border-secondary" required></div>
                <button type="submit" class="btn btn-info w-100 fw-bold text-white py-2"><i class="bi bi-box-arrow-in-right"></i> MASUK SYSTEM</button>
            </form>
        </div>
    </div>
</body></html>
EOF

# ==============================================================================
# UI 2. DASHBOARD.HTML (DENGAN HLS AUTO-RETRY)
# ==============================================================================
cat << 'EOF' > backend/templates/dashboard.html
<!DOCTYPE html><html data-bs-theme="dark"><head><meta charset="utf-8"><title>Dashboard - CCTV Guardian</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.1/font/bootstrap-icons.css"><script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script><style>.cam-header { background-color: var(--bs-tertiary-bg); border: 2px solid var(--bs-border-color); border-bottom: none; border-radius: 8px 8px 0 0; padding: 8px 12px; display: flex; justify-content: space-between; align-items: center; } .video-container { width: 100%; aspect-ratio: 16/9; background-color: #000; position: relative; border-radius: 0 0 8px 8px; overflow: hidden; border: 2px solid var(--bs-border-color); box-shadow: 0 4px 6px rgba(0,0,0,0.3); } video { width: 100%; height: 100%; object-fit: contain; background-color: #000; } .btn-fullscreen { position: absolute; bottom: 10px; right: 10px; z-index: 10; opacity: 0.5; transition: 0.3s; } .btn-fullscreen:hover { opacity: 1; }</style></head>
<body class="bg-body text-body">
    <nav class="navbar navbar-expand-lg bg-body-tertiary border-bottom shadow-sm mb-4"><div class="container-fluid"><a class="navbar-brand fw-bold text-info" href="#"><i class="bi bi-shield-lock"></i> CCTV Guardian</a><button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav"><span class="navbar-toggler-icon"></span></button>
        <div class="collapse navbar-collapse" id="navbarNav">
          <ul class="navbar-nav me-auto">
            <li class="nav-item"><a class="nav-link active" href="/dashboard"><i class="bi bi-grid-fill"></i> Dashboard</a></li>
            {% if request.session.get("role") == "admin" %}
            <li class="nav-item"><a class="nav-link" href="/cameras"><i class="bi bi-camera-video"></i> Kelola Kamera</a></li><li class="nav-item"><a class="nav-link" href="/recordings"><i class="bi bi-film"></i> Riwayat Rekaman</a></li><li class="nav-item"><a class="nav-link text-warning" href="/settings"><i class="bi bi-gear-fill"></i> Pengaturan</a></li><li class="nav-item"><a class="nav-link text-success fw-bold" href="/users"><i class="bi bi-people-fill"></i> Pengguna</a></li>
            {% endif %}
          </ul>
          <div class="d-flex align-items-center mt-2 mt-lg-0"><button class="btn btn-sm btn-outline-secondary me-3" onclick="toggleTheme()"><span id="theme-icon"><i class="bi bi-brightness-high-fill"></i></span> Mode</button><a href="/logout" class="btn btn-outline-danger btn-sm"><i class="bi bi-box-arrow-right"></i> Logout</a></div>
        </div></div></nav>
    <div class="container-fluid px-4"><h4 class="mb-4 border-bottom pb-2"><i class="bi bi-display"></i> Live Monitor</h4>
        <div class="row g-4" id="video-grid">
            {% for cam in cameras %}
            <div class="col-12 col-md-6 col-lg-4 cam-card d-none" id="card_{{ cam.id }}">
                <div class="cam-header"><span class="fw-bold text-info text-truncate" style="max-width: 70%;"><i class="bi bi-camera"></i> {{ cam.name }}</span><div>{% if cam.record_mode == '24_7' %}<span class="badge bg-danger">REC</span>{% endif %}{% if cam.record_mode == 'motion' %}<span class="badge bg-primary">AI STBY</span>{% endif %}</div></div>
                <div class="video-container"><video id="video_{{ cam.id }}" autoplay muted playsinline></video><button class="btn btn-sm btn-dark btn-fullscreen" onclick="toggleFS('video_{{ cam.id }}')"><i class="bi bi-arrows-fullscreen"></i></button></div>
            </div>
            {% else %}<div class="col-12 text-center text-muted mt-5"><i class="bi bi-camera-video-off" style="font-size: 3rem;"></i><h5 class="mt-3">Belum ada kamera aktif.</h5></div>{% endfor %}
        </div>
        {% if cameras %}
        <div class="d-flex justify-content-between align-items-center mt-4 p-3 bg-body-tertiary rounded shadow-sm border"><button class="btn btn-info fw-bold text-white" onclick="prevPage()"><i class="bi bi-arrow-left-circle"></i> Mundur</button><div class="text-center"><span id="page-indicator" class="fw-bold fs-5 text-info">Halaman 1</span>{% if auto_rotate == 'true' %}<div class="small text-muted"><i class="bi bi-arrow-repeat"></i> Auto-Rotate Aktif ({{ rotate_interval }}s)</div>{% endif %}</div><button class="btn btn-info fw-bold text-white" onclick="nextPage()">Maju <i class="bi bi-arrow-right-circle"></i></button></div>
        {% endif %}
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        const cameras = [ {% for cam in cameras %} { id: {{cam.id}}, hls: null, watchdog: null, lastTime: 0, stuckCount: 0 }, {% endfor %} ];
        const gridSize = {{ grid_size }}; const autoRotate = "{{ auto_rotate }}" === "true"; const rotateInterval = {{ rotate_interval }} * 1000;
        let currentPage = 1; let totalPages = Math.ceil(cameras.length / gridSize) || 1; let rotateTimer = null;
        function renderPage(page) {
            cameras.forEach(cam => { if (cam.hls) { cam.hls.destroy(); cam.hls = null; } if (cam.watchdog) { clearInterval(cam.watchdog); cam.watchdog = null; } let c = document.getElementById('card_' + cam.id); if(c) c.classList.add('d-none'); });
            let visibleCams = cameras.slice((page - 1) * gridSize, page * gridSize);
            visibleCams.forEach(cam => {
                let card = document.getElementById('card_' + cam.id); if(card) card.classList.remove('d-none');
                let video = document.getElementById('video_' + cam.id); let source = '/hls/' + cam.id + '/index.m3u8?cb=' + new Date().getTime();
                if (Hls.isSupported()) {
                    let hls = new Hls({ maxBufferLength: 5, liveSyncDurationCount: 2, maxLiveSyncPlaybackRate: 2 });
                    hls.loadSource(source); hls.attachMedia(video);
                    hls.on(Hls.Events.MANIFEST_PARSED, () => video.play().catch(()=>{}));
                    hls.on(Hls.Events.ERROR, function(e, data) {
                        if (data.fatal) {
                            if (data.type === Hls.ErrorTypes.NETWORK_ERROR) { setTimeout(() => { hls.startLoad(); }, 2000); } 
                            else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) { hls.recoverMediaError(); } 
                            else { hls.destroy(); }
                        }
                    });
                    cam.hls = hls; 
                    cam.watchdog = setInterval(() => {
                        if (video.readyState >= 2 && !video.paused) {
                            if (cam.lastTime === video.currentTime) { cam.stuckCount++; if (cam.stuckCount >= 4) { hls.startLoad(); if(video.paused) video.play().catch(e=>{}); cam.stuckCount = 0; }
                            } else { cam.lastTime = video.currentTime; cam.stuckCount = 0; }
                        }
                    }, 1000);
                } else if (video.canPlayType('application/vnd.apple.mpegurl')) { video.src = source; video.play(); }
            });
            let ind = document.getElementById('page-indicator'); if(ind) ind.innerText = `Halaman ${page} dari ${totalPages}`;
        }
        function prevPage() { currentPage = (currentPage > 1) ? currentPage - 1 : totalPages; renderPage(currentPage); resetRotate(); }
        function nextPage() { currentPage = (currentPage < totalPages) ? currentPage + 1 : 1; renderPage(currentPage); resetRotate(); }
        function resetRotate() { if (autoRotate && totalPages > 1) { clearInterval(rotateTimer); rotateTimer = setInterval(nextPage, rotateInterval); } }
        function toggleFS(id) { let el = document.getElementById(id); if(el.requestFullscreen) el.requestFullscreen(); }
        function toggleTheme() { const html = document.documentElement; const newTheme = html.getAttribute('data-bs-theme') === 'dark' ? 'light' : 'dark'; html.setAttribute('data-bs-theme', newTheme); localStorage.setItem('theme', newTheme); document.getElementById('theme-icon').innerHTML = newTheme === 'dark' ? '<i class="bi bi-brightness-high-fill"></i>' : '<i class="bi bi-moon-fill"></i>'; }
        document.addEventListener("DOMContentLoaded", () => { const savedTheme = localStorage.getItem('theme') || 'dark'; document.documentElement.setAttribute('data-bs-theme', savedTheme); let ti = document.getElementById('theme-icon'); if(ti) ti.innerHTML = savedTheme === 'dark' ? '<i class="bi bi-brightness-high-fill"></i>' : '<i class="bi bi-moon-fill"></i>'; if(cameras.length > 0) { renderPage(1); resetRotate(); } });
    </script>
</body></html>
EOF

# ==============================================================================
# UI 3. CAMERAS.HTML (DENGAN FORM LENGKAP & EDIT)
# ==============================================================================
cat << 'EOF' > backend/templates/cameras.html
<!DOCTYPE html><html data-bs-theme="dark"><head><meta charset="utf-8"><title>Kelola Kamera - CCTV Guardian</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.1/font/bootstrap-icons.css"></head>
<body class="bg-body text-body">
    <nav class="navbar navbar-expand-lg bg-body-tertiary border-bottom shadow-sm mb-4"><div class="container-fluid"><a class="navbar-brand fw-bold text-info" href="#"><i class="bi bi-shield-lock"></i> CCTV Guardian</a><button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav"><span class="navbar-toggler-icon"></span></button>
        <div class="collapse navbar-collapse" id="navbarNav"><ul class="navbar-nav me-auto"><li class="nav-item"><a class="nav-link" href="/dashboard"><i class="bi bi-grid-fill"></i> Dashboard</a></li><li class="nav-item"><a class="nav-link active" href="/cameras"><i class="bi bi-camera-video"></i> Kelola Kamera</a></li><li class="nav-item"><a class="nav-link" href="/recordings"><i class="bi bi-film"></i> Riwayat Rekaman</a></li><li class="nav-item"><a class="nav-link text-warning" href="/settings"><i class="bi bi-gear-fill"></i> Pengaturan</a></li><li class="nav-item"><a class="nav-link text-success fw-bold" href="/users"><i class="bi bi-people-fill"></i> Pengguna</a></li></ul><div class="d-flex align-items-center mt-2 mt-lg-0"><button class="btn btn-sm btn-outline-secondary me-3" onclick="toggleTheme()"><span id="theme-icon"><i class="bi bi-brightness-high-fill"></i></span> Mode</button><a href="/logout" class="btn btn-outline-danger btn-sm"><i class="bi bi-box-arrow-right"></i> Logout</a></div></div></div></nav>
    <div class="container px-4">
        <div class="d-flex justify-content-between align-items-center mb-4 border-bottom pb-2"><h4><i class="bi bi-camera-video"></i> Daftar Kamera Aktif</h4><button class="btn btn-success fw-bold" data-bs-toggle="modal" data-bs-target="#addCamModal"><i class="bi bi-plus-circle"></i> Tambah Kamera</button></div>
        <div class="card shadow-sm border-secondary mb-5"><div class="card-body p-0 table-responsive"><table class="table table-hover table-striped mb-0 align-middle"><thead class="table-dark"><tr><th>ID</th><th>Nama Kamera</th><th>Tautan URL</th><th>Mode Rekaman</th><th>AI</th><th>Telegram</th><th class="text-end">Aksi</th></tr></thead>
            <tbody>
                {% for cam in cameras %}
                <tr><td class="fw-bold">{{ cam.id }}</td><td class="fw-bold text-info">{{ cam.name }}</td><td class="small text-muted text-truncate" style="max-width: 150px;">{{ cam.rtsp_url }}</td>
                    <td>{% if cam.record_mode == '24_7' %}<span class="badge bg-danger">24 Jam</span>{% elif cam.record_mode == 'motion' %}<span class="badge bg-primary">AI</span>{% else %}<span class="badge bg-secondary">Live Saja</span>{% endif %}</td>
                    <td>{% if cam.ai_enabled %}<span class="badge bg-success">ON</span>{% else %}<span class="badge bg-dark">OFF</span>{% endif %}</td><td>{% if cam.telegram_alert %}<span class="badge bg-info text-dark">ON</span>{% else %}<span class="badge bg-dark">OFF</span>{% endif %}</td>
                    <td class="text-end"><button class="btn btn-sm btn-warning fw-bold" data-bs-toggle="modal" data-bs-target="#editModal{{ cam.id }}"><i class="bi bi-pencil-square"></i></button> <form action="/cameras/delete/{{ cam.id }}" method="post" class="d-inline" onsubmit="return confirm('Hapus kamera {{ cam.name }}?');"><button type="submit" class="btn btn-sm btn-danger fw-bold"><i class="bi bi-trash"></i></button></form></td>
                </tr>
                <div class="modal fade" id="editModal{{ cam.id }}" tabindex="-1" data-bs-backdrop="static"><div class="modal-dialog"><div class="modal-content bg-dark text-white border-secondary"><div class="modal-header border-secondary"><h5 class="modal-title text-info"><i class="bi bi-pencil-square"></i> Edit Kamera</h5><button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button></div><form action="/cameras/edit/{{ cam.id }}" method="post"><div class="modal-body"><div class="mb-3"><label class="form-label fw-bold">Nama Kamera</label><input type="text" name="name" class="form-control border-secondary bg-dark text-white" value="{{ cam.name }}" required></div><div class="mb-3"><label class="form-label fw-bold">RTSP URL</label><input type="text" name="rtsp_url" class="form-control border-secondary bg-dark text-white" value="{{ cam.rtsp_url }}" required></div><div class="mb-3"><label class="form-label fw-bold">Mode Rekaman</label><select name="record_mode" class="form-select border-secondary bg-dark text-white"><option value="none" {% if cam.record_mode == 'none' %}selected{% endif %}>Live Saja</option><option value="24_7" {% if cam.record_mode == '24_7' %}selected{% endif %}>24 Jam</option><option value="motion" {% if cam.record_mode == 'motion' %}selected{% endif %}>AI Gerak</option></select></div><div class="form-check form-switch mb-3"><input class="form-check-input" type="checkbox" name="ai_enabled" value="true" id="edit_ai_{{ cam.id }}" {% if cam.ai_enabled %}checked{% endif %}><label class="form-check-label fw-bold text-success" for="edit_ai_{{ cam.id }}">Aktifkan AI</label></div><div class="form-check form-switch mb-3"><input class="form-check-input" type="checkbox" name="telegram_alert" value="true" id="edit_tele_{{ cam.id }}" {% if cam.telegram_alert %}checked{% endif %}><label class="form-check-label fw-bold text-info" for="edit_tele_{{ cam.id }}">Notif Telegram</label></div><div class="mb-3"><label class="form-label fw-bold">Kepekaan AI</label><input type="range" name="ai_sensitivity" class="form-range" min="1" max="100" value="{{ cam.ai_sensitivity }}"></div></div><div class="modal-footer border-secondary"><button type="submit" class="btn btn-warning fw-bold">Simpan</button></div></form></div></div></div>
                {% else %}<tr><td colspan="7" class="text-center py-5 text-muted">Belum ada kamera.</td></tr>{% endfor %}
            </tbody>
        </table></div></div>
    </div>
    <div class="modal fade" id="addCamModal" tabindex="-1" data-bs-backdrop="static"><div class="modal-dialog"><div class="modal-content bg-dark text-white border-secondary"><div class="modal-header border-secondary"><h5 class="modal-title text-success"><i class="bi bi-plus-circle"></i> Tambah Kamera Baru</h5><button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button></div><form action="/cameras" method="post"><div class="modal-body"><div class="mb-3"><label class="form-label fw-bold">Nama Kamera</label><input type="text" name="name" class="form-control border-secondary bg-dark text-white" required></div><div class="mb-3"><label class="form-label fw-bold">RTSP URL</label><input type="text" name="rtsp_url" class="form-control border-secondary bg-dark text-white" required></div><div class="mb-3"><label class="form-label fw-bold">Mode Rekaman</label><select name="record_mode" class="form-select border-secondary bg-dark text-white"><option value="none">Live Saja</option><option value="24_7">24 Jam</option><option value="motion">AI Gerak</option></select></div><div class="form-check form-switch mb-3"><input class="form-check-input" type="checkbox" name="ai_enabled" value="true" id="ai_new"><label class="form-check-label fw-bold text-success" for="ai_new">Aktifkan AI</label></div><div class="form-check form-switch mb-3"><input class="form-check-input" type="checkbox" name="telegram_alert" value="true" id="tele_new"><label class="form-check-label fw-bold text-info" for="tele_new">Notif Telegram</label></div><div class="mb-3"><label class="form-label fw-bold">Kepekaan AI</label><input type="range" name="ai_sensitivity" class="form-range" min="1" max="100" value="70"></div></div><div class="modal-footer border-secondary"><button type="submit" class="btn btn-success fw-bold">Simpan</button></div></form></div></div></div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
    <script>function toggleTheme() { const h = document.documentElement; const nt = h.getAttribute('data-bs-theme') === 'dark' ? 'light' : 'dark'; h.setAttribute('data-bs-theme', nt); localStorage.setItem('theme', nt); document.getElementById('theme-icon').innerHTML = nt === 'dark' ? '<i class="bi bi-brightness-high-fill"></i>' : '<i class="bi bi-moon-fill"></i>'; } document.addEventListener("DOMContentLoaded", () => { const st = localStorage.getItem('theme') || 'dark'; document.documentElement.setAttribute('data-bs-theme', st); let ti = document.getElementById('theme-icon'); if(ti) ti.innerHTML = st === 'dark' ? '<i class="bi bi-brightness-high-fill"></i>' : '<i class="bi bi-moon-fill"></i>'; });</script>
</body></html>
EOF

# ==============================================================================
# UI 4. RECORDINGS.HTML (FILTER & PLAYER)
# ==============================================================================
cat << 'EOF' > backend/templates/recordings.html
<!DOCTYPE html><html data-bs-theme="dark"><head><meta charset="utf-8"><title>Riwayat Rekaman</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.1/font/bootstrap-icons.css"></head>
<body class="bg-body text-body">
    <nav class="navbar navbar-expand-lg bg-body-tertiary border-bottom shadow-sm mb-4"><div class="container-fluid"><a class="navbar-brand fw-bold text-info" href="#"><i class="bi bi-shield-lock"></i> CCTV Guardian</a><button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav"><span class="navbar-toggler-icon"></span></button><div class="collapse navbar-collapse" id="navbarNav"><ul class="navbar-nav me-auto"><li class="nav-item"><a class="nav-link" href="/dashboard"><i class="bi bi-grid-fill"></i> Dashboard</a></li><li class="nav-item"><a class="nav-link" href="/cameras"><i class="bi bi-camera-video"></i> Kelola Kamera</a></li><li class="nav-item"><a class="nav-link active" href="/recordings"><i class="bi bi-film"></i> Riwayat Rekaman</a></li><li class="nav-item"><a class="nav-link text-warning" href="/settings"><i class="bi bi-gear-fill"></i> Pengaturan</a></li><li class="nav-item"><a class="nav-link text-success fw-bold" href="/users"><i class="bi bi-people-fill"></i> Pengguna</a></li></ul><div class="d-flex align-items-center mt-2 mt-lg-0"><button class="btn btn-sm btn-outline-secondary me-3" onclick="toggleTheme()"><span id="theme-icon"><i class="bi bi-brightness-high-fill"></i></span> Mode</button><a href="/logout" class="btn btn-outline-danger btn-sm"><i class="bi bi-box-arrow-right"></i> Logout</a></div></div></div></nav>
    <div class="container px-4">
        <div class="d-flex justify-content-between align-items-center mb-3 border-bottom pb-2"><h4><i class="bi bi-hdd-network"></i> Arsip Rekaman (MP4)</h4><span class="badge bg-secondary">Folder: {{ storage_path }}</span></div>
        <div class="card shadow-sm border-secondary mb-4 bg-body-tertiary"><div class="card-body"><div class="row g-2">
            <div class="col-md-3"><label class="small text-muted fw-bold">Kamera</label><select id="fCam" class="form-select border-secondary" onchange="applyF()"><option value="">Semua Kamera</option>{% for cam in cameras %}<option value="{{ cam }}">{{ cam }}</option>{% endfor %}</select></div>
            <div class="col-md-3"><label class="small text-muted fw-bold">Tanggal</label><input type="date" id="fDate" class="form-control border-secondary" onchange="applyF()"></div>
            <div class="col-md-2"><label class="small text-muted fw-bold">Jam</label><select id="fHour" class="form-select border-secondary" onchange="applyF()"><option value="">Semua</option></select></div>
            <div class="col-md-2"><label class="small text-muted fw-bold">Menit</label><select id="fMin" class="form-select border-secondary" onchange="applyF()"><option value="">Semua</option></select></div>
            <div class="col-md-2 d-flex align-items-end"><button class="btn btn-outline-warning w-100 fw-bold" onclick="resetF()"><i class="bi bi-arrow-clockwise"></i> Reset</button></div>
        </div></div></div>
        <div class="card shadow-sm border-secondary mb-5"><div class="card-body p-0 table-responsive"><table class="table table-hover table-striped mb-0 align-middle"><thead class="table-dark"><tr><th>Kamera</th><th>Tanggal</th><th>Waktu</th><th>Nama File</th><th class="text-end">Aksi</th></tr></thead><tbody id="recTbl">
            {% for file in files %}
            <tr class="rec-row" data-c="{{ file.cam_name }}" data-d="{{ file.date }}" data-h="{{ file.hour }}" data-m="{{ file.minute }}"><td class="fw-bold text-info"><i class="bi bi-camera"></i> {{ file.cam_name }}</td><td>{{ file.date }}</td><td><span class="badge bg-secondary">{{ file.time }}</span></td><td class="small text-muted">{{ file.filename }}</td><td class="text-end"><button class="btn btn-sm btn-primary fw-bold" onclick="op('{{ file.filename }}', '{{ file.cam_name }} - {{ file.date }} {{ file.time }}')"><i class="bi bi-play-circle-fill"></i> Putar</button> <a href="/play_video/{{ file.filename }}" download class="btn btn-sm btn-outline-success"><i class="bi bi-download"></i></a></td></tr>
            {% else %}<tr><td colspan="5" class="text-center py-5 text-muted">Belum ada file rekaman.</td></tr>{% endfor %}
        </tbody></table></div></div>
    </div>
    <div class="modal fade" id="pMod" tabindex="-1" data-bs-backdrop="static"><div class="modal-dialog modal-xl modal-dialog-centered"><div class="modal-content bg-dark text-white border-secondary"><div class="modal-header border-secondary"><h5 class="modal-title text-info fw-bold" id="pTit"><i class="bi bi-play-btn-fill"></i> Playback</h5><button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" onclick="cp()"></button></div><div class="modal-body p-0 text-center bg-black"><video id="vid" controls style="width: 100%; max-height: 70vh; object-fit: contain;" playsinline></video></div><div class="modal-footer border-secondary d-flex justify-content-between bg-body-tertiary"><div class="d-flex align-items-center"><label class="me-3 fw-bold text-body"><i class="bi bi-speedometer2"></i> Speed:</label><select id="sCtrl" class="form-select form-select-sm fw-bold border-secondary" style="width: 150px; background-color: var(--bs-body-bg); color: var(--bs-body-color);" onchange="cs()"><option value="0.5">0.5x</option><option value="1" selected>1x Normal</option><option value="2">2x</option><option value="4">4x</option><option value="8">8x</option></select></div><button type="button" class="btn btn-secondary btn-sm" data-bs-dismiss="modal" onclick="cp()">Tutup</button></div></div></div></div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        document.addEventListener("DOMContentLoaded", () => { let h=document.getElementById('fHour'); for(let i=0;i<24;i++) h.add(new Option(String(i).padStart(2,'0'), String(i).padStart(2,'0'))); let m=document.getElementById('fMin'); for(let i=0;i<60;i++) m.add(new Option(String(i).padStart(2,'0'), String(i).padStart(2,'0'))); });
        function applyF() { let c=document.getElementById('fCam').value, d=document.getElementById('fDate').value, h=document.getElementById('fHour').value, m=document.getElementById('fMin').value; document.querySelectorAll('.rec-row').forEach(r => { let ok = true; if(c && r.getAttribute('data-c') !== c) ok = false; if(d && r.getAttribute('data-d') !== d) ok = false; if(h && r.getAttribute('data-h') !== h) ok = false; if(m && r.getAttribute('data-m') !== m) ok = false; r.style.display = ok ? '' : 'none'; }); }
        function resetF() { document.getElementById('fCam').value=""; document.getElementById('fDate').value=""; document.getElementById('fHour').value=""; document.getElementById('fMin').value=""; applyF(); }
        const pMod = new bootstrap.Modal(document.getElementById('pMod')); const vid = document.getElementById('vid'); const sCtrl = document.getElementById('sCtrl');
        function op(f, t) { document.getElementById('pTit').innerHTML = '<i class="bi bi-play-btn-fill"></i> ' + t; vid.src = "/play_video/" + f; sCtrl.value = "1"; vid.playbackRate = 1; pMod.show(); vid.play().catch(e=>{}); }
        function cp() { vid.pause(); vid.src = ""; } function cs() { try{vid.playbackRate = parseFloat(sCtrl.value);}catch(e){} }
        function toggleTheme() { const h = document.documentElement; const nt = h.getAttribute('data-bs-theme') === 'dark' ? 'light' : 'dark'; h.setAttribute('data-bs-theme', nt); localStorage.setItem('theme', nt); document.getElementById('theme-icon').innerHTML = nt === 'dark' ? '<i class="bi bi-brightness-high-fill"></i>' : '<i class="bi bi-moon-fill"></i>'; } document.addEventListener("DOMContentLoaded", () => { const st = localStorage.getItem('theme') || 'dark'; document.documentElement.setAttribute('data-bs-theme', st); let ti = document.getElementById('theme-icon'); if(ti) ti.innerHTML = st === 'dark' ? '<i class="bi bi-brightness-high-fill"></i>' : '<i class="bi bi-moon-fill"></i>'; });
    </script>
</body></html>
EOF

# ==============================================================================
# UI 5. SETTINGS.HTML (PENGATURAN)
# ==============================================================================
cat << 'EOF' > backend/templates/settings.html
<!DOCTYPE html><html data-bs-theme="dark"><head><meta charset="utf-8"><title>Pengaturan - CCTV Guardian</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.1/font/bootstrap-icons.css"></head>
<body class="bg-body text-body">
    <nav class="navbar navbar-expand-lg bg-body-tertiary border-bottom shadow-sm mb-4"><div class="container-fluid"><a class="navbar-brand fw-bold text-info" href="#"><i class="bi bi-shield-lock"></i> CCTV Guardian</a><button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav"><span class="navbar-toggler-icon"></span></button><div class="collapse navbar-collapse" id="navbarNav"><ul class="navbar-nav me-auto"><li class="nav-item"><a class="nav-link" href="/dashboard"><i class="bi bi-grid-fill"></i> Dashboard</a></li><li class="nav-item"><a class="nav-link" href="/cameras"><i class="bi bi-camera-video"></i> Kelola Kamera</a></li><li class="nav-item"><a class="nav-link" href="/recordings"><i class="bi bi-film"></i> Riwayat Rekaman</a></li><li class="nav-item"><a class="nav-link active text-warning fw-bold" href="/settings"><i class="bi bi-gear-fill"></i> Pengaturan</a></li><li class="nav-item"><a class="nav-link text-success fw-bold" href="/users"><i class="bi bi-people-fill"></i> Pengguna</a></li></ul><div class="d-flex align-items-center mt-2 mt-lg-0"><button class="btn btn-sm btn-outline-secondary me-3" onclick="toggleTheme()"><span id="theme-icon"><i class="bi bi-brightness-high-fill"></i></span> Mode</button><a href="/logout" class="btn btn-outline-danger btn-sm"><i class="bi bi-box-arrow-right"></i> Logout</a></div></div></div></nav>
    <div class="container px-4 pb-5">
        <h4 class="mb-4 border-bottom pb-2"><i class="bi bi-gear-fill"></i> Konfigurasi Sistem</h4>
        <div class="card shadow-sm border-secondary mb-4"><div class="card-body"><form action="/settings/save" method="post">
            <h5 class="text-info border-bottom border-secondary pb-2 mb-3"><i class="bi bi-hdd-fill"></i> Penyimpanan MP4</h5>
            <div class="row g-3 mb-4"><div class="col-md-12"><label class="form-label fw-bold">Folder Rekaman</label><input type="text" class="form-control border-secondary bg-dark text-white" name="storage_path" value="{{ storage_path }}" required></div><div class="col-md-12"><label class="form-label fw-bold">Batas Auto-Cleanup (GB)</label><input type="number" class="form-control border-secondary bg-dark text-white w-50" name="max_storage_gb" value="{{ current_storage }}" required></div></div>
            <h5 class="text-info border-bottom border-secondary pb-2 mb-3"><i class="bi bi-telegram"></i> Bot Telegram AI</h5>
            <div class="row g-3 mb-4"><div class="col-md-6"><label class="form-label fw-bold">Token Bot</label><input type="text" class="form-control border-secondary bg-dark text-white" name="telegram_token" value="{{ telegram_token }}"></div><div class="col-md-6"><label class="form-label fw-bold">Chat ID</label><input type="text" class="form-control border-secondary bg-dark text-white" name="telegram_chat_id" value="{{ telegram_chat_id }}"></div></div>
            <h5 class="text-info border-bottom border-secondary pb-2 mb-3"><i class="bi bi-layout-text-window-reverse"></i> UI Dashboard</h5>
            <div class="row g-3 mb-4"><div class="col-md-4"><label class="form-label fw-bold">Ukuran Grid</label><select class="form-select border-secondary bg-dark text-white" name="grid_size"><option value="4" {% if grid_size == 4 %}selected{% endif %}>4 Kamera</option><option value="6" {% if grid_size == 6 %}selected{% endif %}>6 Kamera</option><option value="9" {% if grid_size == 9 %}selected{% endif %}>9 Kamera</option></select></div><div class="col-md-4"><label class="form-label fw-bold">Auto-Rotate</label><select class="form-select border-secondary bg-dark text-white" name="auto_rotate"><option value="false" {% if auto_rotate == 'false' %}selected{% endif %}>Mati</option><option value="true" {% if auto_rotate == 'true' %}selected{% endif %}>Aktif</option></select></div><div class="col-md-4"><label class="form-label fw-bold">Jeda (Detik)</label><input type="number" class="form-control border-secondary bg-dark text-white" name="rotate_interval" value="{{ rotate_interval }}"></div></div>
            <button type="submit" class="btn btn-warning fw-bold w-100 py-2"><i class="bi bi-save2-fill"></i> Simpan Pengaturan</button>
        </form></div></div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
    <script>function toggleTheme() { const h = document.documentElement; const nt = h.getAttribute('data-bs-theme') === 'dark' ? 'light' : 'dark'; h.setAttribute('data-bs-theme', nt); localStorage.setItem('theme', nt); document.getElementById('theme-icon').innerHTML = nt === 'dark' ? '<i class="bi bi-brightness-high-fill"></i>' : '<i class="bi bi-moon-fill"></i>'; } document.addEventListener("DOMContentLoaded", () => { const st = localStorage.getItem('theme') || 'dark'; document.documentElement.setAttribute('data-bs-theme', st); let ti = document.getElementById('theme-icon'); if(ti) ti.innerHTML = st === 'dark' ? '<i class="bi bi-brightness-high-fill"></i>' : '<i class="bi bi-moon-fill"></i>'; });</script>
</body></html>
EOF

# ==============================================================================
# UI 6. USERS.HTML (MANAJEMEN PENGGUNA)
# ==============================================================================
cat << 'EOF' > backend/templates/users.html
<!DOCTYPE html><html data-bs-theme="dark"><head><meta charset="utf-8"><title>Pengguna - CCTV Guardian</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.1/font/bootstrap-icons.css"></head>
<body class="bg-body text-body">
    <nav class="navbar navbar-expand-lg bg-body-tertiary border-bottom shadow-sm mb-4"><div class="container-fluid"><a class="navbar-brand fw-bold text-info" href="#"><i class="bi bi-shield-lock"></i> CCTV Guardian</a><button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav"><span class="navbar-toggler-icon"></span></button><div class="collapse navbar-collapse" id="navbarNav"><ul class="navbar-nav me-auto"><li class="nav-item"><a class="nav-link" href="/dashboard"><i class="bi bi-grid-fill"></i> Dashboard</a></li><li class="nav-item"><a class="nav-link" href="/cameras"><i class="bi bi-camera-video"></i> Kelola Kamera</a></li><li class="nav-item"><a class="nav-link" href="/recordings"><i class="bi bi-film"></i> Riwayat Rekaman</a></li><li class="nav-item"><a class="nav-link text-warning" href="/settings"><i class="bi bi-gear-fill"></i> Pengaturan</a></li><li class="nav-item"><a class="nav-link active text-success fw-bold" href="/users"><i class="bi bi-people-fill"></i> Pengguna</a></li></ul><div class="d-flex align-items-center mt-2 mt-lg-0"><button class="btn btn-sm btn-outline-secondary me-3" onclick="toggleTheme()"><span id="theme-icon"><i class="bi bi-brightness-high-fill"></i></span> Mode</button><a href="/logout" class="btn btn-outline-danger btn-sm"><i class="bi bi-box-arrow-right"></i> Logout</a></div></div></div></nav>
    <div class="container px-4">
        <div class="d-flex justify-content-between align-items-center mb-4 border-bottom pb-2"><h4><i class="bi bi-people-fill"></i> Manajemen Pengguna</h4><button class="btn btn-success fw-bold" data-bs-toggle="modal" data-bs-target="#addUserModal"><i class="bi bi-person-plus-fill"></i> Tambah Akun</button></div>
        <div class="card shadow-sm border-secondary mb-5"><div class="card-body p-0 table-responsive"><table class="table table-hover table-striped mb-0 align-middle"><thead class="table-dark"><tr><th>Username</th><th>Peran</th><th class="text-end">Aksi</th></tr></thead>
            <tbody>
                {% for user in users %}
                <tr><td class="fw-bold text-info"><i class="bi bi-person-circle"></i> {{ user.username }}</td><td>{% if user.role == 'admin' %}<span class="badge bg-danger">Administrator</span>{% else %}<span class="badge bg-secondary">Tamu</span>{% endif %}</td><td class="text-end"><button class="btn btn-sm btn-warning fw-bold" data-bs-toggle="modal" data-bs-target="#editUserModal{{ user.id }}"><i class="bi bi-pencil-square"></i></button> {% if user.username != 'admin' %}<form action="/users/delete/{{ user.id }}" method="post" class="d-inline" onsubmit="return confirm('Hapus pengguna {{ user.username }}?');"><button type="submit" class="btn btn-sm btn-danger fw-bold"><i class="bi bi-trash"></i></button></form>{% endif %}</td></tr>
                <div class="modal fade" id="editUserModal{{ user.id }}" tabindex="-1" data-bs-backdrop="static"><div class="modal-dialog"><div class="modal-content bg-dark text-white border-secondary"><div class="modal-header border-secondary"><h5 class="modal-title text-info"><i class="bi bi-pencil-square"></i> Edit Pengguna</h5><button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button></div><form action="/users/edit/{{ user.id }}" method="post"><div class="modal-body"><div class="mb-3"><label class="form-label fw-bold">Username</label><input type="text" name="username" class="form-control border-secondary bg-dark text-white" value="{{ user.username }}" required {% if user.username == 'admin' %}readonly{% endif %}></div><div class="mb-3"><label class="form-label fw-bold">Password Baru</label><input type="password" name="password" class="form-control border-secondary bg-dark text-white"></div><div class="mb-3"><label class="form-label fw-bold">Peran Akses</label><select name="role" class="form-select border-secondary bg-dark text-white" {% if user.username == 'admin' %}disabled{% endif %}><option value="admin" {% if user.role == 'admin' %}selected{% endif %}>Administrator</option><option value="tamu" {% if user.role == 'tamu' %}selected{% endif %}>Tamu</option></select>{% if user.username == 'admin' %}<input type="hidden" name="role" value="admin">{% endif %}</div></div><div class="modal-footer border-secondary"><button type="submit" class="btn btn-warning fw-bold">Simpan</button></div></form></div></div></div>
                {% endfor %}
            </tbody>
        </table></div></div>
    </div>
    <div class="modal fade" id="addUserModal" tabindex="-1" data-bs-backdrop="static"><div class="modal-dialog"><div class="modal-content bg-dark text-white border-secondary"><div class="modal-header border-secondary"><h5 class="modal-title text-success"><i class="bi bi-person-plus-fill"></i> Tambah Pengguna Baru</h5><button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button></div><form action="/users" method="post"><div class="modal-body"><div class="mb-3"><label class="form-label fw-bold">Username</label><input type="text" name="username" class="form-control border-secondary bg-dark text-white" required></div><div class="mb-3"><label class="form-label fw-bold">Password</label><input type="password" name="password" class="form-control border-secondary bg-dark text-white" required></div><div class="mb-3"><label class="form-label fw-bold">Peran Akses</label><select name="role" class="form-select border-secondary bg-dark text-white"><option value="admin">Administrator</option><option value="tamu" selected>Tamu</option></select></div></div><div class="modal-footer border-secondary"><button type="submit" class="btn btn-success fw-bold">Simpan Akun</button></div></form></div></div></div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
    <script>function toggleTheme() { const h = document.documentElement; const nt = h.getAttribute('data-bs-theme') === 'dark' ? 'light' : 'dark'; h.setAttribute('data-bs-theme', nt); localStorage.setItem('theme', nt); document.getElementById('theme-icon').innerHTML = nt === 'dark' ? '<i class="bi bi-brightness-high-fill"></i>' : '<i class="bi bi-moon-fill"></i>'; } document.addEventListener("DOMContentLoaded", () => { const st = localStorage.getItem('theme') || 'dark'; document.documentElement.setAttribute('data-bs-theme', st); let ti = document.getElementById('theme-icon'); if(ti) ti.innerHTML = st === 'dark' ? '<i class="bi bi-brightness-high-fill"></i>' : '<i class="bi bi-moon-fill"></i>'; });</script>
</body></html>
EOF

echo "[+] Menyimpan dan mengaktifkan Web Server (Supervisor)..."
cat << 'EOF' > /etc/supervisor/conf.d/cctv-guardian.conf
[program:cctv-guardian_web]
command=python3 -m uvicorn backend.main:app --host 0.0.0.0 --port 8000
directory=/opt/cctv-guardian
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/cctv-guardian.err.log
stdout_logfile=/var/log/supervisor/cctv-guardian.out.log
user=root
EOF

systemctl restart supervisor
supervisorctl reread >/dev/null 2>&1
supervisorctl update >/dev/null 2>&1
supervisorctl restart cctv-guardian_web >/dev/null 2>&1

# MENDAPATKAN IP VPS SECARA OTOMATIS
PUBLIC_IP=$(curl -s ifconfig.me || echo "IP_VPS_LU")

echo ""
echo "=================================================================="
echo "    [+] SELESAI BOS! SISTEM VMS SUDAH BERDIRI KOKOH!              "
echo "=================================================================="
echo "🚀 AKSES DASHBOARD CCTV GUARDIAN LU DI:"
echo "🌐 URL Akses : http://$PUBLIC_IP:8000"
echo "👤 Username  : admin"
echo "🔑 Password  : adminpassword"
echo ""
echo "⚠️  Catatan: Segera ubah password ini di menu Pengguna!"
echo "=================================================================="