# CLAUDE.md

This file provides guidance to AI assistants (like Claude Code) when working with this repository.

## Project Overview

**Project Type**: Self-hosted authentication and collaboration platform
**Primary Language**: Shell (deployment), YAML (configuration), Java (JSPWiki customization)
**Architecture**: Docker Compose multi-container application
**Deployment Model**: Remote deployment via SSH/rsync from local machine

### Core Services
1. **lldap** - LDAP user directory (Rust application, pre-built image)
2. **Authelia** - SSO/2FA server (Go application, pre-built image)
3. **Gitea** - Git hosting (Go application, pre-built image)
4. **JSPWiki** - Wiki platform (Java/Tomcat, custom Docker image)
5. **Caddy** - Reverse proxy (Go application, pre-built image)

## Project Philosophy

### Single Source of Truth
- `.env` file is the **only** place users configure the system
- All service configs are generated from `.env` via templates
- **Never** require users to edit multiple config files
- **Never** hardcode values that should be configurable

### Zero Manual Steps
- `./deploy.sh` should handle everything from secrets to deployment
- User should only need to edit `.env` and run one command
- Secrets auto-generated if missing
- Configs auto-generated from templates
- Service dependencies handled automatically

### Security First
- File-based secrets (not environment variables)
- Read-only mounts where possible
- Secrets never committed to git
- Modern authentication protocols (LDAP, OIDC, Forward-Auth)
- Defense in depth architecture

### Educational Value
- Code should teach authentication patterns
- Comments explain "why" not just "what"
- Documentation references RFCs and specs
- Architecture demonstrates industry best practices

## File Structure and Responsibilities

```
org-stack/
├── .env.example              # Configuration template (edit this to add new options)
├── .env                      # User configuration (generated, not in git)
├── .gitignore                # Ensures secrets/ and .env not committed
│
├── deploy.sh                 # Main deployment script
│   ├── Checks/creates .env
│   ├── Generates secrets if missing
│   ├── Derives LDAP_BASE_DN from BASE_DOMAIN
│   ├── Hashes Gitea OIDC secret
│   ├── Generates configs from templates
│   └── Rsyncs to remote server and starts services
│
├── manage.sh                 # Management operations on remote server
│   ├── logs, restart, update
│   ├── backup, restore
│   └── status, reset
│
├── compose.yml               # Docker Compose service definitions
│   ├── Service configs with educational comments
│   ├── Volume mounts (configs, secrets, data)
│   └── Network and dependency definitions
│
├── Caddyfile.production.template  # Caddy config for Let's Encrypt
├── Caddyfile.test.template        # Caddy config for self-signed certs
│   └── Generated to Caddyfile by deploy.sh based on USE_SELF_SIGNED_CERTS
│
├── authelia/
│   └── configuration.yml.template  # Authelia config template
│       ├── Uses modern v4.38+ syntax (no deprecation warnings)
│       ├── References secrets via _FILE environment variables
│       └── Generated to configuration.yml by deploy.sh
│
├── jspwiki/
│   ├── Dockerfile                  # Custom JSPWiki image with SSO support
│   ├── RemoteUserFilter.java       # Servlet filter for container auth
│   ├── ldap-sync.sh                # Syncs lldap users to JSPWiki XML
│   ├── configure-web-xml.sh        # Modifies web.xml for RemoteUserFilter
│   └── entrypoint.sh               # Container startup: sync LDAP, start Tomcat
│
├── jspwiki-custom.properties  # JSPWiki config (container auth enabled)
├── jspwiki.policy             # JSPWiki security policy
│
├── secrets/                   # Auto-generated secrets (NEVER commit)
│   ├── lldap/
│   │   ├── JWT_SECRET
│   │   └── LDAP_USER_PASS
│   └── authelia/
│       ├── JWT_SECRET
│       ├── SESSION_SECRET
│       ├── STORAGE_ENCRYPTION_KEY
│       ├── OIDC_HMAC_SECRET
│       └── OIDC_PRIVATE_KEY
│
└── Documentation
    ├── README.md             # User-facing documentation and quick start
    ├── ARCHITECTURE.md       # Technical deep-dive
    └── CLAUDE.md             # This file (AI assistant guidance)
```

## Common Tasks

### Adding a New Configuration Option

