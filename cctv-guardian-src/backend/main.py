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
