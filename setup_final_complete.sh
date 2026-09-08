#!/bin/bash
# ============================================
# CCTV Guardian - Setup Script Final
# Single file, self-contained deployment
# Semua file aplikasi dibuat inline
# ============================================
set -uo pipefail

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
    pydantic-settings \
    ultralytics \
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
    expire = datetime.now(datetime.timezone.utc).replace(tzinfo=None)() + (expires_delta or timedelta(minutes=settings.jwt_expiration_minutes))
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
    created_at = Column(DateTime, default=datetime.now(datetime.timezone.utc).replace(tzinfo=None))
    updated_at = Column(DateTime, default=datetime.now(datetime.timezone.utc).replace(tzinfo=None), onupdate=datetime.now(datetime.timezone.utc).replace(tzinfo=None))
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
    created_at = Column(DateTime, default=datetime.now(datetime.timezone.utc).replace(tzinfo=None))
    updated_at = Column(DateTime, default=datetime.now(datetime.timezone.utc).replace(tzinfo=None), onupdate=datetime.now(datetime.timezone.utc).replace(tzinfo=None))
    owner = relationship("User", back_populates="cameras")

class Recording(Base):
    __tablename__ = "recordings"
    id = Column(Integer, primary_key=True, index=True)
    camera_id = Column(Integer, ForeignKey("cameras.id"))
    start_time = Column(DateTime, default=datetime.now(datetime.timezone.utc).replace(tzinfo=None))
    end_time = Column(DateTime, nullable=True)
    duration_seconds = Column(Integer, nullable=True)
    file_path = Column(String(500), nullable=True)
    file_size_mb = Column(Float, nullable=True)
    storage_type = Column(String(20), default="local")
    cloud_path = Column(String(500), nullable=True)
    uploaded = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.now(datetime.timezone.utc).replace(tzinfo=None))

class DetectionLog(Base):
    __tablename__ = "detection_logs"
    id = Column(Integer, primary_key=True, index=True)
    camera_id = Column(Integer, ForeignKey("cameras.id"))
    timestamp = Column(DateTime, default=datetime.now(datetime.timezone.utc).replace(tzinfo=None))
    human_detected = Column(Boolean, default=False)
    confidence = Column(Float, nullable=True)
    num_humans = Column(Integer, nullable=True)

class Alert(Base):
    __tablename__ = "alerts"
    id = Column(Integer, primary_key=True, index=True)
    camera_id = Column(Integer, ForeignKey("cameras.id"))
    alert_type = Column(String(50), nullable=False)
    message = Column(Text, nullable=True)
    timestamp = Column(DateTime, default=datetime.now(datetime.timezone.utc).replace(tzinfo=None))
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
    except Exception:
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
        is_active=data.get("is_active") != False,
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
        camera.is_active = data["is_active"] != False
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
    except Exception:
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
            except Exception:
                has_human = False
    except Exception:
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
                r.end_time = datetime.now(datetime.timezone.utc).replace(tzinfo=None)()
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
            r.end_time = datetime.now(datetime.timezone.utc).replace(tzinfo=None)()
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
        alert.acknowledged_at = datetime.now(datetime.timezone.utc).replace(tzinfo=None)()
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
        is_active=data.get("is_active") != False
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
        user.is_active = data["is_active"] != False
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
        except Exception:
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


# ============================================
# Step 10.5: Create HTML Templates & Static Files
# ============================================
SEC "10.5: Create HTML Templates & Static Files"

mkdir -p "$APP_DIR/backend/templates" "$APP_DIR/backend/static/css" "$APP_DIR/backend/static/js"

cat > "$APP_DIR/backend/templates/alerts.html" << 'ENDOFFILE8alerts.html'
<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Pemberitahuan - CCTV Guardian</title>
    <link rel="stylesheet" href="/static/css/styles.css">
