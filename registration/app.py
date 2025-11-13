#!/usr/bin/env python3
"""
User Self-Provisioning Service for org-stack

Provides a public registration form and admin approval dashboard.
Approved users are automatically created in lldap.

Workflow:
- Public registration form at /
- Admin dashboard at /admin (protected by Authelia forward-auth)
- Pending requests → Approve (creates in lldap) or Reject → Audit log
- lldap is the single source of truth for all active users
"""

import os
import sqlite3
import secrets
import string
import subprocess
from datetime import datetime
from contextlib import contextmanager
from typing import Optional

from fastapi import FastAPI, Request, Form, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

app = FastAPI(title="User Registration Service")
templates = Jinja2Templates(directory="templates")

# Configuration from environment
DATABASE = os.environ.get('DATABASE_PATH', '/data/registrations.db')
LLDAP_ADMIN_USER = os.environ.get('LLDAP_ADMIN_USER', 'admin')
LLDAP_BASE_DN = os.environ.get('LDAP_BASE_DN', 'dc=example,dc=com')
LDAP_HOST = 'ldap://lldap:3890'
ADMIN_EMAIL = os.environ.get('ADMIN_EMAIL', '')
SMTP_ENABLED = os.environ.get('SMTP_ENABLED', 'false').lower() == 'true'
SMTP_HOST = os.environ.get('SMTP_HOST', 'localhost')
SMTP_PORT = int(os.environ.get('SMTP_PORT', '587'))
SMTP_USER = os.environ.get('SMTP_USER', '')
SMTP_PASSWORD = os.environ.get('SMTP_PASSWORD', '')
SMTP_FROM = os.environ.get('SMTP_FROM', ADMIN_EMAIL)
SMTP_USE_TLS = os.environ.get('SMTP_USE_TLS', 'true').lower() == 'true'
EMAIL_LOG_FILE = '/data/emails.log'

# =============================================================================
# Database Functions
# =============================================================================

@contextmanager
def get_db():
    """Context manager for database connections"""
    conn = sqlite3.connect(DATABASE)
    conn.row_factory = sqlite3.Row
    try:
        init_db(conn)
        yield conn
    finally:
        conn.close()

