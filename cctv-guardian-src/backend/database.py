"""
CCTV Web Application - Database Models
"""

from sqlalchemy import create_engine, Column, Integer, String, DateTime, Boolean
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from datetime import datetime

DATABASE_URL = "sqlite:///./cctv.db"

engine = create_engine(DATABASE_URL, connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String, unique=True, index=True, nullable=False)
    password_hash = Column(String, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)
    is_active = Column(Boolean, default=True)


class Camera(Base):
    __tablename__ = "cameras"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)
    location = Column(String, nullable=True)
    rtsp_url = Column(String, nullable=False)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)


class DetectionLog(Base):
    __tablename__ = "detection_logs"

    id = Column(Integer, primary_key=True, index=True)
    camera_id = Column(Integer, nullable=False)
    timestamp = Column(DateTime, default=datetime.utcnow)
    detection_type = Column(String, nullable=False)  # person, vehicle, etc
    confidence = Column(Float, nullable=False)
    snapshot_path = Column(String, nullable=True)  # Path to snapshot image
    recording_path = Column(String, nullable=True)  # Path to recording file


class Recording(Base):
    __tablename__ = "recordings"

    id = Column(Integer, primary_key=True, index=True)
    camera_id = Column(Integer, nullable=False)
    start_time = Column(DateTime, nullable=False)
    end_time = Column(DateTime, nullable=True)
    file_path = Column(String, nullable=False)
    storage_type = Column(String, nullable=False)  # local, cloud
    cloud_path = Column(String, nullable=True)  # Cloud storage path if uploaded
    uploaded = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)


class Alert(Base):
    __tablename__ = "alerts"

    id = Column(Integer, primary_key=True, index=True)
    camera_id = Column(Integer, nullable=False)
    timestamp = Column(DateTime, default=datetime.utcnow)
    alert_type = Column(String, nullable=False)  # human_detected
    message = Column(String, nullable=False)
    read = Column(Boolean, default=False)
    acknowledged = Column(Boolean, default=False)


# Dependency untuk mendapatkan database session
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