</head>
<body>
    <div class="layout">
        <aside class="sidebar">
            <div class="sidebar-header">
                <div class="logo"><span class="logo-icon">📹</span><span class="logo-text">CCTV Guardian</span></div>
            </div>
            <nav class="sidebar-nav">
                <a href="/dashboard" class="nav-item"><span class="nav-icon">🏠</span><span class="nav-text">Dashboard</span></a>
                <a href="/cameras" class="nav-item"><span class="nav-icon">📷</span><span class="nav-text">Kamera</span></a>
                <a href="/recordings" class="nav-item"><span class="nav-icon">🎬</span><span class="nav-text">Rekaman</span></a>
                <a href="/alerts" class="nav-item active"><span class="nav-icon">🔔</span><span class="nav-text">Pemberitahuan</span></a>
                <a href="/settings" class="nav-item"><span class="nav-icon">⚙️</span><span class="nav-text">Pengaturan</span></a>
                <a href="/users" class="nav-item"><span class="nav-icon">👥</span><span class="nav-text">Pengguna</span></a>
            </nav>
            <div class="sidebar-footer">
                <div class="user-info"><div class="user-avatar">👤</div>
                <div class="user-details"><div class="user-name">Admin</div><div class="user-role">Administrator</div></div></div>
                <button class="btn-logout" onclick="logout()">Keluar</button>
            </div>
        </aside>
        <main class="main-content">
            <header class="topbar">
                <div class="topbar-left"><h1>Pemberitahuan</h1><span class="breadcrumb">Beranda / Pemberitahuan</span></div>
            </header>
            <div class="content">
                <div class="section-header-row">
                    <h2>Daftar Pemberitahuan</h2>
                </div>
                <div class="alerts-list" id="alertsList"><div class="loading-state">Memuat...</div></div>
            </div>
        </main>
    </div>
    <div id="toastContainer" class="toast-container"></div>
    <script src="/static/js/app.js"></script>
    <script>
    document.addEventListener('DOMContentLoaded', async () => {
        await checkAuth();
        loadAlerts();
    });
    async function loadAlerts() {
        const list = document.getElementById('alertsList');
        try {
            const res = await fetch('/api/alerts');
            const alerts = await res.json();
            if (alerts.length === 0) {
                list.innerHTML = '<div class="empty-state">Tidak ada pemberitahuan</div>';
                return;
            }
            list.innerHTML = alerts.map(a => {
                const icon = a.alert_type.includes('person') ? '🚨' :
                    a.alert_type.includes('vehicle') ? '🚗' : '🔄';
                const typeLabel = a.alert_type.replace(/_/g, ' ').toUpperCase();
                const time = new Date(a.timestamp).toLocaleString('id-ID');
                const statusClass = a.read ? 'read' : 'unread';
                const statusText = a.read ? '○ Dibaca' : '● Belum Dibaca';
                return \`<div class="alert-card \${a.read ? 'read' : 'unread'} alert-\${a.alert_type}">
                    <div class="alert-card-header">
                        <div class="alert-type-badge \${a.alert_type}">\${icon} \${typeLabel}</div>
                        <div class="alert-time">\${time}</div>
                    </div>
                    <div class="alert-card-body">
                        <div class="alert-message">\${a.message || ''}</div>
                        <div class="alert-camera">Kamera: \${a.camera_name || 'Unknown'} #\${a.camera_id}</div>
                    </div>
                    <div class="alert-card-footer">
                        <span class="alert-status \${statusClass}">\${statusText}</span>
                        <div class="alert-actions">
                            <button class="btn btn-sm btn-outline" onclick="acknowledgeAlert(\${a.id})" \${a.acknowledged ? 'disabled' : ''}>✓ Acknowledge</button>
                            <button class="btn btn-sm btn-outline" onclick="markAlertRead(\${a.id})" \${a.read ? 'disabled' : ''}>Baca</button>
                        </div>
                    </div>
                </div>\`;
            }).join('');
        } catch (err) {
            list.innerHTML = '<div class="empty-state">Gagal memuat pemberitahuan</div>';
            showToast('Gagal memuat pemberitahuan', 'error');
        }
    }
    async function acknowledgeAlert(id) {
        try {
            const res = await fetch(\`/api/alerts/\${id}/acknowledge\`, {method:'POST'});
            if (res.ok) { showToast('Pemberitahuan di-acknowledge', 'success'); loadAlerts(); }
            else showToast('Gagal acknowledge', 'error');
        } catch (err) { showToast('Gagal acknowledge', 'error'); }
    }
    async function markAlertRead(id) {
        try {
            const res = await fetch(\`/api/alerts/\${id}/read\`, {method:'POST'});
            if (res.ok) { showToast('Pemberitahuan ditandai sudah dibaca', 'success'); loadAlerts(); }
            else showToast('Gagal tandai dibaca', 'error');
        } catch (err) { showToast('Gagal tandai dibaca', 'error'); }
    }
    async function logout() {
        await fetch('/api/auth/logout', {method:'POST'});
        document.cookie = 'auth_token=; path=/; max-age=0';
        window.location.href = '/';
    }
    </script>
</body>
</html>

ENDOFFILE8alerts.html

cat > "$APP_DIR/backend/templates/dashboard.html" << 'ENDOFFILE8dashboard.html'
<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Dashboard - CCTV Guardian</title>
    <link rel="stylesheet" href="/static/css/styles.css">
</head>
<body>
    <div class="layout">
        <aside class="sidebar">
            <div class="sidebar-header">
                <div class="logo"><span class="logo-icon">📹</span><span class="logo-text">CCTV Guardian</span></div>
            </div>
            <nav class="sidebar-nav">
                <a href="/dashboard" class="nav-item active"><span class="nav-icon">🏠</span><span class="nav-text">Dashboard</span></a>
                <a href="/cameras" class="nav-item"><span class="nav-icon">📷</span><span class="nav-text">Kamera</span></a>
                <a href="/recordings" class="nav-item"><span class="nav-icon">🎬</span><span class="nav-text">Rekaman</span></a>
                <a href="/alerts" class="nav-item"><span class="nav-icon">🔔</span><span class="nav-text">Pemberitahuan</span></a>
                <a href="/settings" class="nav-item"><span class="nav-icon">⚙️</span><span class="nav-text">Pengaturan</span></a>
                <a href="/users" class="nav-item"><span class="nav-icon">👥</span><span class="nav-text">Pengguna</span></a>
            </nav>
            <div class="sidebar-footer">
                <div class="user-info"><div class="user-avatar">👤</div>
                <div class="user-details"><div class="user-name" id="userName">Admin</div><div class="user-role" id="userRole">Administrator</div></div></div>
                <button class="btn-logout" onclick="logout()">Keluar</button>
            </div>
        </aside>
        <main class="main-content">
            <header class="topbar">
                <div class="topbar-left"><h1>Dashboard</h1><span class="breadcrumb">Beranda / Dashboard</span></div>
                <div class="topbar-right"><span class="time-display" id="serverTime">--:--:--</span></div>
            </header>
            <div class="content">
                <div class="stats-grid">
                    <div class="stat-card"><div class="stat-icon" style="background:rgba(52,152,219,0.15);color:#3498db;">📷</div><div class="stat-info"><div class="stat-value" id="statCameras">0</div><div class="stat-label">Total Kamera</div></div></div>
                    <div class="stat-card"><div class="stat-icon" style="background:rgba(46,204,113,0.15);color:#2ecc71;">🎬</div><div class="stat-info"><div class="stat-value" id="statRecordings">0</div><div class="stat-label">Total Rekaman</div></div></div>
                    <div class="stat-card"><div class="stat-icon" style="background:rgba(231,76,60,0.15);color:#e74c3c;">🔔</div><div class="stat-info"><div class="stat-value" id="statAlerts">0</div><div class="stat-label">Pemberitahuan Baru</div></div></div>
                    <div class="stat-card"><div class="stat-icon" style="background:rgba(155,89,182,0.15);color:#9b59b6;">👥</div><div class="stat-info"><div class="stat-value" id="statUsers">0</div><div class="stat-label">Pengguna</div></div></div>
                </div>
                <section class="section">
                    <div class="section-header"><h2>Pemberitahuan Terbaru</h2><a href="/alerts" class="btn btn-sm btn-outline">Lihat Semua</a></div>
                    <div class="alerts-mini" id="alertsMini"><div class="loading-state">Memuat data...</div></div>
                </section>
                <section class="section">
                    <div class="section-header"><h2>Kamera Aktif</h2><a href="/cameras" class="btn btn-sm btn-outline">Kelola Kamera</a></div>
                    <div class="camera-grid" id="cameraGrid"><div class="loading-state">Memuat kamera...</div></div>
                </section>
            </div>
        </main>
    </div>
    <div id="videoModal" class="modal" style="display:none;">
        <div class="modal-content modal-video">
            <div class="modal-header"><h3 id="modalCamName">Kamera</h3><button class="modal-close" onclick="closeVideoModal()">&times;</button></div>
            <div class="video-container"><img id="videoStream" class="video-stream" alt="Video Stream">
                <div class="video-overlay" id="videoOverlay" style="display:none;">
                    <div class="status-badge status-live">● LIVE</div>
                    <div class="rec-status" id="recStatus" style="display:none;"><span class="status-badge status-recording">● REC</span><span class="rec-timer" id="recTimer">00:00:00</span></div>
                </div>
            </div>
            <div class="video-controls">
                <button class="btn btn-sm btn-outline" onclick="startRecord()" id="btnRecord">🔴 Rekaman</button>
                <button class="btn btn-sm btn-outline btn-danger" onclick="stopRecord()" id="btnStopRecord" style="display:none;">⏹ Berhenti</button>
                <button class="btn btn-sm btn-outline" onclick="detectMotion()">👁 Deteksi</button>
                <button class="btn btn-sm btn-outline" onclick="closeVideoModal()">Tutup</button>
            </div>
        </div>
    </div>
    <div id="toastContainer" class="toast-container"></div>
    <script src="/static/js/app.js"></script>
    <script>
    document.addEventListener('DOMContentLoaded', async () => {
        await checkAuth();
        loadDashboard();
        updateServerTime();
        setInterval(updateServerTime, 1000);
    });
    async function loadDashboard() {
        try {
            const [statsRes, alertsRes, camerasRes] = await Promise.all([
                fetch('/api/stats'),
                fetch('/api/alerts?limit=5'),
                fetch('/api/cameras')
            ]);
            if (statsRes.ok) {
                const s = await statsRes.json();
                document.getElementById('statCameras').textContent = s.total_cameras || 0;
                document.getElementById('statRecordings').textContent = s.total_recordings || 0;
                document.getElementById('statAlerts').textContent = s.unread_alerts || 0;
                document.getElementById('statUsers').textContent = s.total_users || 0;
            }
            const alertsEl = document.getElementById('alertsMini');
            if (alertsRes.ok) {
                const alerts = await alertsRes.json();
                alertsEl.innerHTML = alerts.length === 0
                    ? '<div class="empty-state">Tidak ada pemberitahuan</div>'
                    : alerts.map(a => {
                        const icon = a.alert_type.includes('person') ? '🚨' : a.alert_type.includes('vehicle') ? '🚗' : '🔄';
                        return \`<div class="alert-item alert-\${a.alert_type}">
                            <div class="alert-icon">\${icon}</div>
                            <div class="alert-content">
                                <div class="alert-title">\${a.alert_type.replace(/_/g, ' ').toUpperCase()}</div>
                                <div class="alert-message">\${a.message || ''}</div>
                                <div class="alert-time">\${new Date(a.timestamp).toLocaleString('id-ID')}</div>
                            </div>
                        </div>\`;
                    }).join('');
            }
            const camerasEl = document.getElementById('cameraGrid');
            if (camerasRes.ok) {
                const cameras = await camerasRes.json();
                camerasEl.innerHTML = cameras.length === 0
                    ? '<div class="empty-state">Belum ada kamera. <a href="/cameras">Tambah kamera</a></div>'
                    : cameras.map(c => {
                        const isActive = c.is_active;
                        const isRecording = c.is_recording;
                        return \`<div class="camera-card \${isActive ? 'active' : 'inactive'}" onclick="openCamera(\${c.id}, '\${c.name.replace(/'/g, "\\\\'")}')">
                            <div class="camera-preview">
                                <div class="camera-placeholder">
                                    <span class="camera-icon">📷</span>
                                    <span class="camera-name">\${c.name}</span>
                                </div>
                                <div class="rec-badge \${isRecording ? 'show' : 'hide'}">● REC</div>
                            </div>
                            <div class="camera-info">
                                <div class="camera-title">\${c.name}</div>
                                <div class="camera-location">\${c.location || '-'}</div>
                                <div class="camera-status \${isActive ? 'status-active' : 'status-inactive'}">\${isActive ? '● Aktif' : '○ Nonaktif'}</div>
                            </div>
                        </div>\`;
                    }).join('');
            }
        } catch (err) {
            showToast('Gagal memuat dashboard', 'error');
        }
    }
    function updateServerTime() {
        document.getElementById('serverTime').textContent = new Date().toLocaleTimeString('id-ID');
    }
    let cameraWindows = {};
    async function openCamera(cameraId, cameraName) {
        const existing = cameraWindows[cameraId];
        if (existing && !existing.closed) { existing.focus(); return; }
        document.getElementById('modalCamName').textContent = cameraName;
        document.getElementById('videoStream').src = \`/api/cameras/\${cameraId}/stream?t=\${Date.now()}\`;
        document.getElementById('videoModal').style.display = 'flex';
        document.getElementById('btnRecord').style.display = 'inline-block';
        document.getElementById('btnStopRecord').style.display = 'none';
        cameraWindows[cameraId] = { streamUrl: \`/api/cameras/\${cameraId}/stream\` };
    }
    function closeVideoModal() {
        document.getElementById('videoModal').style.display = 'none';
    }
    async function startRecord() {
        const camId = Object.keys(cameraWindows).find(k => cameraWindows[k].streamUrl.includes(k.toString()));
        try {
            const res = await fetch('/api/recordings/start', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({camera_id: parseInt(camId || 1), camera_name: document.getElementById('modalCamName').textContent})
            });
            const data = await res.json();
            if (res.ok) {
                document.getElementById('btnRecord').style.display = 'none';
                document.getElementById('btnStopRecord').style.display = 'inline-block';
                showToast('Rekaman dimulai', 'success');
            } else {
                showToast(data.detail || 'Gagal mulai rekaman', 'error');
            }
        } catch (err) {
            showToast('Gagal memulai rekaman', 'error');
        }
    }
    async function stopRecord() {
        try {
            const res = await fetch('/api/recordings/stop', {method: 'POST'});
            const data = await res.json();
            if (res.ok) {
                document.getElementById('btnRecord').style.display = 'inline-block';
                document.getElementById('btnStopRecord').style.display = 'none';
                showToast('Rekaman berhenti', 'success');
            } else {
                showToast(data.detail || 'Gagal berhenti rekaman', 'error');
            }
        } catch (err) {
            showToast('Gagal berhenti rekaman', 'error');
        }
    }
    async function detectMotion() {
        const camId = Object.keys(cameraWindows).find(k => cameraWindows[k].streamUrl.includes(k.toString()));
        try {
            const res = await fetch(\`/api/cameras/\${camId || 1}/detect\`, {method: 'POST'});
            const data = await res.json();
            if (res.ok) {
                const type = data.human_detected ? 'manusia' : data.vehicle_detected ? 'kendaraan' : data.motion_detected ? 'gerakan' : 'tidak ada';
                showToast(\`Deteksi: \${type}\`, (data.human_detected || data.vehicle_detected || data.motion_detected) ? 'warning' : 'info');
            } else {
                showToast('Gagal deteksi', 'error');
            }
        } catch (err) {
            showToast('Gagal deteksi', 'error');
        }
    }
    async function logout() {
        await fetch('/api/auth/logout', {method: 'POST'});
        document.cookie = 'auth_token=; path=/; max-age=0';
        window.location.href = '/';
    }
    </script>
</body>
</html>

ENDOFFILE8dashboard.html

cat > "$APP_DIR/backend/templates/login.html" << 'ENDOFFILE8login.html'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CCTV Guardian - Login</title>
    <link rel="stylesheet" href="/static/css/styles.css">
</head>
<body>
    <div class="login-container">
        <div class="login-card">
            <h1>CCTV Guardian</h1>
            <p class="subtitle">Akses sistem monitoring</p>
            
            <form id="loginForm">
                <div class="form-group">
                    <label for="username">Username</label>
                    <input type="text" id="username" name="username" required>
                </div>
                
                <div class="form-group">
                    <label for="password">Password</label>
                    <input type="password" id="password" name="password" required>
                </div>
                
                <button type="submit" class="btn btn-primary btn-block">Login</button>
            </form>
            
            <div class="login-help">
                <p><strong>Akun Default:</strong></p>
                <p>Admin: admin / admin123</p>
                <p>Viewer: viewer / viewer123</p>
            </div>
        </div>
    </div>

    <script>
        document.getElementById('loginForm').addEventListener('submit', async function(e) {
            e.preventDefault();
            
            const username = document.getElementById('username').value;
            const password = document.getElementById('password').value;
            
            try {
                const response = await fetch('/api/login', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({ username, password }),
                });
                
                const data = await response.json();
                
                if (response.ok && data.success) {
                    // Store token
                    localStorage.setItem('auth_token', data.token);
                    localStorage.setItem('user', JSON.stringify(data.user));
                    
                    // Redirect to dashboard
                    window.location.href = '/dashboard';
                } else {
                    alert(data.message || 'Login failed. Please check your credentials.');
                }
            } catch (error) {
                console.error('Error:', error);
                alert('Terjadi kesalahan. Silakan coba lagi.');
            }
        });
    </script>
</body>
</html>

ENDOFFILE8login.html

cat > "$APP_DIR/backend/templates/recordings.html" << 'ENDOFFILE8recordings.html'
<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Rekaman - CCTV Guardian</title>
    <link rel="stylesheet" href="/static/css/styles.css">
</head>
<body>
    <div class="layout">
        <aside class="sidebar">
            <div class="sidebar-header">
                <div class="logo"><span class="logo-icon">📹</span><span class="logo-text">CCTV Guardian</span></div>
            </div>
            <nav class="sidebar-nav">
                <a href="/dashboard" class="nav-item"><span class="nav-icon">🏠</span><span class="nav-text">Dashboard</span></a>
                <a href="/cameras" class="nav-item"><span class="nav-icon">📷</span><span class="nav-text">Kamera</span></a>
                <a href="/recordings" class="nav-item active"><span class="nav-icon">🎬</span><span class="nav-text">Rekaman</span></a>
                <a href="/alerts" class="nav-item"><span class="nav-icon">🔔</span><span class="nav-text">Pemberitahuan</span></a>
                <a href="/settings" class="nav-item"><span class="nav-icon">⚙️</span><span class="nav-text">Pengaturan</span></a>
                <a href="/users" class="nav-item"><span class="nav-icon">👥</span><span class="nav-text">Pengguna</span></a>
            </nav>
            <div class="sidebar-footer">
                <div class="user-info"><div class="user-avatar">👤</div>
                <div class="user-details"><div class="user-name">Admin</div><div class="user-role">Administrator</div></div></div>
                <button class="btn-logout" onclick="logout()">Keluar</button>
            </div>
        </aside>
        <main class="main-content">
            <header class="topbar">
                <div class="topbar-left"><h1>Rekaman</h1><span class="breadcrumb">Beranda / Rekaman</span></div>
            </header>
            <div class="content">
                <div class="section-header-row">
                    <h2>Daftar Rekaman</h2>
                </div>
                <div class="table-container">
                    <table class="data-table">
                        <thead><tr>
                            <th>ID</th><th>Kamera</th><th>Mulai</th><th>Selesai</th>
                            <th>Durasi</th><th>Ukuran</th><th>Tipe</th><th>Cloud</th><th>Action</th>
                        </tr></thead>
                        <tbody id="recordingsBody"><tr><td colspan="9" class="empty-row">Memuat...</td></tr></tbody>
                    </table>
                </div>
            </div>
        </main>
    </div>
    <div id="videoModal" class="modal" style="display:none">
        <div class="modal-content">
            <div class="modal-header">
                <h3 id="modalTitle">Rekaman</h3>
                <button class="modal-close" onclick="closeVideoModal()">&times;</button>
            </div>
            <div class="modal-body">
                <video id="videoPlayer" controls width="100%"></video>
            </div>
            <div class="modal-footer">
                <button class="btn btn-outline" onclick="downloadRecording()">⬇ Download MP4</button>
                <button class="btn btn-outline" onclick="closeVideoModal()">Tutup</button>
            </div>
        </div>
    </div>
    <div id="toastContainer" class="toast-container"></div>
    <script src="/static/js/app.js"></script>
    <script>
    document.addEventListener('DOMContentLoaded', async () => {
        await checkAuth();
        loadRecordings();
    });
    async function loadRecordings() {
        const tbody = document.getElementById('recordingsBody');
        try {
            const res = await fetch('/api/recordings');
            const recs = await res.json();
            if (recs.length === 0) {
                tbody.innerHTML = '<tr><td colspan="9" class="empty-row">Belum ada rekaman</td></tr>';
                return;
            }
            tbody.innerHTML = recs.map(r => {
                const start = new Date(r.start_time);
                const end = r.end_time ? new Date(r.end_time) : null;
                const dur = r.duration_seconds ? formatDuration(r.duration_seconds) : '-';
                const size = r.file_size_mb ? r.file_size_mb.toFixed(1)+' MB' : '-';
                const cloudStatus = r.uploaded ? '✅ Uploaded' :
                    (r.cloud_path ? '☁️ Pending' : '💾 Local');
                const playDisabled = !r.file_path ? 'disabled' : '';
                const dlDisabled = !r.file_path ? 'disabled' : '';
                return \`<tr>
                    <td>\${r.id}</td>
                    <td>\${r.camera_name || 'Unknown'}</td>
                    <td title="\${r.start_time}">\${start.toLocaleString('id-ID')}</td>
                    <td title="\${r.end_time}">\${end ? end.toLocaleString('id-ID') : '-'}</td>
                    <td>\${dur}</td>
                    <td>\${size}</td>
                    <td><span class="storage-badge \${r.storage_type}">\${r.storage_type}</span></td>
                    <td>\${r.uploaded ? '<span class="status-badge status-uploaded">✅ Uploaded</span>' : (r.cloud_path ? '<span class="status-badge status-cloud-pending">☁️ Pending</span>' : '<span class="status-badge status-local">💾 Local</span>')}</td>
                    <td>
                        <button class="btn btn-sm btn-outline" onclick="playRecording(\${r.id}, '\${r.camera_name || ''}')" \${playDisabled}>▶ Putar</button>
                        <button class="btn btn-sm btn-outline" onclick="downloadRecordingFile(\${r.id})" \${dlDisabled}>⬇ Download</button>
                        \${r.cloud_path ? \`<a href="\${r.cloud_path}" target="_blank" class="btn btn-sm btn-outline">☁️ Open Cloud</a>\` : '<button class="btn btn-sm btn-outline" onclick="uploadToCloud('+r.id+')">☁️ Upload</button>'}
                        <button class="btn btn-sm btn-danger" onclick="deleteRecording(\${r.id})">🗑</button>
                    </td>
                </tr>\`;
            }).join('');
        } catch (err) {
            tbody.innerHTML = '<tr><td colspan="9" class="empty-row">Gagal memuat rekaman</td></tr>';
            showToast('Gagal memuat rekaman', 'error');
        }
    }
    function formatDuration(sec) {
        const h = Math.floor(sec/3600), m = Math.floor((sec%3600)/60), s = sec%60;
        return h>0 ? \`\${h}h \${m}m \${s}s\` : m>0 ? \`\${m}m \${s}s\` : \`\${s}s\`;
    }
    let currentRecording = null;
    function playRecording(id, camName) {
        currentRecording = { id, camName };
        const video = document.getElementById('videoPlayer');
        video.src = \`/api/recordings/\${id}/stream\`;
        video.play();
        document.getElementById('modalTitle').textContent = \`\${camName} - Rekaman\`;
        document.getElementById('videoModal').style.display = 'flex';
    }
    async function downloadRecordingFile(id) {
        try {
            const res = await fetch(\`/api/recordings/\${id}\`);
            if (!res.ok) { showToast('Gagal download', 'error'); return; }
            const blob = await res.blob();
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url; a.download = \`rec_\${id}.mp4\`; a.click();
            URL.revokeObjectURL(url);
            showToast('Download dimulai', 'success');
        } catch (err) { showToast('Gagal download', 'error'); }
    }
    async function uploadToCloud(id) {
        try {
            const res = await fetch(\`/api/recordings/\${id}/upload\`, {method:'POST'});
            const data = await res.json();
            if (res.ok) { showToast('Upload ke cloud berhasil: '+data.cloud_path, 'success'); loadRecordings(); }
            else showToast(data.message || 'Gagal upload ke cloud', 'error');
        } catch (err) { showToast('Gagal upload', 'error'); }
    }
    async function deleteRecording(id) {
        if (!confirm('Hapus rekaman ini? Tindakan ini tidak dapat dibatalkan.')) return;
        try {
            const res = await fetch(\`/api/recordings/\${id}\`, {method:'DELETE'});
            if (res.ok) { showToast('Rekaman berhasil dihapus', 'success'); loadRecordings(); }
            else showToast('Gagal menghapus rekaman', 'error');
        } catch (err) { showToast('Gagal menghapus rekaman', 'error'); }
    }
    function closeVideoModal() {
        document.getElementById('videoModal').style.display = 'none';
        if (currentRecording) {
            const video = document.getElementById('videoPlayer');
            video.pause(); video.src = '';
            currentRecording = null;
        }
    }
    async function downloadRecording() {
        if (!currentRecording) return;
        await downloadRecordingFile(currentRecording.id);
    }
    async function logout() {
        await fetch('/api/auth/logout', {method:'POST'});
        document.cookie = 'auth_token=; path=/; max-age=0';
        window.location.href = '/';
    }
    </script>
</body>
</html>

ENDOFFILE8recordings.html

cat > "$APP_DIR/backend/templates/settings.html" << 'ENDOFFILE8settings.html'
<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Pengaturan - CCTV Guardian</title>
    <link rel="stylesheet" href="/static/css/styles.css">
</head>
<body>
    <div class="layout">
        <aside class="sidebar">
            <div class="sidebar-header">
                <div class="logo"><span class="logo-icon">📹</span><span class="logo-text">CCTV Guardian</span></div>
            </div>
            <nav class="sidebar-nav">
                <a href="/dashboard" class="nav-item"><span class="nav-icon">🏠</span><span class="nav-text">Dashboard</span></a>
                <a href="/cameras" class="nav-item"><span class="nav-icon">📷</span><span class="nav-text">Kamera</span></a>
                <a href="/recordings" class="nav-item"><span class="nav-icon">🎬</span><span class="nav-text">Rekaman</span></a>
                <a href="/alerts" class="nav-item"><span class="nav-icon">🔔</span><span class="nav-text">Pemberitahuan</span></a>
                <a href="/settings" class="nav-item active"><span class="nav-icon">⚙️</span><span class="nav-text">Pengaturan</span></a>
                <a href="/users" class="nav-item"><span class="nav-icon">👥</span><span class="nav-text">Pengguna</span></a>
            </nav>
            <div class="sidebar-footer">
                <div class="user-info"><div class="user-avatar">👤</div>
                <div class="user-details"><div class="user-name">Admin</div><div class="user-role">Administrator</div></div></div>
                <button class="btn-logout" onclick="logout()">Keluar</button>
            </div>
        </aside>
        <main class="main-content">
            <header class="topbar">
                <div class="topbar-left"><h1>Pengaturan</h1><span class="breadcrumb">Beranda / Pengaturan</span></div>
            </header>
            <div class="content">
                <div class="settings-container">

                    <!-- DETECTION -->
                    <div class="settings-section">
                        <h3>🔍 Pengaturan Deteksi</h3>
                        <div class="settings-group">
                            <div class="setting-row">
                                <div><div class="setting-label">Aktifkan Deteksi</div><div class="setting-desc">Nyalakan/matikan sistem deteksi secara keseluruhan</div></div>
                                <div class="setting-control"><div class="toggle-switch" id="toggleDetection" onclick="toggleSet('DETECTION_ENABLED', this.classList.toggle('active'))"></div></div>
                            </div>
                            <div class="setting-row">
                                <div><div class="setting-label">Model YOLO</div><div class="setting-desc">Pilih model YOLO: yolov8n (cepat), yolov8s (sedang), yolov8m (akurat)</div></div>
                                <div class="setting-control"><select id="setModelType" class="form-select" onchange="saveSet('DETECTION_MODEL_TYPE', this.value)"><option value="yolov8n">yolov8n (Cepat)</option><option value="yolov8s">yolov8s (Sedang)</option><option value="yolov8m">yolov8m (Akurat)</option></select></div>
                            </div>
                            <div class="setting-row">
                                <div><div class="setting-label">Threshold Confidence</div><div class="setting-desc">Minimum confidence (0.0-1.0). Semakin tinggi semakin ketat</div></div>
                                <div class="setting-control"><input type="range" id="setConfThreshold" min="0" max="1" step="0.05" value="0.5" oninput="document.getElementById('confVal').textContent=this.value; saveSet('DETECTION_CONFIDENCE_THRESHOLD', this.value)"><span id="confVal">0.50</span></div>
                            </div>
                            <div class="setting-row">
                                <div><div class="setting-label">Interval Deteksi (detik)</div><div class="setting-desc">Interval antara setiap deteksi. 1 = tiap detik, 5 = tiap 5 detik</div></div>
                                <div class="setting-control"><input type="number" id="setDetectInterval" class="form-input" value="2" min="1" max="60" onchange="saveSet('DETECTION_INTERVAL', this.value)"></div>
                            </div>
                            <div class="setting-divider"></div>
                            <div class="setting-row">
                                <div><div class="setting-label">Deteksi Manusia</div><div class="setting-desc">Aktifkan deteksi manusia (kelas person)</div></div>
                                <div class="setting-control"><div class="toggle-switch" id="togglePerson" onclick="toggleSet('DETECTION_PERSON_ENABLE', this.classList.toggle('active'))"></div></div>
                            </div>
                            <div class="setting-row">
                                <div><div class="setting-label">Deteksi Kendaraan</div><div class="setting-desc">Aktifkan deteksi kendaraan (mobil, motor, bus, truk)</div></div>
                                <div class="setting-control"><div class="toggle-switch" id="toggleVehicle" onclick="toggleSet('DETECTION_VEHICLE_ENABLE', this.classList.toggle('active'))"></div></div>
                            </div>
                            <div class="setting-row">
                                <div><div class="setting-label">Deteksi Gerakan</div><div class="setting-desc">Aktifkan deteksi gerakan (Perubahan Laplacian)</div></div>
                                <div class="setting-control"><div class="toggle-switch" id="toggleMotion" onclick="toggleSet('DETECTION_MOTION_ENABLE', this.classList.toggle('active'))"></div></div>
                            </div>
                            <div class="setting-row">
                                <div><div class="setting-label">Motion Threshold</div><div class="setting-desc">Threshold Laplacian variance. Semakin tinggi semakin sensitif</div></div>
                                <div class="setting-control"><input type="number" id="setMotionThreshold" class="form-input" value="100" min="10" max="10000" onchange="saveSet('MOTION_THRESHOLD', this.value)"></div>
                            </div>
                        </div>
                    </div>

                    <!-- RECORDING -->
                    <div class="settings-section">
                        <h3>🎬 Pengaturan Rekaman</h3>
                        <div class="settings-group">
                            <div class="setting-row">
                                <div><div class="setting-label">Mode Rekaman</div><div class="setting-desc">24 Jam (Continuous) atau Hanya saat Motion (Motion Triggered)</div></div>
                                <div class="setting-control"><select id="setRecMode" class="form-select" onchange="saveSet('RECORDING_MODE', this.value)"><option value="CONTINUOUS">24 Jam (Continuous)</option><option value="MOTION_TRIGGERED">Motion Triggered</option></select></div>
                            </div>
                            <div class="setting-row">
                                <div><div class="setting-label">Durasi Rekaman Motion (detik)</div><div class="setting-desc">Berapa lama merekam setelah motion terdeteksi (hanya untuk mode Motion Triggered)</div></div>
                                <div class="setting-control"><input type="number" id="setMotionRecDur" class="form-input" value="30" min="5" max="3600" onchange="saveSet('MOTION_RECORD_DURATION', this.value)"></div>
                            </div>
                            <div class="setting-row">
                                <div><div class="setting-label">Cooldown Motion (detik)</div><div class="setting-desc">Jeda antar rekaman motion. Mencegah rekaman berulang</div></div>
                                <div class="setting-control"><input type="number" id="setMotionCooldown" class="form-input" value="60" min="5" max="86400" onchange="saveSet('MOTION_COOLDOWN', this.value)"></div>
                            </div>
                        </div>
                    </div>

                    <!-- CLOUD -->
                    <div class="settings-section">
                        <h3>☁️ Penyimpanan Cloud</h3>
                        <div class="settings-group">
                            <div class="setting-row">
                                <div><div class="setting-label">Aktifkan Upload Cloud</div><div class="setting-desc">Upload rekaman ke cloud otomatis</div></div>
                                <div class="setting-control"><div class="toggle-switch" id="toggleCloud" onclick="toggleSet('CLOUD_UPLOAD_ENABLED', this.classList.toggle('active')); updateGDriveFields();"></div></div>
                            </div>
                            <div class="setting-row">
                                <div><div class="setting-label">Provider Cloud</div><div class="setting-desc">Pilih provider cloud untuk upload rekaman</div></div>
                                <div class="setting-control"><select id="setCloudProv" class="form-select" onchange="saveSet('CLOUD_PROVIDER', this.value); updateGDriveFields();"><option value="none">None (Penyimpanan Lokal Only)</option><option value="googledrive">Google Drive</option><option value="s3">Amazon S3 / S3 Compatible</option><option value="nextcloud">Nextcloud</option></select></div>
                            </div>
                            <div id="gdriveCredentials" style="display:none;">
                                <div class="setting-divider"></div>
                                <div class="form-group"><label>Client ID</label><input type="text" id="setGDriveCID" value="" placeholder="xxx.apps.googleusercontent.com" onchange="saveSet('GOOGLE_DRIVE_CLIENT_ID', this.value)" class="form-input"></div>
                                <div class="form-group"><label>Client Secret</label><input type="password" id="setGDriveCS" value="" placeholder="••••••••" onchange="saveSet('GOOGLE_DRIVE_CLIENT_SECRET', this.value)" class="form-input"></div>
                                <div class="form-group"><label>Refresh Token</label><input type="password" id="setGDriveRT" value="" placeholder="1//0e..." onchange="saveSet('GOOGLE_DRIVE_REFRESH_TOKEN', this.value)" class="form-input"><div class="setting-desc">Dari OAuth consent screen. <a href="https://developers.google.com/drive/api/guides/about-auth" target="_blank" style="color:#3498db;">Cara dapatkan →</a></div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- TELEGRAM -->
                    <div class="settings-section">
                        <h3>💬 Telegram Bot</h3>
                        <div class="settings-group">
                            <div class="setting-row">
                                <div><div class="setting-label">Aktifkan Notifikasi Telegram</div><div class="setting-desc">Kirim notifikasi ke Telegram saat ada deteksi</div></div>
                                <div class="setting-control"><div class="toggle-switch" id="toggleTelegram" onclick="toggleSet('TELEGRAM_ENABLED', this.classList.toggle('active'))"></div></div>
                            </div>
                            <div class="form-group"><label>Bot Token</label><input type="password" id="setTGToken" value="" placeholder="1234567890:ABCdefGHIjklMNOpqrSTUvwxYZ" onchange="saveSet('TELEGRAM_BOT_TOKEN', this.value)" class="form-input"><div class="setting-desc">Dari @BotFather. Buat bot baru di <a href="https://t.me/BotFather" target="_blank" style="color:#3498db;">@BotFather</a></div></div>
                            <div class="form-group"><label>Chat ID</label><input type="text" id="setTGCHat" value="" placeholder="-123456789" onchange="saveSet('TELEGRAM_CHAT_ID', this.value)" class="form-input"><div class="setting-desc">Chat ID tujuan notifikasi. Kirim pesan ke bot dan cek log untuk mendapatkan chat ID Anda.</div></div>
                        </div>
                    </div>

                    <!-- EMAIL -->
                    <div class="settings-section">
                        <h3>📧 Email Notifikasi</h3>
                        <div class="settings-group">
                            <div class="setting-row">
                                <div><div class="setting-label">Aktifkan Email</div><div class="setting-desc">Kirim notifikasi via email</div></div>
                                <div class="setting-control"><div class="toggle-switch" id="toggleEmail" onclick="toggleSet('EMAIL_ENABLED', this.classList.toggle('active'))"></div></div>
                            </div>
                            <div class="form-group"><label>SMTP Server</label><input type="text" id="setSMTP" value="smtp.gmail.com" onchange="saveSet('EMAIL_SMTP', this.value)" class="form-input"></div>
                            <div class="form-group"><label>Port</label><input type="number" id="setSMTPPort" value="587" onchange="saveSet('EMAIL_SMTP_PORT', this.value)" class="form-input"></div>
                            <div class="form-group"><label>Username</label><input type="text" id="setEmailUser" value="" onchange="saveSet('EMAIL_USERNAME', this.value)" class="form-input"></div>
                            <div class="form-group"><label>Password (App Password)</label><input type="password" id="setEmailPass" value="" onchange="saveSet('EMAIL_PASSWORD', this.value)" class="form-input"></div>
                            <div class="form-group"><label>Email Tujuan</label><input type="email" id="setEmailTo" value="" onchange="saveSet('EMAIL_RECIPIENT', this.value)" class="form-input"></div>
                        </div>
                    </div>

                    <!-- STORAGE -->
                    <div class="settings-section">
                        <h3>💾 Penyimpanan Lokal</h3>
                        <div class="settings-group">
                            <div class="setting-row">
                                <div><div class="setting-label">Path Rekaman</div><div class="setting-desc">Lokasi penyimpanan rekaman di server</div></div>
                                <div class="setting-control"><input type="text" id="setSavePath" value="/opt/cctv-guardian/recordings" onchange="saveSet('LOCAL_SAVE_PATH', this.value)" class="form-input"></div>
                            </div>
                            <div class="setting-row">
                                <div><div class="setting-label">Maksimum Storage (GB)</div><div class="setting-desc">Maksimum storage yang digunakan. Rekaman lama dihapus otomatis jika melebihi threshold</div></div>
                                <div class="setting-control"><input type="number" id="setMaxStorage" class="form-input" value="50" min="1" max="9999" onchange="saveSet('MAX_LOCAL_STORAGE_GB', this.value)"></div>
                            </div>
                            <div class="storage-usage-bar">
                                <div class="storage-label"><span>Penggunaan Storage saat ini</span><span id="storagePercent">0%</span></div>
                                <div class="storage-bar-bg"><div class="storage-bar-fill" id="storageBarFill" style="width:0%"></div></div>
                                <div class="storage-info"><span id="storageUsed">0 GB</span> / <span id="storageTotal">50 GB</span></div>
                            </div>
                        </div>
                    </div>

                </div>
            </div>
        </main>
    </div>
    <div id="toastContainer" class="toast-container"></div>
    <script src="/static/js/app.js"></script>
    <script>
    document.addEventListener('DOMContentLoaded', async () => {
        await checkAuth();
        await loadSettings();
        updateStorageBar();
        updateGDriveFields();
        setInterval(updateStorageBar, 30000);
        document.getElementById('setCloudProv').addEventListener('change', updateGDriveFields);
    });
    function updateGDriveFields() {
        const prov = document.getElementById('setCloudProv').value;
        const gdriveDiv = document.getElementById('gdriveCredentials');
        if (gdriveDiv) gdriveDiv.style.display = (prov === 'googledrive') ? 'block' : 'none';
        const provStatus = document.getElementById('cloudProviderStatus');
        if (provStatus) provStatus.textContent = prov === 'googledrive' ? '🟢 Google Drive' : '🔴 None / Other';
    }
    async function logout() {
        await fetch('/api/auth/logout', {method:'POST'});
        document.cookie = 'auth_token=; path=/; max-age=0';
        window.location.href = '/';
    }
    </script>
</body>
</html>

ENDOFFILE8settings.html

cat > "$APP_DIR/backend/templates/users.html" << 'ENDOFFILE8users.html'
<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Pengguna - CCTV Guardian</title>
    <link rel="stylesheet" href="/static/css/styles.css">
</head>
<body>
    <div class="layout">
        <aside class="sidebar">
            <div class="sidebar-header">
                <div class="logo"><span class="logo-icon">📹</span><span class="logo-text">CCTV Guardian</span></div>
            </div>
            <nav class="sidebar-nav">
                <a href="/dashboard" class="nav-item"><span class="nav-icon">🏠</span><span class="nav-text">Dashboard</span></a>
                <a href="/cameras" class="nav-item"><span class="nav-icon">📷</span><span class="nav-text">Kamera</span></a>
                <a href="/recordings" class="nav-item"><span class="nav-icon">🎬</span><span class="nav-text">Rekaman</span></a>
                <a href="/alerts" class="nav-item"><span class="nav-icon">🔔</span><span class="nav-text">Pemberitahuan</span></a>
                <a href="/settings" class="nav-item"><span class="nav-icon">⚙️</span><span class="nav-text">Pengaturan</span></a>
                <a href="/users" class="nav-item active"><span class="nav-icon">👥</span><span class="nav-text">Pengguna</span></a>
            </nav>
            <div class="sidebar-footer">
                <div class="user-info"><div class="user-avatar">👤</div>
                <div class="user-details"><div class="user-name">Admin</div><div class="user-role">Administrator</div></div></div>
                <button class="btn-logout" onclick="logout()">Keluar</button>
            </div>
        </aside>
        <main class="main-content">
            <header class="topbar">
                <div class="topbar-left"><h1>Pengguna</h1><span class="breadcrumb">Beranda / Pengguna</span></div>
            </header>
            <div class="content">
                <div class="section-header-row">
                    <h2>Daftar Pengguna</h2>
                    <button class="btn btn-primary" onclick="showAddUserModal()">+ Tambah Pengguna</button>
                </div>
                <div class="table-container">
                    <table class="data-table">
                        <thead><tr>
                            <th>ID</th><th>Username</th><th>Nama Lengkap</th><th>Email</th>
                            <th>Role</th><th>Status</th><th>Action</th>
                        </tr></thead>
                        <tbody id="usersBody"><tr><td colspan="7" class="empty-row">Memuat...</td></tr></tbody>
                    </table>
                </div>
            </div>
        </main>
    </div>
    <div id="userModal" class="modal" style="display:none">
        <div class="modal-content">
            <div class="modal-header">
                <h3 id="modalTitle">Tambah Pengguna</h3>
                <button class="modal-close" onclick="closeUserModal()">&times;</button>
            </div>
            <div class="modal-body">
                <form id="userForm" class="form">
                    <input type="hidden" id="usrId">
                    <div class="form-group"><label>Username</label><input type="text" id="usrUsername" required placeholder="username"></div>
                    <div class="form-group"><label>Password</label><input type="password" id="usrPassword" required placeholder="Minimum 6 karakter"><div class="form-hint">Masukkan jika mengubah password</div></div>
                    <div class="form-group"><label>Nama Lengkap</label><input type="text" id="usrFullName" placeholder="Nama lengkap pengguna"></div>
                    <div class="form-group"><label>Email</label><input type="email" id="usrEmail" placeholder="email@example.com"></div>
                    <div class="form-group"><label>Role</label><select id="usrRole" class="form-select"><option value="admin">Administrator</option><option value="viewer">Viewer (Lihat Only)</option></select></div>
                    <div class="form-group"><label>Status Aktif</label><label class="toggle-switch-label"><input type="checkbox" id="usrActive" checked><span class="toggle-switch"></span></label></div>
                </form>
            </div>
            <div class="modal-footer">
                <button class="btn btn-outline" onclick="closeUserModal()">Batal</button>
                <button class="btn btn-primary" onclick="saveUser()">Simpan</button>
            </div>
        </div>
    </div>
    <div id="toastContainer" class="toast-container"></div>
    <script src="/static/js/app.js"></script>
    <script>
    document.addEventListener('DOMContentLoaded', async () => {
        await checkAuth();
        loadUsers();
    });
    async function loadUsers() {
        const tbody = document.getElementById('usersBody');
        try {
            const res = await fetch('/api/users');
            const users = await res.json();
            if (users.length === 0) {
                tbody.innerHTML = '<tr><td colspan="7" class="empty-row">Belum ada pengguna</td></tr>';
                return;
            }
            tbody.innerHTML = users.map(u => {
                const roleClass = u.role;
                const statusClass = u.is_active ? 'status-active' : 'status-inactive';
                const statusText = u.is_active ? '● Aktif' : '○ Nonaktif';
                return \`<tr>
                    <td>\${u.id}</td>
                    <td><strong>\${u.username}</strong></td>
                    <td>\${u.full_name || '-'}</td>
                    <td>\${u.email || '-'}</td>
                    <td><span class="role-badge \${roleClass}">\${u.role}</span></td>
                    <td><span class="status-badge \${statusClass}">\${statusText}</span></td>
                    <td>
                        <button class="btn btn-sm btn-outline" onclick="editUser(\${u.id})">Edit</button>
                        <button class="btn btn-sm btn-danger" onclick="deleteUser(\${u.id})" \${currentUserId===u.id ? 'disabled' : ''}>Hapus</button>
                    </td>
                </tr>\`;
            }).join('');
        } catch (err) {
            tbody.innerHTML = '<tr><td colspan="7" class="empty-row">Gagal memuat data pengguna</td></tr>';
            showToast('Gagal memuat pengguna', 'error');
        }
    }
    function showAddUserModal() {
        document.getElementById('modalTitle').textContent = 'Tambah Pengguna';
        document.getElementById('userForm').reset();
        document.getElementById('usrId').value = '';
        document.getElementById('userModal').style.display = 'flex';
    }
    async function editUser(id) {
        try {
            const res = await fetch(\`/api/users/\${id}\`);
            const u = await res.json();
            document.getElementById('modalTitle').textContent = 'Edit Pengguna';
            document.getElementById('usrId').value = u.id;
            document.getElementById('usrUsername').value = u.username;
            document.getElementById('usrFullName').value = u.full_name || '';
            document.getElementById('usrEmail').value = u.email || '';
            document.getElementById('usrRole').value = u.role;
            document.getElementById('usrActive').checked = u.is_active;
            document.getElementById('userModal').style.display = 'flex';
        } catch (err) { showToast('Gagal memuat data pengguna', 'error'); }
    }
    function closeUserModal() {
        document.getElementById('userModal').style.display = 'none';
    }
    async function saveUser() {
        const data = {
            username: document.getElementById('usrUsername').value,
            password: document.getElementById('usrPassword').value,
            full_name: document.getElementById('usrFullName').value,
            email: document.getElementById('usrEmail').value,
            role: document.getElementById('usrRole').value,
            is_active: document.getElementById('usrActive').checked
        };
        const id = document.getElementById('usrId').value;
        try {
            const url = id ? \`/api/users/\${id}\` : '/api/users';
            const method = id ? 'PUT' : 'POST';
            const res = await fetch(url, {
                method,
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify(data)
            });
            const result = await res.json();
            if (res.ok) {
                showToast(id ? 'Pengguna berhasil diperbarui' : 'Pengguna berhasil ditambahkan', 'success');
                closeUserModal();
                loadUsers();
            } else {
                showToast(result.detail || 'Gagal menyimpan pengguna', 'error');
            }
        } catch (err) { showToast('Gagal menyimpan pengguna', 'error'); }
    }
    async function deleteUser(id) {
        if (!confirm('Hapus pengguna ini? Tindakan ini tidak dapat dibatalkan.')) return;
        try {
            const res = await fetch(\`/api/users/\${id}\`, {method:'DELETE'});
            if (res.ok) { showToast('Pengguna berhasil dihapus', 'success'); loadUsers(); }
            else showToast('Gagal menghapus pengguna', 'error');
        } catch (err) { showToast('Gagal menghapus pengguna', 'error'); }
    }
    async function logout() {
        await fetch('/api/auth/logout', {method:'POST'});
        document.cookie = 'auth_token=; path=/; max-age=0';
        window.location.href = '/';
    }
    </script>
</body>
</html>

ENDOFFILE8users.html

cat > "$APP_DIR/backend/static/css/styles.css" << 'ENDOFFILE8styles.css'
/* ============================================
   CCTV Guardian - Stylesheet
   ============================================ */

:root {
    --primary: #2c3e50;
    --primary-light: #34495e;
    --accent: #3498db;
    --accent-hover: #2980b9;
    --success: #2ecc71;
    --warning: #f39c12;
    --danger: #e74c3c;
    --bg: #f5f6fa;
    --sidebar-bg: #2c3e50;
    --sidebar-text: #ecf0f1;
    --card-bg: #ffffff;
    --border: #e0e6ed;
    --text: #2c3e50;
    --text-light: #7f8c8d;
    --radius: 8px;
    --shadow: 0 2px 8px rgba(0,0,0,0.08);
    --shadow-lg: 0 4px 16px rgba(0,0,0,0.12);
}

* { margin:0; padding:0; box-sizing:border-box; }

body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.5;
    min-height: 100vh;
}

/* ============================================
   LAYOUT
   ============================================ */

.layout { display:flex; min-height:100vh; }

/* SIDEBAR */

.sidebar {
    width: 250px;
    background: var(--sidebar-bg);
    color: var(--sidebar-text);
    display: flex;
    flex-direction: column;
    position: fixed;
    top: 0; left: 0; bottom: 0;
    z-index: 100;
    transition: transform 0.3s;
}

.sidebar-header {
    padding: 20px 20px 15px;
    border-bottom: 1px solid rgba(255,255,255,0.1);
}

.logo {
    display: flex;
    align-items: center;
    gap: 10px;
}

.logo-icon { font-size: 28px; }

.logo-text {
    font-size: 18px;
    font-weight: 700;
    color: #fff;
    letter-spacing: 0.5px;
}

.sidebar-nav {
    flex: 1;
    padding: 15px 0;
    overflow-y: auto;
}

.nav-item {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 20px;
    color: var(--sidebar-text);
    text-decoration: none;
    transition: all 0.2s;
    border-left: 3px solid transparent;
    margin: 2px 10px;
    border-radius: 0 8px 8px 0;
}

.nav-item:hover {
    background: rgba(255,255,255,0.08);
    border-left-color: var(--accent);
}

.nav-item.active {
    background: rgba(52,152,219,0.2);
    border-left-color: var(--accent);
    color: #fff;
}

.nav-icon { font-size: 18px; }
.nav-text { font-size: 14px; font-weight: 500; }

.sidebar-footer {
    padding: 15px 20px;
    border-top: 1px solid rgba(255,255,255,0.1);
}

.user-info {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 10px;
}

.user-avatar {
    width: 36px;
    height: 36px;
    background: var(--accent);
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 18px;
}

.user-name {
    font-size: 14px;
    font-weight: 600;
    color: #fff;
}

.user-role {
    font-size: 12px;
    color: var(--text-light);
}

.btn-logout {
    width: 100%;
    padding: 8px;
    background: rgba(255,255,255,0.1);
    border: 1px solid rgba(255,255,255,0.2);
    color: var(--sidebar-text);
    border-radius: 6px;
    cursor: pointer;
    font-size: 13px;
    transition: all 0.2s;
}

.btn-logout:hover {
    background: var(--danger);
    border-color: var(--danger);
    color: #fff;
}

/* MAIN CONTENT */

.main-content {
    flex: 1;
    margin-left: 250px;
    padding: 0;
    min-height: 100vh;
}

/* TOPBAR */

.topbar {
    background: var(--card-bg);
    padding: 15px 30px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 1px solid var(--border);
    position: sticky;
    top: 0;
    z-index: 50;
}

.topbar-left h1 {
    font-size: 22px;
    font-weight: 700;
    color: var(--primary);
}

.breadcrumb {
    font-size: 13px;
    color: var(--text-light);
    margin-left: 10px;
}

.topbar-right .time-display {
    font-size: 14px;
    font-weight: 600;
    color: var(--text-light);
    font-family: 'Courier New', monospace;
}

/* ============================================
   CONTENT
   ============================================ */

.content { padding: 25px 30px; }

.section-header-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 20px;
}

.section-header-row h2 {
    font-size: 18px;
    font-weight: 700;
    color: var(--primary);
}

.filter-row {
    display: flex;
    gap: 10px;
    align-items: center;
}

/* ============================================
   BUTTONS
   ============================================ */

.btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    padding: 8px 16px;
    border: none;
    border-radius: 6px;
    font-size: 14px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.2s;
    text-decoration: none;
}

.btn-primary { background: var(--accent); color: #fff; }
.btn-primary:hover { background: var(--accent-hover); transform: translateY(-1px); }

.btn-outline {
    background: transparent;
    border: 1px solid var(--border);
    color: var(--text);
}
.btn-outline:hover { background: var(--bg); border-color: var(--text-light); }

.btn-danger { background: var(--danger); color: #fff; }
.btn-danger:hover { background: #c0392b; }

.btn-sm { padding: 5px 12px; font-size: 12px; }
.btn-full { width: 100%; }
.btn:disabled { opacity: 0.5; cursor: not-allowed; }

/* ============================================
   FORM
   ============================================ */

.form-group { margin-bottom: 15px; }

.form-group label {
    display: block;
    font-size: 13px;
    font-weight: 600;
    color: var(--text);
    margin-bottom: 5px;
}

.form-input, .form-select {
    width: 100%;
    padding: 9px 12px;
    border: 1px solid var(--border);
    border-radius: 6px;
    font-size: 14px;
    color: var(--text);
    background: #fff;
    transition: border-color 0.2s;
}

.form-input:focus, .form-select:focus {
    outline: none;
    border-color: var(--accent);
    box-shadow: 0 0 0 3px rgba(52,152,219,0.1);
}

.form-hint { font-size: 11px; color: var(--text-light); margin-top: 3px; }

.form { max-width: 500px; }

/* TOGGLE SWITCH */

.toggle-switch-label {
    display: inline-flex;
    align-items: center;
    gap: 10px;
    cursor: pointer;
    font-size: 14px;
    color: var(--text);
}

.toggle-switch-label input { display: none; }

.toggle-switch {
    width: 44px;
    height: 24px;
    background: #bdc3c7;
    border-radius: 12px;
    position: relative;
    transition: background 0.3s;
}

.toggle-switch::after {
    content: '';
    position: absolute;
    width: 20px;
    height: 20px;
    background: #fff;
    border-radius: 50%;
    top: 2px;
    left: 2px;
    transition: transform 0.3s;
    box-shadow: 0 2px 4px rgba(0,0,0,0.2);
}

.toggle-switch-label input:checked + .toggle-switch { background: var(--accent); }
.toggle-switch-label input:checked + .toggle-switch::after { transform: translateX(20px); }

.active.toggle-switch { background: var(--accent); }
.active.toggle-switch::after { transform: translateX(20px); }

/* ============================================
   STATS GRID
   ============================================ */

.stats-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 20px;
    margin-bottom: 25px;
}

.stat-card {
    background: var(--card-bg);
    border-radius: var(--radius);
    padding: 20px;
    box-shadow: var(--shadow);
    display: flex;
    align-items: center;
    gap: 15px;
    transition: transform 0.2s, box-shadow 0.2s;
}

.stat-card:hover {
    transform: translateY(-2px);
    box-shadow: var(--shadow-lg);
}

.stat-icon {
    width: 48px;
    height: 48px;
    border-radius: 12px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 24px;
}

.stat-info { flex: 1; }

.stat-value {
    font-size: 28px;
    font-weight: 800;
    color: var(--primary);
    line-height: 1;
}

.stat-label {
    font-size: 13px;
    color: var(--text-light);
    margin-top: 4px;
}

/* ============================================
   TABLE
   ============================================ */

.table-container {
    background: var(--card-bg);
    border-radius: var(--radius);
    box-shadow: var(--shadow);
    overflow: hidden;
}

.data-table {
    width: 100%;
    border-collapse: collapse;
}

.data-table th {
    background: var(--primary);
    color: #fff;
    padding: 12px 15px;
    text-align: left;
    font-size: 13px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.data-table td {
    padding: 12px 15px;
    border-bottom: 1px solid var(--border);
    font-size: 14px;
}

.data-table tr:hover td { background: rgba(52,152,219,0.04); }

.data-table .empty-row {
    text-align: center;
    color: var(--text-light);
    padding: 30px !important;
    font-style: italic;
}

.mono { font-family: 'Courier New', monospace; font-size: 12px; color: var(--text-light); }

/* ============================================
   STATUS BADGES
   ============================================ */

.status-badge {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 10px;
    border-radius: 20px;
    font-size: 12px;
    font-weight: 600;
}

.status-active { background: rgba(46,204,113,0.12); color: #27ae60; }
.status-inactive { background: rgba(127,140,141,0.12); color: #7f8c8d; }
.status-live { background: rgba(46,204,113,0.15); color: #27ae60; animation: pulse 2s infinite; }
.status-recording { background: rgba(231,76,60,0.15); color: #e74c3c; animation: pulse 1s infinite; }
.status-uploaded { background: rgba(46,204,113,0.12); color: #27ae60; }
.status-cloud-pending { background: rgba(241,196,15,0.12); color: #d4a017; }
.status-local { background: rgba(52,152,219,0.12); color: #2980b9; }

.role-badge {
    padding: 3px 10px;
    border-radius: 20px;
    font-size: 12px;
    font-weight: 600;
}

.role-badge.admin { background: rgba(155,89,182,0.12); color: #8e44ad; }
.role-badge.viewer { background: rgba(52,152,219,0.12); color: #2980b9; }

.storage-badge {
    padding: 3px 10px;
    border-radius: 20px;
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
}

.storage-badge.local { background: rgba(52,152,219,0.12); color: #2980b9; }
.storage-badge.cloud { background: rgba(46,204,113,0.12); color: #27ae60; }

/* ============================================
   ALERTS
   ============================================ */

.alerts-mini {
    background: var(--card-bg);
    border-radius: var(--radius);
    box-shadow: var(--shadow);
    padding: 15px;
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.alert-item {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    padding: 12px;
    border-radius: 8px;
    background: #fff;
    border-left: 3px solid var(--accent);
}

.alert-item.alert-person_detected { border-left-color: var(--danger); }
.alert-item.alert-vehicle_detected { border-left-color: var(--warning); }
.alert-item.alert-motion_detected { border-left-color: var(--text-light); }

.alert-icon { font-size: 24px; flex-shrink: 0; }
.alert-content { flex: 1; }
.alert-title {
    font-size: 13px;
    font-weight: 700;
    color: var(--text);
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin-bottom: 2px;
}
.alert-message { font-size: 13px; color: var(--text-light); margin-bottom: 4px; }
.alert-time { font-size: 11px; color: var(--text-light); font-family: 'Courier New', monospace; }

.alerts-list { display: flex; flex-direction: column; gap: 12px; }

.alert-card {
    background: var(--card-bg);
    border-radius: var(--radius);
    box-shadow: var(--shadow);
    overflow: hidden;
    border-left: 4px solid var(--accent);
}

.alert-card.unread { border-left-color: var(--danger); background: #fff8f8; }

.alert-cardHeader {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 15px;
    background: var(--bg);
    border-bottom: 1px solid var(--border);
}

.alert-type-badge {
    padding: 4px 12px;
    border-radius: 20px;
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.alert-person_detected .alert-type-badge { background: rgba(231,76,60,0.15); color: #e74c3c; }
.alert-vehicle_detected .alert-type-badge { background: rgba(241,196,15,0.15); color: #d4a017; }
.alert-motion_detected .alert-type-badge { background: rgba(127,140,141,0.15); color: #7f8c8d; }

.alert-card-body { padding: 15px; }
.alert-message { font-size: 14px; color: var(--text); margin-bottom: 8px; line-height: 1.5; }
.alert-camera { font-size: 12px; color: var(--text-light); }

.alert-card-footer {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 10px 15px;
    border-top: 1px solid var(--border);
    background: var(--bg);
}

.alert-status { font-size: 12px; font-weight: 600; }
.alert-status.unread { color: var(--danger); }
.alert-status.read { color: var(--text-light); }

.alert-actions { display: flex; gap: 8px; }

/* ============================================
   SETTINGS
   ============================================ */

.settings-container {
    max-width: 800px;
    background: var(--card-bg);
    border-radius: var(--radius);
    box-shadow: var(--shadow);
    padding: 25px;
}

.settings-section {
    margin-bottom: 25px;
    padding-bottom: 20px;
    border-bottom: 1px solid var(--border);
}

.settings-section:last-child {
    border-bottom: none;
    margin-bottom: 0;
    padding-bottom: 0;
}

.settings-section h3 {
    font-size: 16px;
    font-weight: 700;
    color: var(--primary);
    margin-bottom: 15px;
    padding-bottom: 8px;
    border-bottom: 2px solid var(--accent);
}

.settings-group { display: flex; flex-direction: column; gap: 8px; }

.setting-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 0;
}

.setting-label { font-size: 14px; font-weight: 600; color: var(--text); }
.setting-desc { font-size: 12px; color: var(--text-light); margin-top: 2px; }
.setting-control { flex-shrink: 0; }
.setting-divider { height: 1px; background: var(--border); margin: 10px 0; }

/* STORAGE BAR */

.storage-usage-bar { margin-top: 15px; }

.storage-label {
    display: flex;
    justify-content: space-between;
    font-size: 13px;
    color: var(--text-light);
    margin-bottom: 6px;
}

.storage-bar-bg {
    height: 12px;
    background: var(--border);
    border-radius: 6px;
    overflow: hidden;
}

.storage-bar-fill {
    height: 100%;
    background: linear-gradient(90deg, var(--success), var(--warning), var(--danger));
    border-radius: 6px;
    transition: width 0.5s ease;
}

.storage-info {
    font-size: 12px;
    color: var(--text-light);
    margin-top: 4px;
    font-family: 'Courier New', monospace;
}

/* ============================================
   VIDEO GRID
   ============================================ */

.camera-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 20px;
}

.camera-card {
    background: var(--card-bg);
    border-radius: var(--radius);
    box-shadow: var(--shadow);
    overflow: hidden;
    cursor: pointer;
    transition: transform 0.2s, box-shadow 0.2s;
    border: 2px solid transparent;
}

.camera-card:hover {
    transform: translateY(-3px);
    box-shadow: var(--shadow-lg);
}

.camera-card.active { border-color: var(--success); }
.camera-card.inactive { opacity: 0.7; }

.camera-preview {
    position: relative;
    height: 160px;
    background: var(--primary);
    display: flex;
    align-items: center;
    justify-content: center;
}

.camera-placeholder {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    color: rgba(255,255,255,0.5);
}

.camera-icon { font-size: 40px; }
.camera-name { font-size: 16px; font-weight: 600; color: rgba(255,255,255,0.8); }

.rec-badge {
    position: absolute;
    top: 10px;
    right: 10px;
    background: var(--danger);
    color: #fff;
    padding: 3px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 700;
    animation: pulse 1s infinite;
}

.rec-badge.hide { display: none; }

.camera-info { padding: 12px 15px; }
.camera-title { font-size: 15px; font-weight: 700; color: var(--text); margin-bottom: 3px; }
.camera-location { font-size: 12px; color: var(--text-light); margin-bottom: 6px; }
.camera-status { font-size: 12px; font-weight: 600; }
.camera-status.status-active { color: var(--success); }
.camera-status.status-inactive { color: var(--text-light); }

/* ============================================
   VIDEO MODAL
   ============================================ */

.modal {
    position: fixed;
    top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0,0,0,0.7);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 200;
    backdrop-filter: blur(4px);
}

.modal-content {
    background: var(--card-bg);
    border-radius: 12px;
    width: 90%;
    max-width: 800px;
    max-height: 90vh;
    overflow: hidden;
    box-shadow: var(--shadow-lg);
}

.modal-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 15px 20px;
    border-bottom: 1px solid var(--border);
}

.modal-header h3 { font-size: 16px; font-weight: 700; color: var(--primary); }

.modal-close {
    background: none;
    border: none;
    font-size: 24px;
    cursor: pointer;
    color: var(--text-light);
    padding: 0;
    line-height: 1;
    transition: color 0.2s;
}

.modal-close:hover { color: var(--danger); }

.modal-body { padding: 20px; }

.modal-footer {
    display: flex;
    gap: 10px;
    justify-content: flex-end;
    padding: 15px 20px;
    border-top: 1px solid var(--border);
}

/* VIDEO PLAYER */

.video-container {
    position: relative;
    width: 100%;
    background: #000;
    aspect-ratio: 16/9;
    display: flex;
    align-items: center;
    justify-content: center;
}

.video-stream { width: 100%; height: 100%; object-fit: cover; }

.video-overlay {
    position: absolute;
    top: 0; left: 0; right: 0; bottom: 0;
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    justify-content: flex-start;
    gap: 8px;
    padding: 12px;
    pointer-events: none;
}

.rec-status {
    display: flex;
    align-items: center;
    gap: 8px;
    color: #fff;
    font-size: 12px;
    font-weight: 600;
    text-shadow: 0 1px 3px rgba(0,0,0,0.5);
}

.rec-timer { font-family: 'Courier New', monospace; font-size: 13px; min-width: 50px; }

.video-controls {
    display: flex;
    gap: 8px;
    padding: 12px 15px;
    background: var(--bg);
    flex-wrap: wrap;
    align-items: center;
}

/* ============================================
   LOGIN PAGE
   ============================================ */

.login-container {
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    background: linear-gradient(135deg, var(--primary) 0%, #1a252f 100%);
    padding: 20px;
}

.login-box {
    background: var(--card-bg);
    border-radius: 16px;
    padding: 40px;
    width: 100%;
    max-width: 400px;
    box-shadow: var(--shadow-lg);
}

.login-header { text-align: center; margin-bottom: 30px; }

.login-header .logo-icon { font-size: 48px; margin-bottom: 10px; display: block; }

.login-header h1 {
    font-size: 28px;
    font-weight: 700;
    color: var(--primary);
    margin-bottom: 5px;
}

.login-header .subtitle {
    font-size: 14px;
    color: var(--text-light);
}

.login-form { margin-bottom: 20px; }

.login-form .form-group { margin-bottom: 20px; }

.login-form .btn { margin-top: 10px; }

.login-footer {
    text-align: center;
    margin-top: 20px;
    padding-top: 20px;
    border-top: 1px solid var(--border);
}

.login-footer small { color: var(--text-light); font-size: 12px; }

.error-msg {
    background: rgba(231,76,60,0.1);
    color: var(--danger);
    padding: 10px 15px;
    border-radius: 6px;
    font-size: 14px;
    margin-bottom: 15px;
    border: 1px solid rgba(231,76,60,0.3);
}

/* ============================================
   TOAST
   ============================================ */

.toast-container {
    position: fixed;
    top: 20px;
    right: 20px;
    z-index: 300;
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.toast {
    padding: 12px 20px;
    border-radius: 8px;
    color: #fff;
    font-size: 14px;
    font-weight: 500;
    box-shadow: var(--shadow-lg);
    animation: slideIn 0.3s ease;
    display: flex;
    align-items: center;
    gap: 8px;
    max-width: 400px;
}

.toast-success { background: var(--success); }
.toast-error { background: var(--danger); }
.toast-warning { background: var(--warning); }
.toast-info { background: var(--accent); }

@keyframes slideIn {
    from { transform: translateX(100%); opacity: 0; }
    to { transform: translateX(0); opacity: 1; }
}

@keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.6; }
}

/* ============================================
   UTILITY
   ============================================ */

.loading-state {
    text-align: center;
    color: var(--text-light);
    padding: 30px;
    font-style: italic;
}

.empty-state {
    text-align: center;
    color: var(--text-light);
    padding: 40px;
    font-size: 16px;
}

.section-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 15px;
}

.section-header h2 {
    font-size: 16px;
    font-weight: 700;
    color: var(--primary);
}

/* ============================================
   RESPONSIVE
   ============================================ */

@media (max-width: 768px) {
    .sidebar {
        transform: translateX(-100%);
    }

    .sidebar.open {
        transform: translateX(0);
    }

    .main-content {
        margin-left: 0;
    }

    .topbar {
        padding: 12px 15px;
    }

    .content { padding: 15px; }

    .stats-grid {
        grid-template-columns: 1fr;
    }

    .form-row {
        grid-template-columns: 1fr;
    }

    .camera-grid {
        grid-template-columns: 1fr;
    }
}

/* ============================================
   KEYFRAMES
   ============================================ */

@keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.6; }
}

/* ============================================
   ADDITIONAL HELPER CLASSES
   ============================================ */

.form-select { appearance: none; background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath fill='%237f8c8d' d='M6 8L1 3h10z'/%3E%3C/svg%3E"); background-repeat: no-repeat; background-position: right 10px center; padding-right: 30px; }

.mono { font-family: 'Courier New', monospace; }

.text-muted { color: var(--text-light); }

.font-weight-600 { font-weight: 600; }

/* ============================================
   SETTINGS PAGE SPECIFIC
   ============================================ */

.settings-container {
    max-width: 800px;
    background: var(--card-bg);
    border-radius: var(--radius);
    box-shadow: var(--shadow);
    padding: 25px;
}

.settings-section {
    margin-bottom: 25px;
    padding-bottom: 20px;
    border-bottom: 1px solid var(--border);
}

.settings-section:last-child {
    border-bottom: none;
    margin-bottom: 0;
    padding-bottom: 0;
}

.settings-section h3 {
    font-size: 16px;
    font-weight: 700;
    color: var(--primary);
    margin-bottom: 15px;
    padding-bottom: 8px;
    border-bottom: 2px solid var(--accent);
}

.settings-group { display: flex; flex-direction: column; gap: 8px; }

.setting-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 0;
}

.setting-label { font-size: 14px; font-weight: 600; color: var(--text); }
.setting-desc { font-size: 12px; color: var(--text-light); margin-top: 2px; }
.setting-control { flex-shrink: 0; }
.setting-divider { height: 1px; background: var(--border); margin: 10px 0; }

.storage-usage-bar { margin-top: 15px; }

ENDOFFILE8styles.css

cat > "$APP_DIR/backend/static/js/app.js" << 'ENDOFFILE8app.js'
// ============================================
// CCTV Guardian - Frontend App
// ============================================

const API_BASE = '';

// ============================================
// Auth Helpers
// ============================================

function getAuthToken() {
    const cookies = document.cookie.split(';');
    for (let c of cookies) {
        c = c.trim();
        if (c.startsWith('auth_token=')) {
            return c.substring('auth_token='.length);
        }
    }
    return null;
}

async function checkAuth() {
    const token = getAuthToken();
    if (!token) {
        window.location.href = '/';
        return false;
    }
    try {
        const res = await fetch('/api/verify', {
            headers: { 'Authorization': 'Bearer ' + token }
        });
        if (!res.ok) {
            document.cookie = 'auth_token=; path=/; max-age=0';
            window.location.href = '/';
            return false;
        }
        const data = await res.json();
        if (data.valid && data.user) {
            document.getElementById('userName') && (document.getElementById('userName').textContent = data.user.username);
            document.getElementById('userRole') && (document.getElementById('userRole').textContent = data.user.role.charAt(0).toUpperCase() + data.user.role.slice(1));
        }
        return true;
    } catch (err) {
        document.cookie = 'auth_token=; path=/; max-age=0';
        window.location.href = '/';
        return false;
    }
}

async function logout() {
    await fetch('/api/auth/logout', {method:'POST'});
    document.cookie = 'auth_token=; path=/; max-age=0';
    window.location.href = '/';
}

// ============================================
// Settings Helpers
// ============================================

async function loadSettings() {
    try {
        const res = await fetch('/api/settings');
        const s = await res.json();
        setVal('setModelType', s.DETECTION_MODEL_TYPE || 'yolov8n');
        setVal('setConfThreshold', s.DETECTION_CONFIDENCE_THRESHOLD || 0.5);
        document.getElementById('confVal').textContent = (s.DETECTION_CONFIDENCE_THRESHOLD || 0.5).toFixed(2);
        setVal('setDetectInterval', s.DETECTION_INTERVAL || 2);
        setVal('setMotionThreshold', s.MOTION_THRESHOLD || 100);
        setVal('setRecMode', s.RECORDING_MODE || 'CONTINUOUS');
        setVal('setMotionRecDur', s.MOTION_RECORD_DURATION || 30);
        setVal('setMotionCooldown', s.MOTION_COOLDOWN || 60);
        setVal('setCloudProv', s.CLOUD_PROVIDER || 'none');
        setVal('setSavePath', s.LOCAL_SAVE_PATH || '/opt/cctv-guardian/recordings');
        setVal('setMaxStorage', s.MAX_LOCAL_STORAGE_GB || 50);
        setVal('setTGToken', s.TELEGRAM_BOT_TOKEN || '');
        setVal('setTGCHat', s.TELEGRAM_CHAT_ID || '');
        setVal('setSMTP', s.EMAIL_SMTP || 'smtp.gmail.com');
        setVal('setSMTPPort', s.EMAIL_SMTP_PORT || 587);
        setVal('setEmailUser', s.EMAIL_USERNAME || '');
        setVal('setEmailPass', s.EMAIL_PASSWORD || '');
        setVal('setEmailTo', s.EMAIL_RECIPIENT || '');
        setVal('setGDriveCID', s.GOOGLE_DRIVE_CLIENT_ID || '');
        setVal('setGDriveCS', s.GOOGLE_DRIVE_CLIENT_SECRET || '');
        setVal('setGDriveRT', s.GOOGLE_DRIVE_REFRESH_TOKEN || '');
        // Toggle switches
        setToggle('toggleDetection', s.DETECTION_ENABLED !== false);
        setToggle('togglePerson', s.DETECTION_PERSON_ENABLE !== false);
        setToggle('toggleVehicle', s.DETECTION_VEHICLE_ENABLE !== false);
        setToggle('toggleMotion', s.DETECTION_MOTION_ENABLE !== false);
        setToggle('toggleCloud', s.CLOUD_UPLOAD_ENABLED === true);
        setToggle('toggleTelegram', s.TELEGRAM_ENABLED === true);
        setToggle('toggleEmail', s.EMAIL_ENABLED === true);
    } catch (err) { console.error('Failed to load settings:', err); }
}

function setVal(id, val) {
    const el = document.getElementById(id);
    if (el) el.value = val;
}

function setToggle(id, active) {
    const el = document.getElementById(id);
    if (el) {
        if (active) el.classList.add('active');
        else el.classList.remove('active');
    }
}

async function saveSet(key, value) {
    try {
        const res = await fetch('/api/settings', {
            method: 'PUT',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({key, value})
        });
        if (!res.ok) {
            const data = await res.json();
            showToast(data.detail || 'Gagal menyimpan pengaturan', 'error');
        }
    } catch (err) { showToast('Gagal menyimpan pengaturan', 'error'); }
}

async function toggleSet(key, active) {
    await saveSet(key, active);
    const label = key.replace(/_/g, ' ').toLowerCase();
    showToast(active ? label + ' diaktifkan' : label + ' dinonaktifkan', 'info');
}

// ============================================
// Storage Bar
// ============================================

async function updateStorageBar() {
    try {
        const res = await fetch('/api/storage-info');
        if (res.ok) {
            const info = await res.json();
            const usedGB = (info.used_bytes / (1024*1024*1024)).toFixed(2);
            const totalGB = (info.total_bytes / (1024*1024*1024)).toFixed(2);
            const percent = Math.min(100, (info.used_bytes / info.total_bytes * 100)).toFixed(1);
            document.getElementById('storageUsed').textContent = usedGB + ' GB';
            document.getElementById('storageTotal').textContent = totalGB + ' GB';
            document.getElementById('storagePercent').textContent = percent + '%';
            document.getElementById('storageBarFill').style.width = percent + '%';
        }
    } catch (err) { console.error('Storage bar error:', err); }
}

// ============================================
// Toast Notifications
// ============================================

function showToast(message, type = 'info', duration = 3000) {
    const container = document.getElementById('toastContainer');
    if (!container) return;
    const icons = {
        success: '✅',
        error: '❌',
        warning: '⚠️',
        info: 'ℹ️'
    };
    const toast = document.createElement('div');
    toast.className = \`toast toast-\${type}\`;
    toast.innerHTML = \`\${icons[type] || icons.info} \${message}\`;
    container.appendChild(toast);
    setTimeout(() => {
        toast.style.opacity = '0';
        toast.style.transform = 'translateX(100%)';
        setTimeout(() => toast.remove(), 300);
    }, duration);
}

// ============================================
// Confirm Dialog
// ============================================

function confirmDialog(message) {
    return window.confirm(message);
}

ENDOFFILE8app.js

OK "main.py created"
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

if [ "$NGINX_CHOICE" = "1" ] || [ "$NGINX_CHOICE" = "y" ] || [ "$NGINX_CHOICE" = "Y" ]; then
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
    if [ "$NGINX_CHOICE" = "1" ] || [ "$NGINX_CHOICE" = "y" ] || [ "$NGINX_CHOICE" = "Y" ]; then
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