1. **Add to `.env.example`** with clear comments and default value
2. **Update template file** (Caddyfile or authelia config) to use `${NEW_VAR}`
3. **Update `deploy.sh`** to export the variable for envsubst
4. **Update documentation** (README.md) if user-facing
5. **Test** by removing .env and running deploy.sh

Example:
```bash
# .env.example
NEW_FEATURE_ENABLED=true  # Enable new feature

# authelia/configuration.yml.template
new_feature:
  enabled: ${NEW_FEATURE_ENABLED}

# deploy.sh (in export section)
export NEW_FEATURE_ENABLED
```

### Adding a New Service

1. **Add service to `compose.yml`** with clear comments
2. **Add subdomain to `.env.example`** (e.g., `NEWSERVICE_SUBDOMAIN=new`)
3. **Add to Caddyfile templates** with appropriate auth config
4. **Update `deploy.sh`** summary section to show new URL
5. **Update `manage.sh`** if service needs special handling
6. **Document in README.md** and ARCHITECTURE.md

### Modifying Authelia Configuration

**Important**: Always use **modern v4.38+ syntax**. Check [Authelia docs](https://www.authelia.com/configuration/prologue/introduction/) for latest syntax.

Common deprecations to avoid:
- ❌ `username_attribute` → ✅ `attributes.username`
- ❌ `access_token_lifespan` → ✅ `lifespans.access_token`
- ❌ `issuer_private_key: |` → ✅ Use `*_FILE` env var

When adding new features:
1. Check if Authelia exposes secret via `*_FILE` env variable
2. If yes, use file-based secret (add to deploy.sh generation)
3. If no, use template variable from .env

### Working with Secrets

**Adding a new secret:**

```bash
# 1. Add generation to deploy.sh
generate_secret_file "secrets/authelia/NEW_SECRET" 32

# 2. Add environment variable to compose.yml
environment:
  - AUTHELIA_NEW_SECRET_FILE=/secrets/NEW_SECRET

# 3. Add volume mount if in new directory
volumes:
  - ./secrets/authelia:/secrets:ro

# 4. Reference in template with comment
# authelia/configuration.yml.template
# new_secret read from AUTHELIA_NEW_SECRET_FILE
```

**Never:**
- ❌ Commit secrets to git
- ❌ Put secrets in environment variables (use _FILE pattern)
- ❌ Echo secrets in logs
- ❌ Use predictable secret values

### Debugging Authentication Issues

**Check in this order:**

1. **Service Status**
   ```bash
   ssh user@host 'cd ~/org-stack && docker compose ps'
   ```
   All services should be "Up" and "healthy" (Authelia)

2. **Authelia Logs**
   ```bash
   ssh user@host 'cd ~/org-stack && docker compose logs authelia | tail -50'
   ```
   Look for:
   - Configuration errors (missing secrets, bad syntax)
   - LDAP connection errors
   - Authentication failures

3. **Secret Files**
   ```bash
   ssh user@host 'ls -la ~/org-stack/secrets/authelia/'
   ```
   All files should exist with 600 permissions

4. **Network Connectivity**
   ```bash
   ssh user@host 'cd ~/org-stack && docker compose exec gitea curl http://authelia:9091/.well-known/openid-configuration'
   ```
   Should return JSON (OIDC discovery document)

5. **LDAP Connectivity**
   ```bash
   ssh user@host 'cd ~/org-stack && docker compose exec authelia ldapsearch -H ldap://lldap:3890 -D "uid=admin,ou=people,dc=example,dc=com" -w "$(cat secrets/lldap/LDAP_USER_PASS)" -b "dc=example,dc=com" "(uid=admin)"'
   ```
   Should return admin user entry

### Common Error Patterns

**"502 Bad Gateway" on all services except Gitea**
- **Cause**: Authelia container not running or crashing
- **Check**: `docker compose logs authelia`
- **Common root cause**: Missing or incorrect secret file path

**"No such host" errors in Caddy logs**
- **Cause**: Docker network issues or service not started
- **Fix**: `docker compose down && docker compose up -d`

**"Certificate signed by unknown authority" in Gitea**
- **Cause**: Gitea trying to use external HTTPS URL with self-signed cert
- **Fix**: Use internal URL in OIDC config: `http://authelia:9091/...`

**Authelia deprecation warnings in logs**
- **Cause**: Using old configuration syntax
- **Fix**: Update `authelia/configuration.yml.template` to modern syntax
- **Reference**: [Authelia Migration Guides](https://www.authelia.com/reference/guides/migration/)

## Code Style Guidelines

### Shell Scripts (deploy.sh, manage.sh)

```bash
# Good: Clear error messages with context
if [ ! -f .env ]; then
    error ".env file not found. Copy .env.example to .env and configure."
fi

# Good: Functions with clear names
generate_secret_file() {
    local file_path=$1
    local length=${2:-32}
    # ...
}

# Good: Comments explain "why"
# Derive LDAP_BASE_DN from BASE_DOMAIN because most users won't know LDAP DN format
if [ "$LDAP_BASE_DN" = "AUTO" ]; then
    DERIVED_DN=$(echo "$BASE_DOMAIN" | sed 's/\./,dc=/g' | sed 's/^/dc=/')
    # ...
fi
```

### YAML Configuration

```yaml
# Good: Comments explain purpose and link to docs
authentication_backend:
  ldap:
    # lldap connection settings
    # See: https://github.com/lldap/lldap
    address: 'ldap://lldap:3890'

# Good: Group related settings
lifespans:
  access_token: ${ACCESS_TOKEN_LIFESPAN}
  authorize_code: ${AUTHORIZE_CODE_LIFESPAN}
  id_token: ${ID_TOKEN_LIFESPAN}
  refresh_token: ${REFRESH_TOKEN_LIFESPAN}
```

### Docker Compose

```yaml
# Good: Comments explain auth method and purpose
gitea:
  # Self-hosted Git service
  # Uses OIDC to authenticate users through Authelia (SSO)
  image: gitea/gitea:latest
  environment:
    - GITEA__server__DOMAIN=${GITEA_SUBDOMAIN}.${BASE_DOMAIN}
  volumes:
    - gitea_data:/data    # Git repos, database, config
```

## Testing Approach

### Before Committing Changes

1. **Test fresh deployment**:
   ```bash
   rm .env
   rm -rf secrets/
   ./deploy.sh
   ```

2. **Verify services start**:
   ```bash
   ssh user@host 'cd ~/org-stack && docker compose ps'
   ```
   All should be "Up"

3. **Test authentication flow**:
   - Create user in lldap
   - Login to wiki (tests Forward-Auth + 2FA)
   - Login to Gitea (tests OIDC + 2FA)

4. **Check for deprecation warnings**:
   ```bash
   ssh user@host 'cd ~/org-stack && docker compose logs authelia' | grep -i deprecat
   ```
   Should be zero warnings

5. **Verify secrets not in git**:
   ```bash
   git status
   ```
   secrets/ and .env should not appear

### Test Scenarios

**Scenario 1: First-time deployment**
- User has never deployed before
- Should complete with zero manual steps
- All secrets auto-generated

**Scenario 2: Configuration change**
- User changes BASE_DOMAIN in .env
- Runs deploy.sh
- All services update to new domain

**Scenario 3: Secret rotation**
- Delete a secret file
- Run deploy.sh
- Secret regenerated, services restart

**Scenario 4: Disaster recovery**
- Backup volumes with manage.sh backup
- Destroy everything with manage.sh reset
- Restore from backup
- Everything works

## Understanding the Authentication Flow

### When User Accesses Wiki

```
1. Browser → Caddy: GET https://wiki.example.com/
2. Caddy → Authelia: Forward-auth subrequest to /api/authz/forward-auth
3. Authelia checks session cookie:
   a. If valid session: Return 200 + Remote-User header
   b. If no session: Return 401 + redirect to login
4. If 401:
   - Caddy → Browser: 302 to Authelia login
   - User enters credentials
   - Authelia → lldap: Validate password via LDAP BIND
   - Authelia prompts for TOTP (if REQUIRE_2FA=true)
   - Authelia creates session, sets cookie
   - Authelia → Browser: 302 back to wiki
5. Caddy forwards request to JSPWiki with Remote-User header
6. JSPWiki trusts Remote-User (via RemoteUserFilter)
7. User sees wiki page as authenticated user
```

### When User Accesses Gitea

```
1. Browser → Gitea: Click "Sign in with OpenID Connect"
2. Gitea → Browser: 302 to Authelia /api/oidc/authorization
3. Authelia checks session:
   a. If valid: Skip to step 5
   b. If no session: Show login + 2FA
4. User authenticates (same as wiki flow)
5. Authelia → Browser: 302 to Gitea callback with code
6. Gitea → Authelia: POST /api/oidc/token with code
7. Authelia → Gitea: Access token + ID token (JWT)
8. Gitea validates JWT, extracts user info
9. Gitea creates local session
10. User logged into Gitea (SSO - no credential re-entry if already logged into wiki)
```

## When to Ask User for Clarification

**Always ask before:**
- Changing authentication behavior (2FA, SSO, etc.)
- Modifying security-related code
- Breaking changes to .env configuration
- Changing default behavior
- Adding new external dependencies

**No need to ask for:**
- Bug fixes (broken features)
- Documentation improvements
- Code cleanup/refactoring (no behavior change)
- Adding educational comments
- Fixing deprecation warnings

## Important Constraints

### Do Not

- ❌ Add configuration that requires editing multiple files
- ❌ Use deprecated Authelia configuration syntax
- ❌ Put secrets in environment variables (use _FILE pattern)
- ❌ Create services without proper health checks
- ❌ Bypass authentication (all services must auth via Authelia)
- ❌ Hardcode domains, IPs, or credentials
- ❌ Use `latest` tags for critical services (prefer versioned tags)
- ❌ Mix forward-auth and OIDC on same service

### Always

- ✅ Use file-based secrets
- ✅ Mount secrets read-only (`:ro`)
- ✅ Add educational comments to configs
- ✅ Test full deployment flow
- ✅ Keep `.env.example` in sync with actual usage
- ✅ Update documentation when changing behavior
- ✅ Use modern Authelia v4.38+ syntax
- ✅ Reference official docs/RFCs in comments

## Resources

### Official Documentation
- [lldap](https://github.com/lldap/lldap)
- [Authelia](https://www.authelia.com/)
- [Gitea](https://docs.gitea.io/)
- [JSPWiki](https://jspwiki-wiki.apache.org/)
- [Caddy](https://caddyserver.com/docs/)

### Protocol Specifications
- [LDAP - RFC 4511](https://tools.ietf.org/html/rfc4511)
- [OIDC Core 1.0](https://openid.net/specs/openid-connect-core-1_0.html)
- [OAuth 2.0 - RFC 6749](https://tools.ietf.org/html/rfc6749)
- [TOTP - RFC 6238](https://tools.ietf.org/html/rfc6238)

### Helpful Articles
- [Understanding OIDC](https://connect2id.com/learn/openid-connect)
- [Forward-Auth Pattern](https://www.authelia.com/integration/proxies/fowarded-headers/)
- [Docker Secrets Best Practices](https://docs.docker.com/engine/swarm/secrets/)

## Project Goals

This project aims to:
1. **Demonstrate** modern authentication patterns (LDAP, OIDC, Forward-Auth)
2. **Educate** about SSO, 2FA, and centralized user management
3. **Provide** production-ready self-hosted alternative to cloud services
4. **Showcase** Docker Compose best practices
5. **Maintain** simplicity - one command deployment, zero manual config

When working on this project, prioritize these goals:
- Make it easier to deploy
- Make it more educational
- Make it more secure
- Make it well-documented

## Current State

**Production Ready**: Yes (with appropriate configuration)
**Deployment Model**: Remote server via SSH/rsync
**Supported Platforms**: Linux (Docker required)
**Active Development**: Yes

**Known Limitations**:
- SQLite databases (acceptable for <10k users)
- Filesystem notifier (should be SMTP for production)
- Single server deployment (no HA)

**Improvement Opportunities**:
- Add Redis for Authelia session storage
- Add PostgreSQL option for Gitea
- Add Prometheus monitoring
- Add automated backup scheduling
- Add user import scripts (CSV → lldap)

## Final Notes

This is a **teaching project** as much as a production tool. Code should be:
- **Readable** - clear variable names, educational comments
- **Reliable** - error handling, validation, health checks
- **Reproducible** - anyone should be able to deploy successfully
- **Referenced** - link to RFCs, docs, and explanations

When in doubt, prioritize clarity over cleverness, and security over convenience.

If you're working on this project as an AI assistant, remember:
- The user may not be an expert in authentication protocols
- Comments should explain "why" not just "what"
- Changes should work end-to-end (don't break deployment)
- Documentation is as important as code

Good luck! 🚀
