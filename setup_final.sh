#!/bin/bash
# ============================================
# CCTV Guardian - Setup Script Final
# Single file, self-contained deployment
# Semua file aplikasi dibuat inline
# ============================================
set -euo pipefail

APP_NAME="cctv-guardian"
APP_DIR="/opt/${APP_NAME}"

echo ""
echo "============================================"
echo "  CCTV Guardian - Automated Installer"
echo "  Single-file deployment (no extra folders)"
echo "============================================"
echo ""

# ---- System Setup ----
SEC() { echo ""; echo -e "\e[1;94m[Step $1]\e[0m $2"; }
OK() { echo -e "  \e[32m✓\e[0m $1"; }
ERR() { echo -e "  \e[31m✗\e[0m $1" >&2; exit 1; }
WARN() { echo -e "  \e[33m⚠\e[0m $1"; }
INF() { echo -e "  \e[96mℹ\e[0m $1"; }

SEC "1: Update System & Install Dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget git supervisor nginx ffmpeg python3 python3-pip python3-venv python3-dev 2>/dev/null || apt-get install -y curl wget git supervisor nginx ffmpeg python3 python3-pip python3-venv 2>/dev/null
OK "System packages installed"

SEC "2: Create App User & Directory"
if ! id cctvapp &>/dev/null; then
    useradd -m -s /bin/bash cctvapp 2>/dev/null || useradd -m cctvapp 2>/dev/null || true
fi
mkdir -p "$APP_DIR"/{backend/routes,backend/utils,backend/templates,backend/static/css,backend/static/js,recordings,logs,backups}
chown -R cctvapp:cctvapp "$APP_DIR" 2>/dev/null || chown -R cctvapp "$APP_DIR" 2>/dev/null || true
OK "User & directory created"

SEC "3: Create Python Virtual Environment"
python3 -m venv "$APP_DIR/venv"
source "$APP_DIR/venv/bin/activate"
pip install --upgrade pip -q
OK "Virtual environment created"

SEC "4: Install Python Dependencies"
pip install -q \
    fastapi uvicorn python-multipart passlib[bcrypt] \
    python-jose[cryptography] sqlalchemy aiofiles \
    pillow opencv-python-headless pyyaml python-dotenv \
    requests httpx aiohttp google-api-python-client boto3 \
    2>/dev/null || pip install -q fastapi uvicorn python-multipart passlib python-jose sqlalchemy aiofiles pillow opencv-python-headless requests httpx 2>/dev/null
OK "Python dependencies installed"

SEC "5: Create .env Configuration"
cat > "$APP_DIR/.env" << 'ENVEOF'
APP_NAME=CCTV Guardian
PORT=8000
DATABASE_URL=sqlite:///data.db
JWT_SECRET_KEY=change-this-to-random-string
JWT_ALGORITHM=HS256
JWT_EXPIRATION_MINUTES=60
LOG_LEVEL=INFO
LOG_FILE=logs/app.log
LOG_TO_FILE=true
LOG_TO_CONSOLE=true

RTSP_URL_1=rtsp://admin:password@192.168.1.100:554/stream
RTSP_USER_1=admin
RTSP_PASS_1=password

RTSP_URL_2=
RTSP_USER_2=
RTSP_PASS_2=

LOCAL_SAVE_PATH=recordings
RECORDING_FORMAT=mp4
RECORDING_FPS=25
RECORDING_RESOLUTION=1280x720
MAX_LOCAL_STORAGE_GB=50
AUTO_DELETE_OLD_RECORDS=true
RECORD_RETENTION_DAYS=30

CLOUD_UPLOAD_ENABLED=false
CLOUD_PROVIDER=none
GOOGLE_DRIVE_CLIENT_ID=
GOOGLE_DRIVE_CLIENT_SECRET=
GOOGLE_DRIVE_REFRESH_TOKEN=
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_S3_BUCKET=
AWS_S3_REGION=us-east-1
NEXTCLOUD_URL=
NEXTCLOUD_USER=
NEXTCLOUD_PASSWORD=
NEXTCLOUD_FOLDER=

TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=

EMAIL_ENABLED=false
EMAIL_SENDER=
EMAIL_PASSWORD=
EMAIL_RECIPIENT=
SMTP_SERVER=smtp.gmail.com
SMTP_PORT=587
SMTP_TLS=true

