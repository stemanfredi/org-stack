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
else
    log ".env exists, checking for missing values..."
fi

# Source the .env file
set -a
source .env
set +a

#=============================================================================
# 2. Generate missing secrets
#=============================================================================

# Create secrets directories
mkdir -p secrets/lldap secrets/authelia

# Generate secret and save to file
generate_secret_file() {
    local file_path=$1
    local length=${2:-32}

    if [ ! -f "$file_path" ]; then
        openssl rand -hex $length > "$file_path"
        chmod 600 "$file_path"
        log "Generated secret file: $file_path"
    fi
}

# Generate password and save to file
generate_password_file() {
    local file_path=$1

    if [ ! -f "$file_path" ]; then
        openssl rand -base64 24 > "$file_path"
        chmod 600 "$file_path"
        log "Generated password file: $file_path"
    fi
}

# Legacy function for backwards compatibility (still used for GITEA_OIDC_CLIENT_SECRET)
generate_secret() {
    local var_name=$1
    local length=${2:-32}
    local current_value="${!var_name}"

    if [ -z "$current_value" ]; then
        local new_secret=$(openssl rand -hex $length)
        sed -i "s|^${var_name}=.*|${var_name}=${new_secret}|" .env
        eval "export ${var_name}=${new_secret}"
        log "Generated ${var_name}"
    fi
}

log "Checking secrets..."

# lldap secrets (file-based)
generate_secret_file "secrets/lldap/JWT_SECRET" 32
generate_password_file "secrets/lldap/LDAP_USER_PASS"

# Authelia secrets (file-based)
generate_secret_file "secrets/authelia/JWT_SECRET" 32
generate_secret_file "secrets/authelia/SESSION_SECRET" 32
generate_secret_file "secrets/authelia/STORAGE_ENCRYPTION_KEY" 32
generate_secret_file "secrets/authelia/OIDC_HMAC_SECRET" 32

# Gitea OIDC secret (still in .env - needed for hashing)
generate_secret "GITEA_OIDC_CLIENT_SECRET" 36

# Generate RSA key if missing (file-based)
if [ ! -f "secrets/authelia/OIDC_PRIVATE_KEY" ]; then
    log "Generating RSA private key for OIDC..."
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    # Generate key with proper permissions by using current user
    docker run --rm --user "$(id -u):$(id -g)" -v "$TEMP_DIR:/keys" authelia/authelia:latest \
        authelia crypto pair rsa generate --bits 2048 --directory /keys >/dev/null 2>&1 || \
        error "Failed to generate RSA key. Is Docker running?"

    if [ ! -f "$TEMP_DIR/private.pem" ]; then
        error "RSA key generation failed"
    fi

    # Move the private key to secrets directory
    mv "$TEMP_DIR/private.pem" "secrets/authelia/OIDC_PRIVATE_KEY"
    chmod 600 "secrets/authelia/OIDC_PRIVATE_KEY"

    log "Generated OIDC_PRIVATE_KEY file"
fi

success "All secrets ready"

#=============================================================================
# 3. Derive LDAP_BASE_DN from BASE_DOMAIN if AUTO
#=============================================================================
source .env

if [ "$LDAP_BASE_DN" = "AUTO" ]; then
    log "Deriving LDAP_BASE_DN from BASE_DOMAIN..."
    DERIVED_DN=$(echo "$BASE_DOMAIN" | sed 's/\./,dc=/g' | sed 's/^/dc=/')
    sed -i "s|^LDAP_BASE_DN=.*|LDAP_BASE_DN=${DERIVED_DN}|" .env
    export LDAP_BASE_DN="$DERIVED_DN"
    success "LDAP_BASE_DN set to: $DERIVED_DN"
fi

#=============================================================================
# 4. Hash Gitea OIDC client secret for Authelia
#=============================================================================
log "Hashing Gitea OIDC client secret..."

GITEA_OIDC_CLIENT_SECRET_HASH=$(docker run --rm authelia/authelia:latest \
    authelia crypto hash generate pbkdf2 --variant sha512 --password "$GITEA_OIDC_CLIENT_SECRET" 2>&1 | \
    grep 'Digest:' | awk '{print $2}')

if [ -z "$GITEA_OIDC_CLIENT_SECRET_HASH" ]; then
    error "Failed to hash Gitea client secret"
fi

export GITEA_OIDC_CLIENT_SECRET_HASH
success "Gitea client secret hashed"

#=============================================================================
# 5. Set authentication policy based on 2FA requirement
#=============================================================================
if [ "${REQUIRE_2FA}" = "true" ]; then
    AUTH_POLICY="two_factor"
    log "2FA enabled - requiring two-factor authentication"
else
    AUTH_POLICY="one_factor"
    warn "2FA disabled - only requiring username/password (not recommended for production)"
fi
export AUTH_POLICY

#=============================================================================
# 6. Generate configuration files from templates
#=============================================================================
log "Generating configuration files..."

# Export all variables for envsubst
export BASE_DOMAIN GITEA_SUBDOMAIN WIKI_SUBDOMAIN AUTHELIA_SUBDOMAIN LLDAP_SUBDOMAIN
export LDAP_BASE_DN LLDAP_LDAP_USER_PASS AUTH_POLICY
export SESSION_EXPIRATION SESSION_INACTIVITY SESSION_REMEMBER_ME
export MAX_RETRIES FIND_TIME BAN_TIME
export ACCESS_TOKEN_LIFESPAN AUTHORIZE_CODE_LIFESPAN ID_TOKEN_LIFESPAN REFRESH_TOKEN_LIFESPAN
export GITEA_OIDC_CLIENT_SECRET_HASH

