#!/bin/bash

# sync-gitea-users.sh
# Creates Gitea user accounts for all lldap users
# Accounts will auto-link when users first log in via OIDC

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log() { echo -e "${BLUE}➜${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }

# Load .env if it exists
if [ -f .env ]; then
    source .env
else
    error ".env file not found"
fi

# Get LDAP admin password
if [ ! -f "secrets/lldap/LDAP_USER_PASS" ]; then
    error "LDAP admin password file not found"
fi

LDAP_ADMIN_PASS=$(cat secrets/lldap/LDAP_USER_PASS)
LDAP_BASE_DN=${LDAP_BASE_DN}

log "Fetching users from lldap..."

# Query lldap for all users
USERS=$(docker compose exec -T lldap ldapsearch \
    -H ldap://localhost:3890 \
    -D "uid=admin,ou=people,${LDAP_BASE_DN}" \
    -w "${LDAP_ADMIN_PASS}" \
    -b "ou=people,${LDAP_BASE_DN}" \
    "(objectClass=person)" \
    uid mail displayName 2>/dev/null | \
    awk '
        /^dn:/ { if (uid) print uid","email","name; uid=""; email=""; name="" }
        /^uid:/ { uid=$2 }
        /^mail:/ { email=$2 }
        /^displayName:/ { $1=""; name=substr($0,2) }
        END { if (uid) print uid","email","name }
    ')

if [ -z "$USERS" ]; then
    warn "No users found in lldap"
    exit 0
fi

log "Found $(echo "$USERS" | wc -l) users in lldap"
echo

# Create Gitea users
while IFS=',' read -r username email displayname; do
    # Skip admin user if it already exists
    if [ "$username" = "admin" ]; then
        log "Skipping admin user (should be created during initial setup)"
        continue
    fi

    log "Processing user: $username ($email)"

    # Check if user exists in Gitea
    if docker compose exec --user git gitea gitea admin user list 2>/dev/null | grep -q "^[0-9]*[[:space:]]*${username}[[:space:]]"; then
        success "User $username already exists in Gitea"
        continue
    fi

    # Create user in Gitea
    # Use --random-password since user will log in via OIDC
    # --must-change-password false since they won't use the local password
    if docker compose exec --user git gitea gitea admin user create \
        --username "$username" \
        --email "$email" \
        --random-password \
        --must-change-password=false \
        --admin=false 2>/dev/null; then
        success "Created Gitea user: $username"
    else
        warn "Failed to create user: $username (may already exist)"
    fi
done <<< "$USERS"

echo
success "User synchronization complete!"
log "Users can now log in to Gitea via OIDC and their accounts will auto-link"