DETECTION_ENABLED=true
DETECTION_MODEL_TYPE=full-body
DETECTION_CONFIDENCE_THRESHOLD=0.5
DETECTION_INTERVAL=5
YOLO_MODEL_PATH=

DEBUG=false
ADMIN_EMAIL=admin@localhost
ENVEOF
OK ".env created"

# ---- Config ----
SEC "6: Create Backend Config"
cat > "$APP_DIR/backend/config.py" << 'PYEOF'
from pydantic_settings import BaseSettings
from functools import lru_cache

class Settings(BaseSettings):
    app_name: str = "CCTV Guardian"
    port: int = 8000
    database_url: str = "sqlite:///data.db"
    jwt_secret_key: str = ""
    jwt_algorithm: str = "HS256"
    jwt_expiration_minutes: int = 60
    log_level: str = "INFO"
    log_file: str = "logs/app.log"
    log_to_file: bool = True
    log_to_console: bool = True
    rtsp_url_1: str = ""
    rtsp_user_1: str = ""
    rtsp_pass_1: str = ""
    rtsp_url_2: str = ""
    rtsp_user_2: str = ""
    rtsp_pass_2: str = ""
    local_save_path: str = "recordings"
    recording_format: str = "mp4"
    recording_fps: int = 25
    recording_resolution: str = "1280x720"
    max_local_storage_gb: int = 50
    auto_delete_old_records: bool = True
    record_retention_days: int = 30
    cloud_upload_enabled: bool = False
    cloud_provider: str = "none"
    google_drive_client_id: str = ""
    google_drive_client_secret: str = ""
    google_drive_refresh_token: str = ""
    aws_access_key_id: str = ""
    aws_secret_access_key: str = ""
    aws_s3_bucket: str = ""
    aws_s3_region: str = "us-east-1"
    nextcloud_url: str = ""
    nextcloud_user: str = ""
    nextcloud_password: str = ""
    nextcloud_folder: str = ""
    telegram_bot_token: str = ""
    telegram_chat_id: str = ""
    email_enabled: bool = False
    email_sender: str = ""
    email_password: str = ""
    email_recipient: str = ""
    smtp_server: str = "smtp.gmail.com"
    smtp_port: int = 587
    smtp_tls: bool = True
    detection_enabled: bool = True
    detection_model_type: str = "full-body"
    detection_confidence_threshold: float = 0.5
    detection_interval: int = 5
    yolo_model_path: str = ""
    debug: bool = False
    admin_email: str = "admin@localhost"

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"

@lru_cache()
def get_settings():
    return Settings()

settings = get_settings()
PYEOF
OK "config.py created"

# ---- Database ----
SEC "7: Create Database Setup"
cat > "$APP_DIR/backend/database.py" << 'PYEOF'
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base
from backend.config import settings

engine = create_engine(
    settings.database_url,
    connect_args={"check_same_thread": False},
    pool_pre_ping=True,
    pool_recycle=3600
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
PYEOF
OK "database.py created"

# ---- Auth ----
SEC "8: Create Auth Module"
cat > "$APP_DIR/backend/auth.py" << 'PYEOF'
from datetime import datetime, timedelta
from typing import Optional
from jose import jwt, JWTError
from passlib.context import CryptContext
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from backend.database import get_db
from backend.config import settings
from backend.models import User

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
security = HTTPBearer()

def hash_password(password: str) -> str:
    return pwd_context.hash(password)

def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)

def create_access_token(data: dict, expires_delta: Optional[timedelta] = None) -> str:
    to_encode = data.copy()
    expire = datetime.utcnow() + (expires_delta or timedelta(minutes=settings.jwt_expiration_minutes))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)

def verify_token(token: str) -> dict:
    try:
        payload = jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
        return payload
    except JWTError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")

def get_current_user_from_token(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db)
):
    payload = verify_token(credentials.credentials)
    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(status_code=401, detail="Invalid token payload")
    user = db.query(User).filter(User.id == int(user_id)).first()
    if not user:
        raise HTTPException(status_code=401, detail="User not found")
    return user

def admin_required(current_user = Depends(get_current_user_from_token)):
    if current_user.role != "admin":
        raise HTTPException(status_code=403, detail="Admin access required")
    return current_user

def authenticate_user(username: str, password: str, db: Session) -> Optional[User]:
    user = db.query(User).filter(User.username == username).first()
    if not user or not user.is_active:
        return None
    if not verify_password(password, user.password_hash):
        return None
    return user