# Generate Caddyfile (select template based on USE_SELF_SIGNED_CERTS)
if [ "$USE_SELF_SIGNED_CERTS" = "true" ]; then
    envsubst < Caddyfile.test.template > Caddyfile
    success "Generated Caddyfile (testing mode with self-signed certificates)"
else
    envsubst < Caddyfile.production.template > Caddyfile
    success "Generated Caddyfile (production mode with Let's Encrypt)"
fi

# Generate Authelia config (secrets read from files at runtime)
envsubst < authelia/configuration.yml.template > authelia/configuration.yml

success "Generated authelia/configuration.yml"

#=============================================================================
# 6. Display configuration summary
#=============================================================================
echo
echo "======================================="
echo "  Configuration Summary"
echo "======================================="
echo

# Display TLS mode
if [ "$USE_SELF_SIGNED_CERTS" = "true" ]; then
    warn "TLS Mode: Testing (self-signed certificates)"
    echo "  ⚠ Browser will show certificate warnings - accept and continue"
    echo "  ℹ Avoids Let's Encrypt rate limits during development"
    echo "  → Switch to production: Set USE_SELF_SIGNED_CERTS=false in .env"
else
    echo "TLS Mode: Production (Let's Encrypt automatic certificates)"
    echo "  ✓ Trusted certificates - no browser warnings"
    echo "  ℹ Ensure DNS points to this server and ports 80/443 are accessible"
fi
echo

echo "Domain access (via Caddy reverse proxy):"
echo "  • Gitea:    https://${GITEA_SUBDOMAIN}.${BASE_DOMAIN}"
echo "  • Wiki:     https://${WIKI_SUBDOMAIN}.${BASE_DOMAIN}"
echo "  • Authelia: https://${AUTHELIA_SUBDOMAIN}.${BASE_DOMAIN}"
echo "  • lldap:    https://${LLDAP_SUBDOMAIN}.${BASE_DOMAIN}"
echo
echo "Direct port access (from server or via port forwarding):"
echo "  • Gitea:    http://localhost:${GITEA_HTTP_PORT}"
echo "  • Wiki:     http://localhost:8080"
echo "  • Authelia: http://localhost:${AUTHELIA_PORT}"
echo "  • lldap:    http://localhost:${LLDAP_HTTP_PORT}"
echo
echo "lldap admin credentials:"
echo "  • Username: admin"
echo "  • Password: $(cat secrets/lldap/LDAP_USER_PASS)"
echo
echo "Gitea OIDC credentials:"
echo "  • Client ID:     gitea"
echo "  • Client Secret: ${GITEA_OIDC_CLIENT_SECRET}"
echo
warn "Save these credentials securely!"
echo

#=============================================================================
# 7. Deploy to remote server
#=============================================================================
log "Syncing files to remote server ${REMOTE_USER}@${REMOTE_HOST}..."

# Create remote directory
ssh -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} "mkdir -p ~/${REMOTE_DIR}" || \
    error "Failed to create remote directory. Check SSH access."

# Rsync project files to remote server
rsync -avz --delete \
    --exclude='.git' \
    --exclude='backups' \
    --exclude='.env.example' \
    --exclude='README.md' \
    --exclude='*.md' \
    -e "ssh -p ${REMOTE_PORT}" \
    ./ ${REMOTE_USER}@${REMOTE_HOST}:~/${REMOTE_DIR}/ || \
    error "Failed to rsync files to remote server"

success "Files synced to remote server"

#=============================================================================
# 8. Start the stack on remote server
#=============================================================================
read -p "Start the stack on remote server now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Starting services on ${REMOTE_HOST}..."

    ssh -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} "cd ~/${REMOTE_DIR} && docker compose up -d" || \
        error "Failed to start services on remote server"

    echo
    success "Stack deployed successfully on ${REMOTE_HOST}!"
    echo
    echo "Next steps:"
    echo "  1. Wait ~30 seconds for services to start"
    echo "  2. Access lldap at https://${LLDAP_SUBDOMAIN}.${BASE_DOMAIN}"
    echo "     (or direct: http://${REMOTE_HOST}:${LLDAP_HTTP_PORT})"
    echo "  3. Create a user account in lldap"
    echo "  4. Access Gitea at https://${GITEA_SUBDOMAIN}.${BASE_DOMAIN}"
    echo "     (or direct: http://${REMOTE_HOST}:${GITEA_HTTP_PORT})"
    echo "  5. Complete Gitea installation wizard"
    echo "  6. Configure OIDC in Gitea admin panel"
    echo
    echo "Remote management:"
    echo "  • View logs: ./manage.sh logs [service]"
    echo "  • Restart:   ./manage.sh restart"
    echo "  • Status:    ./manage.sh status"
    echo
    echo "For detailed setup instructions, see CLAUDE.md"
else
    echo
    success "Configuration ready!"
    echo "To start manually:"
    echo "  ssh ${REMOTE_USER}@${REMOTE_HOST} 'cd ~/${REMOTE_DIR} && docker compose up -d'"
    echo
    echo "Or use: ./manage.sh start"
fi

echo
