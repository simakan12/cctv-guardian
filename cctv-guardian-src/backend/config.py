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