PYEOF
OK "auth.py created"

# ---- Models ----
SEC "9: Create SQLAlchemy Models"
cat > "$APP_DIR/backend/models.py" << 'PYEOF'
from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, Text, Float
from sqlalchemy.orm import relationship
from datetime import datetime
from backend.database import Base

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True, index=True)
    username = Column(String(50), unique=True, index=True, nullable=False)
    password_hash = Column(String(255), nullable=False)
    full_name = Column(String(100), nullable=True)
    email = Column(String(100), nullable=True)
    role = Column(String(20), default="viewer")
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    cameras = relationship("Camera", back_populates="owner")

class Camera(Base):
    __tablename__ = "cameras"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False)
    location = Column(String(200), nullable=True)
    rtsp_url = Column(String(500), nullable=False)
    username = Column(String(50), nullable=True)
    password = Column(String(100), nullable=True)
    is_active = Column(Boolean, default=True)
    owner_id = Column(Integer, ForeignKey("users.id"))
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    owner = relationship("User", back_populates="cameras")

class Recording(Base):
    __tablename__ = "recordings"
    id = Column(Integer, primary_key=True, index=True)
    camera_id = Column(Integer, ForeignKey("cameras.id"))
    start_time = Column(DateTime, default=datetime.utcnow)
    end_time = Column(DateTime, nullable=True)
    duration_seconds = Column(Integer, nullable=True)
    file_path = Column(String(500), nullable=True)
    file_size_mb = Column(Float, nullable=True)
    storage_type = Column(String(20), default="local")
    cloud_path = Column(String(500), nullable=True)
    uploaded = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)

class DetectionLog(Base):
    __tablename__ = "detection_logs"
    id = Column(Integer, primary_key=True, index=True)
    camera_id = Column(Integer, ForeignKey("cameras.id"))
    timestamp = Column(DateTime, default=datetime.utcnow)
    human_detected = Column(Boolean, default=False)
    confidence = Column(Float, nullable=True)
    num_humans = Column(Integer, nullable=True)

class Alert(Base):
    __tablename__ = "alerts"
    id = Column(Integer, primary_key=True, index=True)
    camera_id = Column(Integer, ForeignKey("cameras.id"))
    alert_type = Column(String(50), nullable=False)
    message = Column(Text, nullable=True)
    timestamp = Column(DateTime, default=datetime.utcnow)
    read = Column(Boolean, default=False)
    acknowledged = Column(Boolean, default=False)
    acknowledged_by = Column(Integer, nullable=True)
    acknowledged_at = Column(DateTime, nullable=True)
PYEOF
OK "models.py created"

# ---- Main Application ----
SEC "10: Create Main Application (main.py)"
cat > "$APP_DIR/backend/main.py" << 'MAINEOF'
import os, sys, time, json, base64, threading, io, logging, shutil, signal
from datetime import datetime
from pathlib import Path
from functools import lru_cache

from fastapi import FastAPI, Request, Depends, HTTPException, Query, File, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
from sqlalchemy import desc

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from backend.database import SessionLocal, Base, engine
from backend.models import User, Camera, Recording, DetectionLog, Alert
from backend.auth import (get_current_user_from_token, admin_required,
                          authenticate_user, create_access_token, verify_token,
                          hash_password, verify_password, security)
from backend.config import settings

# ---- Database Init ----
Base.metadata.create_all(bind=engine)

# ---- Logging ----
os.makedirs(os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"), exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "app.log"))
    ]
)
logger = logging.getLogger("cctv-guardian")

# ---- App Setup ----
app = FastAPI(title="CCTV Guardian", version="1.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True,
                   allow_methods=["*"], allow_headers=["*"])

BASE_DIR = Path(__file__).parent.parent
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "backend" / "static")), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "backend" / "templates"))

# ---- Helper: get_db ----
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# ---- Helper: verify token for templates ----
@app.get("/api/verify")
async def verify_token_endpoint(request: Request):
    token = request.cookies.get("auth_token") or request.headers.get("Authorization", "").replace("Bearer ", "")
    if not token:
        return {"valid": False}
    try:
        payload = verify_token(token)
        db = SessionLocal()
        user = db.query(User).filter(User.id == int(payload["sub"])).first()
        db.close()
        if user:
            return {"valid": True, "user": {"id": user.id, "username": user.username, "role": user.role}}
        return {"valid": False}
    except:
        return {"valid": False}

