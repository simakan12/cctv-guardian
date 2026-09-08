"""
CCTV Web Application - Backend Configuration
Application: CCTV monitoring + human detection
Author: Hermes Agent (assisted by Bos)
"""

import os
from datetime import datetime, timedelta

# Application settings
APP_NAME = "CCTV Guardian"
APP_VERSION = "1.0.0"
DEBUG = False

# Authentication
AUTH_SECRET = os.environ.get("AUTH_SECRET", "change-this-secret-please")
AUTH_SESSION_TIMEOUT = timedelta(hours=24)  # Session expires after 24 hours

# Server settings
HOST = "0.0.0.0"
PORT = int(os.environ.get("PORT", 8000))

# RTSP Stream Configuration
RTSP_CONFIG = {
    "primary_camera": {
        "url": os.environ.get("RTSP_URL_1", "rtsp://username:password@192.168.1.100:554/stream"),
        "name": "Camera 1 - Main Entrance",
        "location": "Main Entrance",
        "enabled": True,
    },
    "secondary_camera": {
        "url": os.environ.get("RTSP_URL_2", ""),
        "name": "Camera 2 - Backyard",
        "location": "Backyard",
        "enabled": False,
    },
}

# Recording Configuration
RECORDING_CONFIG = {
    "save_local": True,
    "local_save_path": os.environ.get("LOCAL_SAVE_PATH", "/var/cctv-recordings"),
    "max_local_storage_gb": 50,
    "cloud_upload_enabled": False,
    "cloud_provider": "google_drive",  # options: google_drive, wasabi, nextcloud
    "cloud_credentials_file": os.environ.get("CLOUD_CREDENTIALS", "/etc/cctv/cloud-credentials.json"),
    "upload_on_detection": True,  # Upload recording ketika human terdeteksi
    "keep_recording_hours": 72,  # Keep recordings for 72 hours
}

# Human Detection Configuration
DETECTION_CONFIG = {
    "model_type": "yolov8n",  # Using YOLOv8 nano for speed
    "confidence_threshold": 0.5,
    "enabled": True,
    "detection_classes": ["person"],  # Only detect humans
    "alert_on_detection": True,
    "min_detection_interval_seconds": 10,  # Min interval between alerts of same camera
}

# Alert Configuration
ALERT_CONFIG = {
    "telegram_bot_token": os.environ.get("TELEGRAM_BOT_TOKEN", ""),
    "telegram_chat_id": os.environ.get("TELEGRAM_CHAT_ID", ""),
    "email_enabled": False,
    "email_sender": os.environ.get("EMAIL_SENDER", ""),
    "email_password": os.environ.get("EMAIL_PASSWORD", ""),
    "email_recipient": os.environ.get("EMAIL_RECIPIENT", ""),
    "notification_channels": ["dashboard"],  # dashboard, telegram, email
}

# Performance Settings
PERFORMANCE_CONFIG = {
    "stream_fps": 15,
    "stream_resolution": (640, 480),
    "detection_interval_seconds": 1,  # Detection setiap detik
    "max_concurrent_streams": 4,
}
