# Multi-Admin Setup Guide

This guide explains how to configure org-stack for multiple administrators with proper permissions and shared access.

## Overview

By default, org-stack deploys to a user's home directory (`~/org-stack`). For production environments with multiple administrators, it's recommended to use a system-wide installation path with Unix group-based permissions.

## Architecture

**System-wide installation:**
```
/opt/org-stack/                    # Installation root (deploy:orgstack, 750)
├── .env                           # Configuration (deploy:orgstack, 640)
├── compose.yml                    # Docker Compose definition
├── secrets/                       # Auto-generated secrets (750)
│   ├── lldap/                     # Individual secrets (600)
│   └── authelia/
├── data/                          # Persistent Docker volumes
│   ├── gitea/
│   ├── wiki/
│   └── ...
└── backups/                       # Backup storage (750)
```

**Permissions:**
- Directories: `750` (rwxr-x---) - Owner full access, group read+execute
- Config files: `640` (rw-r-----) - Owner read+write, group read
- Secrets: `600` (rw-------) - Owner only (Docker reads as owner)
- Scripts: `750` (rwxr-x---) - Owner+group can execute

## One-Time Server Setup

These steps are performed **once** on the remote server by a sysadmin with sudo access.

### 1. Create Deployment User and Admin Group

```bash
# Create the admin group
sudo groupadd orgstack

# Create dedicated deployment user
sudo useradd -r -m -d /opt/org-stack -s /bin/bash -g orgstack deploy

# Add deployment user to docker group (required for docker compose)
sudo usermod -aG docker deploy

# Set password for deploy user (for SSH access)
sudo passwd deploy
```

### 2. Add Administrators to Group

```bash
# Add each admin to the orgstack group
sudo usermod -aG orgstack admin1
sudo usermod -aG orgstack admin2
sudo usermod -aG orgstack admin3

# Verify membership
getent group orgstack
# Output: orgstack:x:1001:admin1,admin2,admin3
```

**Important**: Admins must log out and log back in for group membership to take effect.

### 3. Create Installation Directory

```bash
# Create directory structure
sudo mkdir -p /opt/org-stack

# Set ownership
sudo chown -R deploy:orgstack /opt/org-stack

# Set permissions
sudo chmod 750 /opt/org-stack
```

### 4. Configure SSH Access

Each admin needs SSH access to the `deploy` user:

**Option A: SSH Key Authentication (recommended)**
```bash
# On admin's local machine, copy SSH key
ssh-copy-id deploy@your-server.com

# Test access
ssh deploy@your-server.com
```

**Option B: Password Authentication**
```bash
# Ensure password authentication is enabled in /etc/ssh/sshd_config
# PasswordAuthentication yes

# Admins use the deploy user password
ssh deploy@your-server.com
```

### 5. Optional: Sudo Access for Admins

If admins need to perform system tasks (install packages, restart services):

```bash
# Create sudoers file for orgstack group
sudo visudo -f /etc/sudoers.d/orgstack
```

Add:
```
# Allow orgstack group members to run docker commands
%orgstack ALL=(ALL) NOPASSWD: /usr/bin/docker, /usr/bin/docker-compose

# Or give full sudo access
%orgstack ALL=(ALL) ALL
```

## Local Deployment Configuration

Each admin configures their **local** `.env` file on their workstation (not on the server).

### 1. Clone Repository Locally

```bash
git clone https://github.com/yourorg/org-stack.git
cd org-stack
```

### 2. Configure .env for Multi-Admin

```bash
cp .env.example .env
nano .env
```

**Required settings:**
```bash
# Domain
BASE_DOMAIN=yourdomain.com

# Remote server connection (all admins use the same deploy user)
REMOTE_USER=deploy
REMOTE_HOST=your-server.com
REMOTE_PORT=22

# Multi-admin configuration
REMOTE_PATH=/opt/org-stack      # System-wide installation
ADMIN_GROUP=orgstack             # Unix group for permissions

# SMTP, 2FA, etc. (same for all admins)
REQUIRE_2FA=true
# ... other settings ...
```

### 3. Deploy from Local Machine

```bash
./deploy.sh
```

The script will:
1. Sync files to `/opt/org-stack` on remote server
2. Set group ownership to `orgstack`
3. Set permissions (750 for dirs, 640 for files, 600 for secrets)
4. Generate secrets if missing
5. Start Docker services

## Admin Workflows

### Deploying Changes

Any admin can deploy changes:

```bash
# On local machine
cd ~/org-stack
git pull  # Get latest changes
nano .env  # Modify configuration if needed
./deploy.sh
```

### Managing Services Remotely

```bash
# From local machine using manage.sh
./manage.sh status
./manage.sh logs authelia
./manage.sh restart

# Or SSH directly to server
ssh deploy@your-server.com
cd /opt/org-stack
docker compose ps
docker compose logs -f authelia
docker compose restart gitea
```

### Viewing Configuration

All group members can read configs:

```bash
ssh deploy@your-server.com
cd /opt/org-stack
cat .env
cat secrets/lldap/LDAP_USER_PASS
docker compose config  # Show resolved configuration
```