@app.post("/api/auth/logout")
async def logout():
    return {"success": True}

@app.post("/api/auth/login")
async def login(request: Request):
    form = await request.form()
    username = form.get("username", "")
    password = form.get("password", "")
    db = SessionLocal()
    user = authenticate_user(username, password, db)
    db.close()
    if not user:
        raise HTTPException(401, "Incorrect username or password")
    token = create_access_token(data={"sub": str(user.id), "role": user.role, "username": user.username})
    return {"access_token": token, "token_type": "bearer", "user": {"id": user.id, "username": user.username, "role": user.role}}

@app.post("/api/auth/register")
async def register(request: Request):
    data = await request.json()
    username = data.get("username", "")
    password = data.get("password", "")
    if not username or not password or len(password) < 6:
        raise HTTPException(400, "Username and password (min 6 chars) required")
    db = SessionLocal()
    if db.query(User).filter(User.username == username).first():
        db.close()
        raise HTTPException(400, "Username already exists")
    user = User(username=username, password_hash=hash_password(password),
                role=data.get("role", "viewer"), is_active=True)
    db.add(user)
    db.commit()
    db.refresh(user)
    db.close()
    return {"message": "User registered", "user_id": user.id}

# ---- Cameras ----
@app.get("/api/cameras")
async def list_cameras(request: Request, skip: int = 0, limit: int = 100, search: str = "",
                       current_user = Depends(get_current_user_from_token)):
    db = SessionLocal()
    query = db.query(Camera)
    if search:
        query = query.filter(Camera.name.ilike(f"%{search}%") | Camera.location.ilike(f"%{search}%"))
    cameras = query.offset(skip).limit(limit).all()
    db.close()
    return cameras

@app.post("/api/cameras")
async def create_camera(request: Request, current_user = Depends(admin_required)):
    data = await request.form()
    camera = Camera(
        name=data.get("name", ""),
        location=data.get("location", ""),
        rtsp_url=data.get("rtsp_url", ""),
        username=data.get("username", ""),
        password=data.get("password", ""),
        is_active=data.get("is_active", "true") == "true",
        owner_id=current_user.id
    )
    if not camera.name or not camera.rtsp_url:
        raise HTTPException(400, "Name and RTSP URL required")
    db = SessionLocal()
    db.add(camera)
    db.commit()
    db.refresh(camera)
    db.close()
    return {"success": True, "message": "Camera created", "camera": camera}

@app.get("/api/cameras/{camera_id}")
async def get_camera(camera_id: int, current_user = Depends(get_current_user_from_token)):
    db = SessionLocal()
    camera = db.query(Camera).filter(Camera.id == camera_id).first()
    db.close()
    if not camera:
        raise HTTPException(404, "Camera not found")
    return camera

@app.put("/api/cameras/{camera_id}")
async def update_camera(camera_id: int, request: Request, current_user = Depends(admin_required)):
    data = await request.form()
    db = SessionLocal()
    camera = db.query(Camera).filter(Camera.id == camera_id).first()
    if not camera:
        db.close()
        raise HTTPException(404, "Camera not found")
    for key in ["name", "location", "rtsp_url", "username", "password"]:
        if key in data:
            setattr(camera, key, data[key])
    if "is_active" in data:
        camera.is_active = data["is_active"] == "true"
    db.commit()
    db.refresh(camera)
    db.close()
    return {"success": True, "message": "Camera updated", "camera": camera}

@app.delete("/api/cameras/{camera_id}")
async def delete_camera(camera_id: int, current_user = Depends(admin_required)):
    db = SessionLocal()
    camera = db.query(Camera).filter(Camera.id == camera_id).first()
    if not camera:
        db.close()
        raise HTTPException(404, "Camera not found")
    db.delete(camera)
    db.commit()
    db.close()
    return {"success": True, "message": "Camera deleted"}

