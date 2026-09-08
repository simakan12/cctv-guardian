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
    toast.className = `toast toast-${type}`;
    toast.innerHTML = `${icons[type] || icons.info} ${message}`;
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
