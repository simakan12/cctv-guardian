"""
CCTV Web Application - Main FastAPI Server
"""

from fastapi import FastAPI, Depends, HTTPException, Request, BackgroundTasks, Cookie, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, HTMLResponse, StreamingResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from starlette.responses import Response
import cv2
import numpy as np
from PIL import Image
import threading
import time
import os
import json
from datetime import datetime, timedelta
from typing import Optional
import asyncio
from pathlib import Path
import uuid

from .config import (
    APP_NAME,
    APP_VERSION,
    RTSP_CONFIG,
    RECORDING_CONFIG,
    DETECTION_CONFIG,
    ALERT_CONFIG,
    PERFORMANCE_CONFIG,
    HOST,
    PORT,
    AUTH_SECRET,
)
from .auth import (
    authenticate_user,
    hash_password,
    MOCK_USERS,
    create_access_token,
    get_current_user,
    admin_required,
)
from .database import (
    Base,
    engine,
    SessionLocal,
    Camera,
    Recording,
    DetectionLog,
    Alert,
    get_db,
)

# Create database tables
Base.metadata.create_all(bind=engine)

app = FastAPI(
    title=APP_NAME,
    description="CCTV Monitoring Application with Human Detection",
    version=APP_VERSION,
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Static files
app.mount("/static", StaticFiles(directory="static"), name="static")

# Templates
templates = Jinja2Templates(directory="templates")

# Session storage (in production, use Redis or database)
sessions: dict = {}


@app.get("/")
async def root(request: Request):
    """Serve login page"""
    return templates.TemplateResponse("login.html", {"request": request})


@app.post("/api/login")
async def login(request: Request):
    """Login endpoint - returns JWT token"""
    data = await request.json()
    username = data.get("username", "")
    password = data.get("password", "")

    if not username or not password:
        raise HTTPException(status_code=400, detail="Username and password required")

    user = authenticate_user(username, password)
    if not user:
        raise HTTPException(status_code=401, detail="Invalid credentials")

    # Create JWT token
    token = create_access_token(data={"sub": user["username"], "role": user["role"]})

    return {
        "success": True,
        "token": token,
        "user": {"username": user["username"], "role": user["role"]},
    }


@app.get("/api/verify")
async def verify_token(request: Request):
    """Verify if current token is valid"""
    auth_header = request.headers.get("Authorization")
    if not auth_header or not auth_header.startswith("Bearer "):
        return {"valid": False, "user": None}

    token = auth_header.split(" ", 1)[1]
    try:
        payload = decode_token(token)
        if payload and payload.get("sub"):
            username = payload["sub"]
            user = MOCK_USERS.get(username)
            if user:
                return {"valid": True, "user": {"username": username, "role": user["role"]}}
        return {"valid": False, "user": None}
    except Exception:
        return {"valid": False, "user": None}


@app.get("/api/logout")
async def logout():
    """Logout endpoint"""
    return {"success": True, "message": "Logged out successfully"}


# Dependency untuk mendapatkan user dari JWT token
async def get_current_user_from_token(
    request: Request,
    token: Optional[str] = Cookie(None),
    authorization: Optional[str] = Header(None),
):
    """Get current user from JWT token (either from cookie or Authorization header)"""
    token_to_use = None

    # Try to get token from Authorization header
    if authorization and authorization.startswith("Bearer "):
        token_to_use = authorization.split(" ", 1)[1]
    # Try to get token from cookie
    elif token:
        token_to_use = token
    # Try Authorization header again (in case it was passed differently)
    elif authorization:
        token_to_use = authorization

    if not token_to_use:
        raise HTTPException(
            status_code=401,
            detail="Not authenticated. Please login.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    payload = decode_token(token_to_use)
    if not payload or not payload.get("sub"):
        raise HTTPException(
            status_code=401,
            detail="Invalid or expired token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    username = payload["sub"]
    user = MOCK_USERS.get(username)
    if not user:
        raise HTTPException(
            status_code=401,
            detail="User not found",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return {
        "username": user["username"],
        "password_hash": user["password_hash"],
        "role": user["role"],
    }


@app.get("/dashboard")
async def dashboard(
    request: Request,
    user: dict = Depends(get_current_user_from_token),
):
    """Serve dashboard page"""
    return templates.TemplateResponse(
        "dashboard.html",
        {
            "request": request,
            "user": user,
            "cameras": [],  # Will be populated by JS
        },
    )


@app.get("/api/cameras")
async def get_cameras(
    user: dict = Depends(get_current_user_from_token),
):
    """Get list of cameras"""
    db = SessionLocal()
    try:
        cameras = db.query(Camera).order_by(Camera.id).all()
        return [
            {
                "id": c.id,
                "name": c.name,
                "location": c.location,
                "rtsp_url": c.rtsp_url,
                "is_active": c.is_active,
                "created_at": c.created_at.isoformat() if c.created_at else None,
            }
            for c in cameras
        ]
    finally:
        db.close()


@app.post("/api/cameras", dependencies=[Depends(admin_required)])
async def create_camera(
    request: Request,
    user: dict = Depends(get_current_user_from_token),
):
    """Create a new camera (admin only)"""
    data = await request.json()
    name = data.get("name", "").strip()
    location = data.get("location", "").strip()
    rtsp_url = data.get("rtsp_url", "").strip()
    is_active = data.get("is_active", True)

    if not name or not rtsp_url:
        raise HTTPException(status_code=400, detail="Name and RTSP URL are required")

    db = SessionLocal()
    try:
        # Check if camera with same name or URL already exists
        existing = (
            db.query(Camera)
            .filter(
                (Camera.name == name) | (Camera.rtsp_url == rtsp_url)
            )
            .first()
        )
        if existing:
            raise HTTPException(
                status_code=400,
                detail="Camera with same name or RTSP URL already exists",
            )

        camera = Camera(
            name=name,
            location=location,
            rtsp_url=rtsp_url,
            is_active=is_active,
        )
        db.add(camera)
        db.commit()
        db.refresh(camera)

        return {
            "success": True,
            "camera": {
                "id": camera.id,
                "name": camera.name,
                "location": camera.location,
                "rtsp_url": camera.rtsp_url,
                "is_active": camera.is_active,
                "created_at": camera.created_at.isoformat() if camera.created_at else None,
            },
            "message": "Camera created successfully",
        }

    finally:
        db.close()


@app.put("/api/cameras/{camera_id}")
async def update_camera(
    camera_id: int,
    request: Request,
    user: dict = Depends(get_current_user_from_token),
):
    """Update camera configuration (admin only)"""
    data = await request.json()
    db = SessionLocal()
    try:
        camera = db.query(Camera).filter(Camera.id == camera_id).first()
        if not camera:
            raise HTTPException(status_code=404, detail="Camera not found")

        if "name" in data and data["name"]:
            camera.name = data["name"].strip()
        if "location" in data:
            camera.location = data["location"].strip()
        if "rtsp_url" in data and data["rtsp_url"]:
            camera.rtsp_url = data["rtsp_url"].strip()
        if "is_active" in data:
            camera.is_active = data["is_active"]

        db.commit()
        db.refresh(camera)

        return {
            "success": True,
            "camera": {
                "id": camera.id,
                "name": camera.name,
                "location": camera.location,
                "rtsp_url": camera.rtsp_url,
                "is_active": camera.is_active,
                "created_at": camera.created_at.isoformat() if camera.created_at else None,
            },
            "message": "Camera updated successfully",
        }

    finally:
        db.close()


@app.delete("/api/cameras/{camera_id}", dependencies=[Depends(admin_required)])
async def delete_camera(
    camera_id: int,
    user: dict = Depends(get_current_user_from_token),
):
    """Delete a camera (admin only)"""
    db = SessionLocal()
    try:
        camera = db.query(Camera).filter(Camera.id == camera_id).first()
        if not camera:
            raise HTTPException(status_code=404, detail="Camera not found")

        camera_name = camera.name
        db.delete(camera)
        db.commit()

        return {
            "success": True,
            "message": f"Camera '{camera_name}' deleted successfully",
        }

    finally:
        db.close()


@app.post("/api/cameras/{camera_id}/toggle")
async def toggle_camera(
    camera_id: int,
    user: dict = Depends(get_current_user_from_token),
):
    """Toggle camera active status"""
    db = SessionLocal()
    try:
        camera = db.query(Camera).filter(Camera.id == camera_id).first()
        if not camera:
            raise HTTPException(status_code=404, detail="Camera not found")

        camera.is_active = not camera.is_active
        db.commit()

        return {
            "success": True,
            "camera_id": camera_id,
            "is_active": camera.is_active,
            "message": f"Camera {camera.name} is now {'active' if camera.is_active else 'inactive'}",
        }

    finally:
        db.close()


@app.get("/api/stream/{camera_id}")
async def start_stream(
    camera_id: int,
    user: dict = Depends(get_current_user_from_token),
):
    """Start streaming for a camera (MJPEG) - currently returns mock stream"""
    db = SessionLocal()
    try:
        camera = db.query(Camera).filter(Camera.id == camera_id).first()
        if not camera:
            raise HTTPException(status_code=404, detail="Camera not found")

        if not camera.is_active:
            raise HTTPException(
                status_code=400,
                detail=f"Camera '{camera.name}' is not active. Please activate it first.",
            )

        # In production, this would connect to RTSP stream using cv2.VideoCapture
        # For now, we'll create a mock stream (generate test patterns)
        def generate_frames():
            """Generate video frames (mock)"""
            frame_width = 640
            frame_height = 480
            color = (0, 255, 0)  # Green for testing
            frame_count = 0

            while True:
                frame = np.zeros((frame_height, frame_width, 3), dtype=np.uint8)
                frame[:, :] = color

                cv2.putText(
                    frame,
                    f"Camera {camera.name}",
                    (10, 30),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.7,
                    (255, 255, 255),
                    2,
                )
                cv2.putText(
                    frame,
                    f"Frame: {frame_count}",
                    (10, 60),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.5,
                    (255, 255, 255),
                    1,
                )
                cv2.putText(
                    frame,
                    f"User: {user['username']}",
                    (10, 90),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.5,
                    (255, 255, 255),
                    1,
                )
                cv2.putText(
                    frame,
                    f"RTSP: {camera.rtsp_url[:30]}...",
                    (10, 120),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.4,
                    (255, 255, 255),
                    1,
                )

                _, buffer = cv2.imencode(".jpg", frame)
                frame_bytes = buffer.tobytes()

                yield (
                    b"--frameboundary\n"
                    b"Content-Type: image/jpeg\n\n"
                    + frame_bytes
                    + b"\n"
                )

                frame_count += 1
                time.sleep(1.0 / 15)  # 15 FPS

        return StreamingResponse(
            generate_frames(),
            media_type="multipart/x-mixed-replace;boundary=frameboundary",
        )

    finally:
        db.close()


@app.get("/api/detect/{camera_id}")
async def detect_human(
    camera_id: int,
    user: dict = Depends(get_current_user_from_token),
):
    """Run human detection on a camera stream (simulated for testing)"""
    db = SessionLocal()
    try:
        camera = db.query(Camera).filter(Camera.id == camera_id).first()
        if not camera:
            raise HTTPException(status_code=404, detail="Camera not found")

        if not camera.is_active:
            raise HTTPException(
                status_code=400,
                detail=f"Camera '{camera.name}' is not active.",
            )

        # Simulated detection result (in production, use YOLO here)
        import random
        has_human = random.choice([True, False])
        confidence = round(random.uniform(0.5, 0.99), 2) if has_human else 0

        detection_result = {
            "camera_id": camera_id,
            "camera_name": camera.name,
            "timestamp": datetime.utcnow().isoformat(),
            "human_detected": has_human,
            "confidence": confidence,
            "num_humans": random.randint(0, 3) if has_human else 0,
        }

        if has_human:
            detection_log = DetectionLog(
                camera_id=camera_id,
                detection_type="person",
                confidence=confidence,
            )
            db.add(detection_log)

            alert = Alert(
                camera_id=camera_id,
                alert_type="human_detected",
                message=f"Human detected at {camera.name}",
            )
            db.add(alert)
            print(f"[ALERT] Human detected at Camera {camera.name}")

        db.commit()
        return detection_result

    finally:
        db.close()


@app.get("/api/recordings")
async def get_recordings(
    user: dict = Depends(get_current_user_from_token),
):
    """Get list of recordings"""
    db = SessionLocal()
    try:
        recordings = db.query(Recording).order_by(Recording.start_time.desc()).all()
        return [
            {
                "id": r.id,
                "camera_id": r.camera_id,
                "start_time": r.start_time.isoformat(),
                "end_time": r.end_time.isoformat() if r.end_time else None,
                "file_path": r.file_path,
                "storage_type": r.storage_type,
                "cloud_path": r.cloud_path,
                "uploaded": r.uploaded,
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
            for r in recordings
        ]
    finally:
        db.close()


@app.post("/api/recordings/start")
async def start_recording(
    camera_id: int,
    user: dict = Depends(get_current_user_from_token),
):
    """Start recording for a camera"""
    db = SessionLocal()
    try:
        camera = db.query(Camera).filter(Camera.id == camera_id).first()
        if not camera:
            raise HTTPException(status_code=404, detail="Camera not found")

        if not camera.is_active:
            raise HTTPException(
                status_code=400,
                detail=f"Camera '{camera.name}' is not active. Please activate it first.",
            )

        recording = Recording(
            camera_id=camera_id,
            start_time=datetime.utcnow(),
            file_path=f"/var/cctv-recordings/camera_{camera_id}_{datetime.utcnow().strftime('%Y%m%d_%H%M%S')}.mp4",
            storage_type="local",
        )
        db.add(recording)
        db.commit()

        print(f"[RECORDING] Started recording for Camera {camera.name}")
        return {
            "success": True,
            "recording_id": recording.id,
            "message": f"Recording started for {camera.name}",
        }

    finally:
        db.close()


@app.post("/api/recordings/stop/{recording_id}")
async def stop_recording(
    recording_id: int,
    user: dict = Depends(get_current_user_from_token),
):
    """Stop recording"""
    db = SessionLocal()
    try:
        recording = db.query(Recording).filter(Recording.id == recording_id).first()
        if not recording:
            raise HTTPException(status_code=404, detail="Recording not found")

        recording.end_time = datetime.utcnow()
        db.commit()

        print(f"[RECORDING] Stopped recording {recording_id}")
        return {
            "success": True,
            "message": f"Recording {recording_id} stopped",
        }

    finally:
        db.close()


@app.get("/api/alerts")
async def get_alerts(
    user: dict = Depends(get_current_user_from_token),
):
    """Get recent alerts"""
    db = SessionLocal()
    try:
        alerts = db.query(Alert).order_by(Alert.timestamp.desc()).limit(50).all()
        return [
            {
                "id": a.id,
                "camera_id": a.camera_id,
                "timestamp": a.timestamp.isoformat(),
                "alert_type": a.alert_type,
                "message": a.message,
                "read": a.read,
                "acknowledged": a.acknowledged,
                "created_at": a.created_at.isoformat() if a.created_at else None,
            }
            for a in alerts
        ]
    finally:
        db.close()


@app.post("/api/alerts/{alert_id}/acknowledge")
async def acknowledge_alert(
    alert_id: int,
    user: dict = Depends(get_current_user_from_token),
):
    """Acknowledge an alert"""
    db = SessionLocal()
    try:
        alert = db.query(Alert).filter(Alert.id == alert_id).first()
        if not alert:
            raise HTTPException(status_code=404, detail="Alert not found")

        alert.acknowledged = True
        db.commit()
        return {"success": True, "message": "Alert acknowledged"}

    finally:
        db.close()


@app.post("/api/recordings/upload/{recording_id}")
async def upload_recording(
    recording_id: int,
    user: dict = Depends(get_current_user_from_token),
):
    """Upload recording to cloud storage (simulated)"""
    db = SessionLocal()
    try:
        recording = db.query(Recording).filter(Recording.id == recording_id).first()
        if not recording:
            raise HTTPException(status_code=404, detail="Recording not found")

        if recording.end_time is None:
            raise HTTPException(
                status_code=400,
                detail="Recording has not been stopped yet. Please stop recording first.",
            )

        # Simulated cloud upload
        recording.cloud_path = f"cloud://{recording.file_path}"
        recording.uploaded = True
        db.commit()

        return {
            "success": True,
            "message": f"Recording {recording_id} uploaded to cloud",
            "cloud_path": recording.cloud_path,
        }

    finally:
        db.close()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=HOST, port=PORT)