# ---- Stream (MJPEG) ----
def generate_mjpeg_stream(camera_id: int):
    import cv2
    db = SessionLocal()
    camera = db.query(Camera).filter(Camera.id == camera_id).first()
    db.close()
    if not camera:
        yield (b'--frame\r\n' b'Content-Type: text/plain\r\n\r\n' b'Camera not found\r\n')
        return
    cap = cv2.VideoCapture(camera.rtsp_url)
    if not cap.isOpened():
        yield (b'--frame\r\n' b'Content-Type: text/plain\r\n\r\n' b'Cannot open camera\r\n')
        return
    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                time.sleep(0.1)
                continue
            _, jpg = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 75])
            frame_bytes = jpg.tobytes()
            yield (b'--frame\r\n' b'Content-Type: image/jpeg\r\nContent-Length: ' +
                   str(len(frame_bytes)).encode() + b'\r\n\r\n' + frame_bytes + b'\r\n')
            time.sleep(0.05)
    except:
        pass
    finally:
        cap.release()

@app.get("/api/stream/{camera_id}")
async def stream_camera(camera_id: int, current_user = Depends(get_current_user_from_token)):
    return StreamingResponse(generate_mjpeg_stream(camera_id),
                             media_type="multipart/x-mixed-replace; boundary=frame")

# ---- Detection ----
@app.post("/api/detect/{camera_id}")
async def detect_human(camera_id: int, current_user = Depends(admin_required)):
    db = SessionLocal()
    camera = db.query(Camera).filter(Camera.id == camera_id, Camera.is_active == True).first()
    if not camera:
        db.close()
        raise HTTPException(404, "Active camera not found")
    has_human = False
    confidence = 0.0
    num_humans = 0
    try:
        import cv2
        cap = cv2.VideoCapture(camera.rtsp_url)
        ret, frame = cap.read()
        cap.release()
        if ret:
            try:
               hog = cv2.HOGDescriptor()
                hog.setSVMDetector(cv2.HOGDescriptor_getDefaultPeopleDetector())
                boxes, weights = hog.detectMultiScale(frame, winStride=(4,4), padding=(8,8), scale=1.05)
                num_humans = len(boxes)
                has_human = num_humans > 0
                confidence = float(max(weights)) if len(weights) > 0 else 0.0
            except:
                has_human = False
    except:
        pass
    log = DetectionLog(camera_id=camera_id, human_detected=has_human, confidence=confidence, num_humans=num_humans)
    db.add(log)
    if has_human:
        alert = Alert(camera_id=camera_id, alert_type="human_detected",
                      message=f"Manusia terdeteksi! Confidence: {confidence:.2f}, Jumlah: {num_humans}")
        db.add(alert)
    db.commit()
    db.close()
    return {"human_detected": has_human, "confidence": confidence, "num_humans": num_humans}

# ---- Recordings ----
@app.get("/api/recordings")
async def list_recordings(camera_id: int = None, storage_type: str = None,
                          skip: int = 0, limit: int = 100,
                          current_user = Depends(get_current_user_from_token)):
    db = SessionLocal()
    query = db.query(Recording)
    if camera_id:
        query = query.filter(Recording.camera_id == camera_id)
    if storage_type:
        query = query.filter(Recording.storage_type == storage_type)
    recordings = query.order_by(desc(Recording.start_time)).offset(skip).limit(limit).all()
    db.close()
    return recordings

@app.post("/api/recordings/start")
async def start_recording_endpoint(camera_id: int = Query(...), current_user = Depends(admin_required)):
    db = SessionLocal()
    camera = db.query(Camera).filter(Camera.id == camera_id).first()
    if not camera:
        db.close()
        raise HTTPException(404, "Camera not found")
    recordings_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "recordings")
    os.makedirs(recordings_dir, exist_ok=True)
    filename = f"rec_{camera_id}_{int(time.time())}.mp4"
    file_path = os.path.join(recordings_dir, filename)
    rec = Recording(camera_id=camera_id, file_path=file_path, storage_type="local")
    db.add(rec)
    db.commit()
    db.refresh(rec)
    db.close()
    def record_thread():
        import cv2
        cap = cv2.VideoCapture(camera.rtsp_url)
        if not cap.isOpened():
            return
        fps = 25
        w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        fourcc = cv2.VideoWriter_fourcc(*'mp4v')
        out = cv2.VideoWriter(file_path, fourcc, fps, (w, h))
        while True:
            ret, frame = cap.read()
            if not ret:
                break
            out.write(frame)
            time.sleep(1/30)
        cap.release()
        out.release()
        if os.path.exists(file_path):
            size_mb = round(os.path.getsize(file_path) / (1024*1024), 2)
            db = SessionLocal()
            r = db.query(Recording).filter(Recording.id == rec.id).first()
            if r:
                r.end_time = datetime.utcnow()
                r.duration_seconds = int(time.time() - r.start_time.timestamp())
                r.file_size_mb = size_mb
            db.commit()
            db.close()
    thread = threading.Thread(target=record_thread, daemon=True)
    thread.start()
    return {"success": True, "recording_id": rec.id, "file_path": file_path}