### Making Changes on Server

**Only the `deploy` user can modify files** (write permission). Admins must either:

**Option A: Deploy from local machine (recommended)**
```bash
# Edit .env locally, then deploy
./deploy.sh
```

**Option B: SSH as deploy user**
```bash
ssh deploy@your-server.com
cd /opt/org-stack
nano .env
docker compose up -d
```

**Option C: Use sudo (if configured)**
```bash
ssh admin1@your-server.com
cd /opt/org-stack
sudo -u deploy nano .env
sudo -u deploy docker compose up -d
```

## Security Considerations

### File Permissions

- **Secrets are owner-only (600)**: Only `deploy` user and Docker can read secrets
- **Configs are group-readable (640)**: Admins can audit configuration
- **No world access**: All files are 750/640/600 (no "others" permission)

### SSH Key Management

- Each admin should use their own SSH key to authenticate as `deploy` user
- Use `~deploy/.ssh/authorized_keys` to manage who has access
- Revoke access by removing admin's key from authorized_keys

### Audit Trail

Track who deployed what:

```bash
# On server, check file modification times
ls -la /opt/org-stack/.env

# Check who's currently logged in as deploy
who

# SSH logs show authentication
sudo journalctl -u ssh | grep deploy
```

### Backup Strategy

Only `deploy` user can create backups:

```bash
# From local machine
./manage.sh backup

# Or on server as deploy
ssh deploy@your-server.com
cd /opt/org-stack
docker compose exec registration python backup.py
```

Backups are stored in `/opt/org-stack/backups/` with 750 permissions (group-readable).

## Troubleshooting

### Permission Denied Errors

**Error:** `Permission denied: /opt/org-stack`

**Solution:** Ensure you're SSHing as `deploy` user:
```bash
ssh deploy@your-server.com  # Not your personal user
```

**Error:** `Failed to set group ownership`

**Solution:** Verify `deploy` user is in `orgstack` group:
```bash
groups deploy
# Should show: deploy : orgstack docker
```

### Group Membership Not Working

Admins must **log out and back in** after being added to group:
```bash
# On server
exit
ssh deploy@your-server.com
groups  # Should now show orgstack
```

### Docker Permission Denied

**Error:** `permission denied while trying to connect to Docker daemon`

**Solution:** Add `deploy` user to `docker` group:
```bash
sudo usermod -aG docker deploy
# Log out and back in
```

### Secrets Not Readable by Docker

**Error:** Container fails to start, can't read secret file

**Cause:** Secrets have 600 permissions, readable only by owner

**Solution:** This is correct! Docker runs containers as the file owner, so 600 is appropriate. Verify:
```bash
ls -l /opt/org-stack/secrets/lldap/LDAP_USER_PASS
# Should show: -rw------- 1 deploy orgstack
```

## Migration from Single-User Setup

If you're currently using `~/org-stack` and want to migrate to multi-admin:

### 1. Backup Current Deployment

```bash
ssh user@server
cd ~/org-stack
docker compose down
tar czf ~/org-stack-backup.tar.gz data/ secrets/ .env
```

### 2. Perform One-Time Server Setup

Follow steps in "One-Time Server Setup" section above.

### 3. Restore Data to New Location

```bash
# Extract backup
sudo tar xzf ~/org-stack-backup.tar.gz -C /opt/org-stack/

# Fix permissions
sudo chown -R deploy:orgstack /opt/org-stack
cd /opt/org-stack
sudo -u deploy bash
find . -type d -exec chmod 750 {} \;
find . -type f -exec chmod 640 {} \;
find secrets -type f -exec chmod 600 {} \;
```

### 4. Update Local .env

```bash
# On local machine
nano .env
# Change: REMOTE_DIR=org-stack
# To: REMOTE_PATH=/opt/org-stack
#     ADMIN_GROUP=orgstack
```

### 5. Deploy

```bash
./deploy.sh
```

## Alternative: Single Admin with System Path

If you want system-wide path but don't need multi-admin:

```bash
# In .env
REMOTE_PATH=/opt/org-stack
ADMIN_GROUP=  # Leave empty for single-user mode
```

Permissions will be standard (owner-only) without group access.

## Best Practices

1. **Use version control**: Keep `.env.example` in git, but never commit `.env`
2. **Document changes**: Use git commit messages to track infrastructure changes
3. **Test in staging**: Use `USE_SELF_SIGNED_CERTS=true` for testing deployments
4. **Regular backups**: Schedule automated backups with `./manage.sh backup`
5. **Audit access**: Regularly review `~deploy/.ssh/authorized_keys`
6. **Rotate secrets**: Periodically regenerate secrets (requires coordination)
7. **Communication**: Coordinate deployments among team (avoid conflicts)

## See Also

- [README.md](README.md) - Main documentation
- [ARCHITECTURE.md](ARCHITECTURE.md) - Technical architecture details
- [deploy.sh](deploy.sh) - Deployment script source
- [manage.sh](manage.sh) - Management operations
