"""
CCTV Web Application - Authentication Module
"""

from datetime import datetime, timedelta
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from jose import JWTError, jwt
from passlib.context import CryptContext
from typing import Optional, Dict, Any

from .config import AUTH_SECRET, AUTH_SESSION_TIMEOUT

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
security = HTTPBasic()


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def create_access_token(data: dict, expires_delta: Optional[timedelta] = None) -> str:
    to_encode = data.copy()
    if expires_delta:
        expire = datetime.utcnow() + expires_delta
    else:
        expire = datetime.utcnow() + AUTH_SESSION_TIMEOUT
    to_encode.update({"exp": expire})
    encoded_jwt = jwt.encode(to_encode, AUTH_SECRET, algorithm="HS256")
    return encoded_jwt


def decode_token(token: str) -> Optional[Dict[str, Any]]:
    try:
        payload = jwt.decode(token, AUTH_SECRET, algorithms=["HS256"])
        return payload
    except JWTError:
        return None


# Mock user database (sebenarnya pakai database.py)
MOCK_USERS = {
    "admin": {
        "username": "admin",
        "password_hash": hash_password("admin123"),
        "role": "admin",
    },
    "viewer": {
        "username": "viewer",
        "password_hash": hash_password("viewer123"),
        "role": "viewer",
    },
}


def authenticate_user(username: str, password: str) -> Optional[Dict[str, Any]]:
    user = MOCK_USERS.get(username)
    if not user:
        return None
    if not verify_password(password, user["password_hash"]):
        return None
    return {
        "username": user["username"],
        "password_hash": user["password_hash"],
        "role": user["role"],
    }


def get_current_user(
    request: Any,
) -> Dict[str, Any]:
    """Get current user from JWT token in Authorization header"""
    auth_header = request.headers.get("Authorization")
    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Not authenticated",
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = auth_header.split(" ", 1)[1]
    payload = decode_token(token)

    if not payload:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    username = payload.get("sub")
    if not username:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    user = MOCK_USERS.get(username)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return {
        "username": user["username"],
        "role": user["role"],
        "token": None,  # Token tidak dikembalikan di sini
    }


def admin_required(user: Dict[str, Any] = Depends(get_current_user)) -> Dict[str, Any]:
    """Ensure user has admin role"""
    if user.get("role") != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin access required",
        )
    return user