@app.post("/api/recordings/stop/{recording_id}")
async def stop_recording_endpoint(recording_id: int, current_user = Depends(admin_required)):
    db = SessionLocal()
    rec = db.query(Recording).filter(Recording.id == recording_id).first()
    if not rec:
        db.close()
        raise HTTPException(404, "Recording not found")
    db.close()
    if os.path.exists(rec.file_path):
        size_mb = round(os.path.getsize(rec.file_path) / (1024*1024), 2)
        db = SessionLocal()
        r = db.query(Recording).filter(Recording.id == recording_id).first()
        if r:
            r.end_time = datetime.utcnow()
            r.duration_seconds = int(time.time() - r.start_time.timestamp())
            r.file_size_mb = size_mb
        db.commit()
        db.close()
        return {"success": True, "file_path": rec.file_path, "file_size_mb": size_mb}
    return {"success": False, "error": "File not found"}

@app.get("/api/recordings/{recording_id}/download")
async def download_recording(recording_id: int, current_user = Depends(get_current_user_from_token)):
    db = SessionLocal()
    rec = db.query(Recording).filter(Recording.id == recording_id).first()
    db.close()
    if not rec or not rec.file_path or not os.path.exists(rec.file_path):
        raise HTTPException(404, "Recording file not found")
    return FileResponse(path=rec.file_path,
                        filename=f"recording_{rec.id}_{rec.camera_id}.mp4",
                        media_type="video/mp4")

@app.post("/api/recordings/{recording_id}/upload")
async def upload_recording(recording_id: int, current_user = Depends(admin_required)):
    db = SessionLocal()
    rec = db.query(Recording).filter(Recording.id == recording_id).first()
    if not rec:
        db.close()
        raise HTTPException(404, "Recording not found")
    # Placeholder - cloud upload logic goes here
    rec.uploaded = True
    rec.cloud_path = f"cloud://{rec.id}"
    db.commit()
    db.close()
    return {"success": True, "message": "Uploaded to cloud (placeholder)", "cloud_path": rec.cloud_path}

@app.delete("/api/recordings/{recording_id}")
async def delete_recording(recording_id: int, current_user = Depends(admin_required)):
    db = SessionLocal()
    rec = db.query(Recording).filter(Recording.id == recording_id).first()
    if not rec:
        db.close()
        raise HTTPException(404, "Recording not found")
    if rec.file_path and os.path.exists(rec.file_path):
        os.remove(rec.file_path)
    db.delete(rec)
    db.commit()
    db.close()
    return {"success": True, "message": "Recording deleted"}

# ---- Alerts ----
@app.get("/api/alerts")
async def list_alerts(current_user = Depends(get_current_user_from_token),
                      unread_only: bool = False):
    db = SessionLocal()
    query = db.query(Alert)
    if unread_only:
        query = query.filter(Alert.read == False)
    alerts = query.order_by(desc(Alert.timestamp)).limit(100).all()
    db.close()
    return alerts

@app.post("/api/alerts/{alert_id}/read")
async def mark_read(alert_id: int, current_user = Depends(get_current_user_from_token)):
    db = SessionLocal()
    alert = db.query(Alert).filter(Alert.id == alert_id).first()
    if alert:
        alert.read = True
        db.commit()
    db.close()
    return {"success": True}

@app.post("/api/alerts/read-all")
async def mark_all_read(current_user = Depends(get_current_user_from_token)):
    db = SessionLocal()
    db.query(Alert).filter(Alert.read == False).update({"read": True})
    db.commit()
    db.close()
    return {"success": True}

@app.post("/api/alerts/{alert_id}/acknowledge")
async def acknowledge_alert(alert_id: int, current_user = Depends(get_current_user_from_token)):
    db = SessionLocal()
    alert = db.query(Alert).filter(Alert.id == alert_id).first()
    if alert:
        alert.acknowledged = True
        alert.acknowledged_by = current_user.id
        alert.acknowledged_at = datetime.utcnow()
        db.commit()
    db.close()
    return {"success": True}

