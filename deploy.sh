#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { echo -e "${BLUE}➜${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }

echo "======================================="
echo "  Organization Stack Deployment"
echo "======================================="
echo

#=============================================================================
# 1. Initialize .env if missing
#=============================================================================
if [ ! -f .env ]; then
    log "Creating .env from template..."
    cp .env.example .env
    success ".env created"
    warn "Please edit .env with your configuration, then run deploy.sh again"
    exit 0
else
    log ".env exists, checking configuration..."
fi

# Source the .env file
set -a
source .env
set +a

# Validate required variables
if [ -z "$BASE_DOMAIN" ] || [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_HOST" ]; then
    error "Required variables missing in .env: BASE_DOMAIN, REMOTE_USER, REMOTE_HOST"
fi

success "Configuration validated"

#=============================================================================
# 2. Sync files to remote server
#=============================================================================
log "Syncing files to remote server ${REMOTE_USER}@${REMOTE_HOST}..."

# Create remote directory
ssh -p ${REMOTE_PORT:-22} ${REMOTE_USER}@${REMOTE_HOST} "mkdir -p ~/${REMOTE_DIR:-org-stack}" || \
    error "Failed to create remote directory"

# Sync all necessary files (excluding secrets - they'll be generated remotely)
rsync -avz --delete \
    --exclude='secrets/' \
    --exclude='.git/' \
    --exclude='*.tar.gz' \
    --exclude='backups/' \
    ./ ${REMOTE_USER}@${REMOTE_HOST}:~/${REMOTE_DIR:-org-stack}/ || \
    error "Failed to sync files"

success "Files synced to remote server"

#=============================================================================
# 3. Run remote deployment script
#=============================================================================
log "Running deployment on remote server..."

ssh -p ${REMOTE_PORT:-22} ${REMOTE_USER}@${REMOTE_HOST} "bash -s" <<'REMOTE_SCRIPT'

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}➜${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }

cd ~/org-stack

# Source environment
set -a
source .env
set +a

#=============================================================================
# Generate secrets
#=============================================================================
log "Checking secrets..."

mkdir -p secrets/lldap secrets/authelia

# Function to generate random secret
generate_secret_file() {
    local file_path=$1
    local length=${2:-32}

    if [ ! -f "$file_path" ]; then
        openssl rand -hex $length > "$file_path"
        chmod 600 "$file_path"
        log "Generated: $file_path"
    fi
}

# Function to generate random password (alphanumeric + special chars)
generate_password_file() {
    local file_path=$1
    local length=${2:-32}

    if [ ! -f "$file_path" ]; then
        # Generate password with letters, numbers, and some special chars
        < /dev/urandom tr -dc 'A-Za-z0-9!@#%^&*' | head -c${length} > "$file_path"
        chmod 600 "$file_path"
        log "Generated: $file_path"
    fi
}

# Generate all secret files
generate_secret_file "secrets/lldap/JWT_SECRET" 32
generate_password_file "secrets/lldap/LDAP_USER_PASS" 32
generate_secret_file "secrets/authelia/JWT_SECRET" 32
generate_secret_file "secrets/authelia/SESSION_SECRET" 32
generate_secret_file "secrets/authelia/STORAGE_ENCRYPTION_KEY" 32
generate_secret_file "secrets/authelia/OIDC_HMAC_SECRET" 32

# Generate Gitea OIDC secret in .env if missing
if ! grep -q "^GITEA_OIDC_CLIENT_SECRET=" .env || [ -z "$GITEA_OIDC_CLIENT_SECRET" ]; then
    GITEA_OIDC_CLIENT_SECRET=$(openssl rand -hex 36)
    echo "GITEA_OIDC_CLIENT_SECRET=${GITEA_OIDC_CLIENT_SECRET}" >> .env
    log "Generated GITEA_OIDC_CLIENT_SECRET"
    export GITEA_OIDC_CLIENT_SECRET
fi

# Generate RSA key using Docker
if [ ! -f "secrets/authelia/OIDC_PRIVATE_KEY" ]; then
    log "Generating RSA private key using Docker..."
    TEMP_DIR=$(mktemp -d)
    docker run --rm --user "$(id -u):$(id -g)" -v "$TEMP_DIR:/keys" authelia/authelia:latest \
        authelia crypto pair rsa generate --bits 2048 --directory /keys >/dev/null 2>&1 || \
        error "Failed to generate RSA key"

    if [ -f "$TEMP_DIR/private.pem" ]; then
        mv "$TEMP_DIR/private.pem" "secrets/authelia/OIDC_PRIVATE_KEY"
        chmod 600 "secrets/authelia/OIDC_PRIVATE_KEY"
        rm -rf "$TEMP_DIR"
        log "Generated: OIDC_PRIVATE_KEY"
    else
        rm -rf "$TEMP_DIR"
        error "RSA key generation failed"
    fi