def init_db(db: sqlite3.Connection):
    """Initialize database tables"""
    # Pending registration requests
    db.execute('''
        CREATE TABLE IF NOT EXISTS registration_requests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE,
            email TEXT NOT NULL,
            first_name TEXT NOT NULL,
            last_name TEXT NOT NULL,
            reason TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ip_address TEXT,
            user_agent TEXT
        )
    ''')

    # Historical audit log of all approved/rejected requests
    db.execute('''
        CREATE TABLE IF NOT EXISTS audit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL,
            email TEXT NOT NULL,
            first_name TEXT NOT NULL,
            last_name TEXT NOT NULL,
            reason TEXT,
            action TEXT NOT NULL,
            performed_by TEXT,
            rejection_reason TEXT,
            ip_address TEXT,
            user_agent TEXT,
            created_at TIMESTAMP,
            reviewed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')

    db.commit()

# =============================================================================
# LDAP Security - Injection Prevention
# =============================================================================

def escape_ldap_dn(value: str) -> str:
    """Escape LDAP DN special characters per RFC 4514"""
    value = value.replace('\\', '\\\\')
    replacements = {',': '\\,', '#': '\\#', '+': '\\+', '<': '\\<',
                    '>': '\\>', ';': '\\;', '"': '\\"', '=': '\\='}
    for char, escaped in replacements.items():
        value = value.replace(char, escaped)
    if value.startswith(' '):
        value = '\\' + value
    if value.endswith(' '):
        value = value[:-1] + '\\ '
    return value

def validate_username_strict(username: str) -> bool:
    """Validate username: 2-64 chars, lowercase alphanumeric + underscore, must start with letter"""
    if not username or len(username) < 2 or len(username) > 64:
        return False
    if not username.replace('_', '').isalnum() or not username.islower():
        return False
    if not username[0].isalpha():
        return False
    return True

def validate_email_basic(email: str) -> bool:
    """Basic email validation"""
    if not email or '@' not in email:
        return False
    if len(email) > 255:
        return False
    # Basic format check
    parts = email.split('@')
    if len(parts) != 2:
        return False
    local, domain = parts
    if not local or not domain or '.' not in domain:
        return False
    return True

# =============================================================================
# lldap LDAP Integration
# =============================================================================

def get_lldap_admin_password() -> str:
    """Read lldap admin password from secret file"""
    secret_file = '/secrets-lldap/LDAP_USER_PASS'
    if os.path.exists(secret_file):
        with open(secret_file, 'r') as f:
            return f.read().strip()
    return os.environ.get('LLDAP_ADMIN_PASSWORD', '')

async def create_lldap_user(username: str, email: str, first_name: str, last_name: str) -> tuple[bool, str, str]:
    """Create user in lldap via LDAP. Returns (success, password, error)"""
    try:
        # Validate inputs
        if not validate_username_strict(username):
            print(f'[SECURITY] Invalid username: {username}')
            return False, '', 'Invalid username format'

        if not validate_email_basic(email):
            return False, '', 'Invalid email format'

        if not first_name or len(first_name) > 100 or not last_name or len(last_name) > 100:
            return False, '', 'Invalid name fields'

        # Generate random password
        password = ''.join(secrets.choice(
            string.ascii_letters + string.digits + string.punctuation
        ) for _ in range(20))

        admin_password = get_lldap_admin_password()

        # Escape LDAP DN components
        user_dn = f'uid={escape_ldap_dn(username)},ou=people,{LLDAP_BASE_DN}'
        admin_dn = f'uid={escape_ldap_dn(LLDAP_ADMIN_USER)},ou=people,{LLDAP_BASE_DN}'

        # Create LDIF for new user
        ldif_content = f'''dn: {user_dn}
objectClass: person
objectClass: inetOrgPerson
uid: {escape_ldap_dn(username)}
cn: {escape_ldap_dn(first_name)} {escape_ldap_dn(last_name)}
sn: {escape_ldap_dn(last_name)}
givenName: {escape_ldap_dn(first_name)}
mail: {escape_ldap_dn(email)}
'''

        # Step 1: Create user with ldapadd
        try:
            result = subprocess.run(
                ['ldapadd', '-H', LDAP_HOST, '-D', admin_dn, '-w', admin_password, '-x'],
                input=ldif_content, capture_output=True, text=True, timeout=10
            )
            if result.returncode != 0:
                print(f'[ERROR] ldapadd failed: {result.stderr}')
                return False, '', f'Failed to create user: {result.stderr}'

            print(f'[SUCCESS] User {username} created in lldap')

        except subprocess.TimeoutExpired:
            return False, '', 'LDAP operation timed out'
        except Exception as e:
            return False, '', f'Failed to create user: {str(e)}'

        # Step 2: Set password with ldappasswd
        try:
            result = subprocess.run(
                ['ldappasswd', '-H', LDAP_HOST, '-D', admin_dn, '-w', admin_password, '-s', password, user_dn],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode != 0:
                print(f'[ERROR] ldappasswd failed: {result.stderr}')
                # Cleanup: delete user entry
                subprocess.run(['ldapdelete', '-H', LDAP_HOST, '-D', admin_dn, '-w', admin_password, user_dn],
                             capture_output=True, timeout=10)
                return False, '', f'Failed to set password: {result.stderr}'

            print(f'[SUCCESS] Password set for user {username}')
            return True, password, ''

        except subprocess.TimeoutExpired:
            return False, '', 'LDAP operation timed out'
        except Exception as e:
            return False, '', f'Failed to set password: {str(e)}'

    except Exception as e:
        return False, '', str(e)

# =============================================================================
# LDAP Validation Functions
# =============================================================================

def check_ldap_user_exists(username: str = None, email: str = None) -> tuple[bool, str]:
    """
    Check if username or email already exists in lldap.
    Returns (exists: bool, error_message: str)
    """
    try:
        admin_password = open('/secrets-lldap/LDAP_USER_PASS').read().strip()
        admin_dn = f'uid={LLDAP_ADMIN_USER},ou=people,{LLDAP_BASE_DN}'

        # Check username exists
        if username:
            result = subprocess.run(
                ['ldapsearch', '-x', '-LLL', '-H', LDAP_HOST, '-D', admin_dn, '-w', admin_password,
                 '-b', f'ou=people,{LLDAP_BASE_DN}', f'(uid={escape_ldap_dn(username)})', 'dn'],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0 and result.stdout.strip():
                return True, f'Username "{username}" is already taken'

        # Check email exists
        if email:
            result = subprocess.run(
                ['ldapsearch', '-x', '-LLL', '-H', LDAP_HOST, '-D', admin_dn, '-w', admin_password,
                 '-b', f'ou=people,{LLDAP_BASE_DN}', f'(mail={escape_ldap_dn(email)})', 'dn'],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0 and result.stdout.strip():
                return True, f'Email "{email}" is already registered'

        return False, ''

    except subprocess.TimeoutExpired:
        print('[ERROR] LDAP search timed out')
        return False, ''  # Fail open - allow registration if LDAP is slow
    except Exception as e:
        print(f'[ERROR] Failed to check LDAP: {str(e)}')
        return False, ''  # Fail open - allow registration if LDAP check fails

# =============================================================================
# Email Notifications
# =============================================================================

def log_email_to_file(to: str, subject: str, body: str):
    """Log email to file when SMTP is disabled"""
    timestamp = datetime.now().isoformat()
    with open(EMAIL_LOG_FILE, 'a') as f:
        f.write(f'\n{"="*80}\n')
        f.write(f'Timestamp: {timestamp}\n')
        f.write(f'To: {to}\n')
        f.write(f'Subject: {subject}\n')
        f.write(f'Body:\n{body}\n')
        f.write(f'{"="*80}\n')

def send_email(to: str, subject: str, body: str) -> bool:
    """Send email notification via SMTP or log to file"""
    if not SMTP_ENABLED:
        log_email_to_file(to, subject, body)
        print(f'[EMAIL] Logged to {EMAIL_LOG_FILE}: {to} - {subject}')
        return True

    try:
        import smtplib
        from email.mime.text import MIMEText
        from email.mime.multipart import MIMEMultipart

        msg = MIMEMultipart()
        msg['From'] = SMTP_FROM
        msg['To'] = to
        msg['Subject'] = subject
        msg.attach(MIMEText(body, 'plain'))

        server = smtplib.SMTP(SMTP_HOST, SMTP_PORT)
        if SMTP_USE_TLS:
            server.starttls()

        if SMTP_USER and SMTP_PASSWORD:
            server.login(SMTP_USER, SMTP_PASSWORD)

        server.send_message(msg)
        server.quit()

        print(f'[EMAIL] Sent to {to}: {subject}')
        return True

    except Exception as e:
        print(f'[ERROR] Failed to send email to {to}: {e}')
        # Fallback: log to file
        log_email_to_file(to, subject, body)
        return False

def notify_admin_new_request(username: str, email: str, reason: str):
    """Send email to admin about new registration request"""
    subject = f'New registration request: {username}'
    body = f'''
A new user has requested an account:

Username: {username}
Email: {email}
Reason: {reason}

Please review and approve/reject at the admin dashboard.
'''
    send_email(ADMIN_EMAIL, subject, body)

def notify_user_approved(email: str, username: str, password: str):
    """Send email to user with their credentials after approval"""
    subject = 'Account approved'
    body = f'''
Your account request has been approved!

Username: {username}
Temporary Password: {password}

Please login and change your password immediately after your first login.
For security, this password is randomly generated and should be changed.
'''
    send_email(email, subject, body)

def notify_user_rejected(email: str, username: str, reason: str):
    """Send email to user about rejection"""
    subject = 'Account request rejected'
    body = f'''
Your account request for username '{username}' has been rejected.

Reason: {reason}

If you believe this was an error, please contact the administrator.
'''
    send_email(email, subject, body)

# =============================================================================
# Routes
# =============================================================================

@app.get('/', response_class=HTMLResponse)
async def register_form(request: Request, success: Optional[str] = None, error: Optional[str] = None):
    """Public registration form"""
    return templates.TemplateResponse(
        'register.html',
        {'request': request, 'success': success, 'error': error}
    )

@app.post('/', response_class=HTMLResponse)
async def register_submit(
    request: Request,
    username: str = Form(...),
    email: str = Form(...),
    first_name: str = Form(...),
    last_name: str = Form(...),
    reason: str = Form(default='')
):
    """Handle registration form submission"""
    username = username.strip().lower()
    email = email.strip().lower()
    first_name = first_name.strip()
    last_name = last_name.strip()
    reason = reason.strip()

    if not all([username, email, first_name, last_name]):
        return templates.TemplateResponse(
            'register.html',
            {'request': request, 'error': 'All fields except reason are required'}
        )

    if not validate_username_strict(username):
        return templates.TemplateResponse(
            'register.html',
            {'request': request, 'error': 'Username must be 2-64 characters, start with a letter, and contain only lowercase letters, numbers, and underscores'}
        )

    if not validate_email_basic(email):
        return templates.TemplateResponse(
            'register.html',
            {'request': request, 'error': 'Invalid email address'}
        )

    if len(first_name) > 100 or len(last_name) > 100:
        return templates.TemplateResponse(
            'register.html',
            {'request': request, 'error': 'Names must be less than 100 characters'}
        )

    # Check if username or email already exists in lldap
    exists, error_msg = check_ldap_user_exists(username=username, email=email)
    if exists:
        return templates.TemplateResponse(
            'register.html',
            {'request': request, 'error': error_msg}
        )

    # Check for pending registration and insert in single transaction
    with get_db() as db:
        # Check if username or email already has a pending request
        existing = db.execute(
            'SELECT username, email FROM registration_requests WHERE username = ? OR email = ?',
            (username, email)
        ).fetchone()

        if existing:
            if existing[0] == username:
                return templates.TemplateResponse(
                    'register.html',
                    {'request': request, 'error': f'Username "{username}" already has a pending registration request'}
                )
            else:
                return templates.TemplateResponse(
                    'register.html',
                    {'request': request, 'error': f'Email "{email}" already has a pending registration request'}
                )

        # Insert new registration request
        try:
            db.execute(
                '''INSERT INTO registration_requests
                   (username, email, first_name, last_name, reason, ip_address, user_agent)
                   VALUES (?, ?, ?, ?, ?, ?, ?)''',
                (username, email, first_name, last_name, reason,
                 request.client.host, request.headers.get('User-Agent', ''))
            )
            db.commit()

            # Notify admin
            if ADMIN_EMAIL:
                notify_admin_new_request(username, email, reason)

            return RedirectResponse(
                url='/?success=Registration request submitted! An administrator will review it shortly.',
                status_code=303
            )

        except sqlite3.IntegrityError:
            return templates.TemplateResponse(
                'register.html',
                {'request': request, 'error': 'Username already exists or is pending approval'}
            )

@app.get('/admin', response_class=HTMLResponse)
async def admin_dashboard(request: Request):
    """Admin dashboard for reviewing registration requests"""
    admin_user = request.headers.get('Remote-User', 'unknown')

    with get_db() as db:
        pending = db.execute(
            'SELECT * FROM registration_requests ORDER BY created_at DESC'
        ).fetchall()

        audit_log = db.execute(
            'SELECT * FROM audit_log ORDER BY reviewed_at DESC LIMIT 50'
        ).fetchall()

    return templates.TemplateResponse(
        'admin.html',
        {
            'request': request,
            'pending': pending,
            'audit_log': audit_log,
            'admin_user': admin_user
        }
    )

@app.post('/admin/approve/{request_id}')
async def approve_request(request_id: int, request: Request):
    """Approve request: create user in lldap, move to audit log"""
    admin_user = request.headers.get('Remote-User', 'unknown')

    with get_db() as db:
        req = db.execute('SELECT * FROM registration_requests WHERE id = ?', (request_id,)).fetchone()

        if not req:
            raise HTTPException(status_code=404, detail='Request not found')

        # Create user in lldap with generated password
        success, password, error = await create_lldap_user(
            req['username'],
            req['email'],
            req['first_name'],
            req['last_name']
        )

        if success:
            # Move to audit log
            db.execute(
                '''INSERT INTO audit_log
                   (username, email, first_name, last_name, reason, action, performed_by,
                    ip_address, user_agent, created_at)
                   VALUES (?, ?, ?, ?, ?, 'APPROVED', ?, ?, ?, ?)''',
                (req['username'], req['email'], req['first_name'], req['last_name'],
                 req['reason'], admin_user, req['ip_address'], req['user_agent'], req['created_at'])
            )

            # Remove from pending queue
            db.execute('DELETE FROM registration_requests WHERE id = ?', (request_id,))
            db.commit()

            print(f'[SUCCESS] User {req["username"]} approved and created in lldap by {admin_user}')

            # Notify user
            notify_user_approved(req['email'], req['username'], password)
        else:
            print(f'[ERROR] Failed to create user {req["username"]}: {error}')

    return RedirectResponse(url='/admin', status_code=303)

@app.post('/admin/reject/{request_id}')
async def reject_request(request_id: int, request: Request, reason: str = Form(default='No reason provided')):
    """Reject request: move to audit log with reason"""
    admin_user = request.headers.get('Remote-User', 'unknown')

    with get_db() as db:
        req = db.execute('SELECT * FROM registration_requests WHERE id = ?', (request_id,)).fetchone()

        if not req:
            raise HTTPException(status_code=404, detail='Request not found')

        # Move to audit log
        db.execute(
            '''INSERT INTO audit_log
               (username, email, first_name, last_name, reason, action, performed_by,
                rejection_reason, ip_address, user_agent, created_at)
               VALUES (?, ?, ?, ?, ?, 'REJECTED', ?, ?, ?, ?, ?)''',
            (req['username'], req['email'], req['first_name'], req['last_name'],
             req['reason'], admin_user, reason, req['ip_address'], req['user_agent'], req['created_at'])
        )

        # Remove from pending queue
        db.execute('DELETE FROM registration_requests WHERE id = ?', (request_id,))
        db.commit()

        print(f'[INFO] User {req["username"]} rejected by {admin_user}: {reason}')

        # Notify user
        notify_user_rejected(req['email'], req['username'], reason)

    return RedirectResponse(url='/admin', status_code=303)

@app.get('/health')
async def health():
    """Health check endpoint"""
    return {'status': 'healthy'}