# ---- Users ----
@app.get("/api/users")
async def list_users(search: str = "", role: str = None, is_active: bool = None,
                     skip: int = 0, limit: int = 100,
                     current_user = Depends(get_current_user_from_token)):
    db = SessionLocal()
    query = db.query(User)
    if search:
        query = query.filter(User.username.ilike(f"%{search}%"))
    if role:
        query = query.filter(User.role == role)
    if is_active is not None:
        query = query.filter(User.is_active == is_active)
    users = query.offset(skip).limit(limit).all()
    db.close()
    for u in users:
        u.password_hash = ""
    return users

@app.post("/api/users")
async def create_user(request: Request, current_user = Depends(admin_required)):
    data = await request.form()
    username = data.get("username", "")
    password = data.get("password", "")
    if not username or not password or len(password) < 6:
        raise HTTPException(400, "Username and password (min 6 chars) required")
    db = SessionLocal()
    if db.query(User).filter(User.username == username).first():
        db.close()
        raise HTTPException(400, "Username already exists")
    user = User(
        username=username,
        password_hash=hash_password(password),
        full_name=data.get("full_name", ""),
        email=data.get("email", ""),
        role=data.get("role", "viewer"),
        is_active=data.get("is_active", "true") == "true"
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    user.password_hash = ""
    db.close()
    return {"success": True, "message": "User created", "user": user}

@app.get("/api/users/{user_id}")
async def get_user(user_id: int, current_user = Depends(get_current_user_from_token)):
    db = SessionLocal()
    user = db.query(User).filter(User.id == user_id).first()
    db.close()
    if not user:
        raise HTTPException(404, "User not found")
    user.password_hash = ""
    return user

@app.put("/api/users/{user_id}")
async def update_user(user_id: int, request: Request, current_user = Depends(admin_required)):
    data = await request.form()
    db = SessionLocal()
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        db.close()
        raise HTTPException(404, "User not found")
    if "password" in data and data["password"]:
        if len(data["password"]) < 6:
            db.close()
            raise HTTPException(400, "Password min 6 chars")
        user.password_hash = hash_password(data["password"])
    for key in ["username", "full_name", "email", "role"]:
        if key in data:
            setattr(user, key, data[key])
    if "is_active" in data:
        user.is_active = data["is_active"] == "true"
    db.commit()
    db.refresh(user)
    user.password_hash = ""
    db.close()
    return {"success": True, "message": "User updated", "user": user}

@app.delete("/api/users/{user_id}")
async def delete_user(user_id: int, current_user = Depends(admin_required)):
    if user_id == current_user.id:
        raise HTTPException(400, "Cannot delete yourself")
    db = SessionLocal()
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        db.close()
        raise HTTPException(404, "User not found")
    db.delete(user)
    db.commit()
    db.close()
    return {"success": True, "message": "User deleted"}

@app.post("/api/users/{user_id}/toggle-active")
async def toggle_active(user_id: int, current_user = Depends(admin_required)):
    db = SessionLocal()
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        db.close()
        raise HTTPException(404, "User not found")
    user.is_active = not user.is_active
    db.commit()
    db.close()
    return {"success": True, "is_active": user.is_active}

# ---- Settings ----
@app.get("/api/settings")
async def get_settings_endpoint(current_user = Depends(get_current_user_from_token)):
    s = settings
    return {
        "RTSP_URL_1": s.rtsp_url_1, "RTSP_URL_2": s.rtsp_url_2,
        "LOCAL_SAVE_PATH": s.local_save_path, "MAX_LOCAL_STORAGE_GB": s.max_local_storage_gb,
        "CLOUD_UPLOAD_ENABLED": s.cloud_upload_enabled, "CLOUD_PROVIDER": s.cloud_provider,
        "TELEGRAM_BOT_TOKEN": s.telegram_bot_token, "TELEGRAM_CHAT_ID": s.telegram_chat_id,
        "EMAIL_ENABLED": s.email_enabled, "EMAIL_SENDER": s.email_sender,
        "EMAIL_PASSWORD": s.email_password, "EMAIL_RECIPIENT": s.email_recipient,
        "DETECTION_MODEL_TYPE": s.detection_model_type,
        "DETECTION_CONFIDENCE_THRESHOLD": s.detection_confidence_threshold,
        "DETECTION_INTERVAL": s.detection_interval, "DETECTION_ENABLED": s.detection_enabled,
        "DEBUG": s.debug, "PORT": s.port, "APP_NAME": s.app_name,
    }

@app.put("/api/settings")
async def put_settings(request: Request, current_user = Depends(admin_required)):
    data = await request.json()
    key = data.get("key", "")
    value = data.get("value", "")
    s = settings
    field_map = {
        "RTSP_URL_1": "rtsp_url_1", "RTSP_URL_2": "rtsp_url_2",
        "LOCAL_SAVE_PATH": "local_save_path", "MAX_LOCAL_STORAGE_GB": "max_local_storage_gb",
        "CLOUD_PROVIDER": "cloud_provider", "CLOUD_UPLOAD_ENABLED": "cloud_upload_enabled",
        "TELEGRAM_BOT_TOKEN": "telegram_bot_token", "TELEGRAM_CHAT_ID": "telegram_chat_id",
        "EMAIL_ENABLED": "email_enabled", "EMAIL_SENDER": "email_sender",
        "EMAIL_PASSWORD": "email_password", "EMAIL_RECIPIENT": "email_recipient",
        "DETECTION_MODEL_TYPE": "detection_model_type",
        "DETECTION_CONFIDENCE_THRESHOLD": "detection_confidence_threshold",
        "DETECTION_INTERVAL": "detection_interval", "DETECTION_ENABLED": "detection_enabled",
        "DEBUG": "debug", "PORT": "port", "APP_NAME": "app_name",
    }
    if key not in field_map:
        raise HTTPException(400, f"Unknown setting: {key}")
    setattr(s, field_map[key], value)
    env_file = Path(os.path.dirname(os.path.abspath(__file__))).parent / ".env"
    env_lines = []
    if env_file.exists():
        env_lines = env_file.read_text().splitlines()
    new_lines = []
    for line in env_lines:
        line_key = line.split("=")[0].strip() if "=" in line else ""
        if line_key in field_map and field_map[line_key] == key:
            new_lines.append(f"{line_key}={value}")
        else:
            new_lines.append(line)
    if not any(line.split("=")[0].strip() == key for line in env_lines if "=" in line):
        new_lines.append(f"{key}={value}")
    env_file.write_text("\n".join(new_lines) + "\n")
    return {"success": True, "message": f"Setting {key} saved"}

# ---- Dashboard Template Routing ----
@app.get("/", response_class=HTMLResponse)
async def root(request: Request):
    token = request.cookies.get("auth_token") or request.headers.get("Authorization", "").replace("Bearer ", "")
    if token:
        try:
            payload = verify_token(token)
            db = SessionLocal()
            user = db.query(User).filter(User.id == int(payload["sub"])).first()
            db.close()
            if user:
                return templates.TemplateResponse("dashboard.html", {"request": request, "current_user": user})
        except:
            pass
    return templates.TemplateResponse("login.html", {"request": request})

@app.get("/dashboard", response_class=HTMLResponse)
async def dashboard(request: Request, current_user = Depends(get_current_user_from_token)):
    return templates.TemplateResponse("dashboard.html", {"request": request, "current_user": current_user})

@app.get("/cameras", response_class=HTMLResponse)
async def cameras_page(request: Request, current_user = Depends(get_current_user_from_token)):
    return templates.TemplateResponse("cameras.html", {"request": request, "current_user": current_user})

@app.get("/recordings", response_class=HTMLResponse)
async def recordings_page(request: Request, current_user = Depends(get_current_user_from_token)):
    return templates.TemplateResponse("recordings.html", {"request": request, "current_user": current_user})

@app.get("/alerts", response_class=HTMLResponse)
async def alerts_page(request: Request, current_user = Depends(get_current_user_from_token)):
    return templates.TemplateResponse("alerts.html", {"request": request, "current_user": current_user})

@app.get("/users", response_class=HTMLResponse)
async def users_page(request: Request, current_user = Depends(get_current_user_from_token)):
    return templates.TemplateResponse("users.html", {"request": request, "current_user": current_user})

@app.get("/settings", response_class=HTMLResponse)
async def settings_page(request: Request, current_user = Depends(get_current_user_from_token)):
    return templates.TemplateResponse("settings.html", {"request": request, "current_user": current_user})

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=settings.port, log_level=settings.log_level.lower())
MAINEOF
OK "main.py created"