fi

success "All secrets ready"

#=============================================================================
# Derive LDAP_BASE_DN
#=============================================================================
if [ "$LDAP_BASE_DN" = "AUTO" ]; then
    log "Deriving LDAP_BASE_DN from BASE_DOMAIN..."
    DERIVED_DN=$(echo "$BASE_DOMAIN" | sed 's/\./,dc=/g' | sed 's/^/dc=/')
    sed -i "s|^LDAP_BASE_DN=.*|LDAP_BASE_DN=${DERIVED_DN}|" .env
    export LDAP_BASE_DN="$DERIVED_DN"
    success "LDAP_BASE_DN set to: $DERIVED_DN"
fi

#=============================================================================
# Hash Gitea OIDC client secret
#=============================================================================
log "Hashing Gitea OIDC client secret..."

# Re-source .env to get GITEA_OIDC_CLIENT_SECRET
source .env

GITEA_OIDC_CLIENT_SECRET_HASH=$(docker run --rm authelia/authelia:latest \
    authelia crypto hash generate pbkdf2 --variant sha512 --password "$GITEA_OIDC_CLIENT_SECRET" 2>&1 | \
    grep 'Digest:' | awk '{print $2}')

if [ -z "$GITEA_OIDC_CLIENT_SECRET_HASH" ]; then
    error "Failed to hash Gitea client secret"
fi

export GITEA_OIDC_CLIENT_SECRET_HASH
success "Gitea client secret hashed"

#=============================================================================
# Set authentication policy
#=============================================================================
if [ "$REQUIRE_2FA" = "true" ]; then
    export AUTH_POLICY="two_factor"
else
    export AUTH_POLICY="one_factor"
fi

#=============================================================================
# Generate Caddyfile from template
#=============================================================================
log "Generating Caddyfile..."

if [ "$USE_SELF_SIGNED_CERTS" = "true" ]; then
    envsubst < Caddyfile.test.template > Caddyfile
    success "Generated Caddyfile (self-signed mode)"
else
    envsubst < Caddyfile.production.template > Caddyfile
    success "Generated Caddyfile (Let's Encrypt mode)"
fi

#=============================================================================
# Generate Authelia configuration
#=============================================================================
log "Generating Authelia configuration..."

# Use appropriate template based on SMTP_ENABLED
if [ "${SMTP_ENABLED:-false}" = "true" ]; then
    log "Using SMTP email notifications..."
    envsubst < authelia/configuration.yml.smtp.template > authelia/configuration.yml
else
    log "Using filesystem notifier..."
    envsubst < authelia/configuration.yml.filesystem.template > authelia/configuration.yml
fi

success "Generated authelia/configuration.yml"

#=============================================================================
# Start services
#=============================================================================
log "Starting services..."

docker compose up -d || error "Failed to start services"

success "Services started successfully!"

#=============================================================================
# Display service information
#=============================================================================
echo
echo "======================================="
echo "  Deployment Complete!"
echo "======================================="
echo
echo "Services available at:"
echo "  • Gitea:        https://${GITEA_SUBDOMAIN}.${BASE_DOMAIN}"
echo "  • Wiki:         https://${WIKI_SUBDOMAIN}.${BASE_DOMAIN}"
echo "  • Authelia:     https://${AUTH_SUBDOMAIN}.${BASE_DOMAIN}"
echo "  • lldap:        https://${LLDAP_SUBDOMAIN}.${BASE_DOMAIN}"
echo "  • Registration: https://${REGISTRATION_SUBDOMAIN}.${BASE_DOMAIN}"
echo

# Read and display credentials
if [ -f "secrets/lldap/LDAP_USER_PASS" ]; then
    LLDAP_PASS=$(cat secrets/lldap/LDAP_USER_PASS)
    echo "lldap admin credentials:"
    echo "  • Username: admin"
    echo "  • Password: ${LLDAP_PASS}"
    echo
fi

if [ -n "$GITEA_OIDC_CLIENT_SECRET" ]; then
    echo "Gitea OIDC credentials:"
    echo "  • Client ID:     gitea"
    echo "  • Client Secret: ${GITEA_OIDC_CLIENT_SECRET}"
    echo
fi

echo -e "${YELLOW}⚠${NC} Save these credentials securely!"
echo

REMOTE_SCRIPT

if [ $? -eq 0 ]; then
    success "Deployment completed successfully on ${REMOTE_HOST}!"
    echo
    echo "Next steps:"
    echo "  1. Access lldap at https://${LLDAP_SUBDOMAIN}.${BASE_DOMAIN}"
    echo "  2. Create user accounts"
    echo "  3. Configure Gitea OIDC (see README.md)"
    echo
else
    error "Deployment failed"
fi
