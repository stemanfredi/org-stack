# Organization Stack

A self-hosted collaboration and authentication platform featuring Single Sign-On (SSO), Two-Factor Authentication (2FA), centralized user management, Git hosting, and wiki collaboration.

## Overview

This project provides a complete, production-ready stack for small to medium organizations seeking self-hosted alternatives to cloud services. All components communicate through modern authentication standards (LDAP, OIDC, Forward-Auth) providing seamless single sign-on across all services.

### Components

- **[lldap](https://github.com/lldap/lldap)** - Lightweight LDAP directory for centralized user and group management
- **[Authelia](https://www.authelia.com/)** - SSO authentication server with 2FA/TOTP support, OIDC provider, and forward-auth endpoint
- **[Gitea](https://gitea.io/)** - Self-hosted Git service with web UI (authenticated via OIDC)
- **[JSPWiki](https://jspwiki.apache.org/)** - Collaborative wiki platform (authenticated via Forward-Auth)
- **[Caddy](https://caddyserver.com/)** - Reverse proxy with automatic HTTPS via Let's Encrypt

### Key Features

✅ **Single Sign-On (SSO)** - One set of credentials for all services
✅ **Two-Factor Authentication** - TOTP (Google Authenticator, Authy, etc.) support
✅ **Automatic HTTPS** - Let's Encrypt certificates managed by Caddy
✅ **File-Based Secrets** - Secure secret management following Docker best practices
✅ **One-Command Deployment** - Automated setup script handles everything
✅ **Zero Manual Configuration** - Template-based config generation from `.env`

## Quick Start

### Prerequisites

- **Remote Server**: Linux server with Docker and Docker Compose v2 installed
- **Local Machine**: SSH access to remote server, rsync installed
- **Domain**: Domain name with DNS pointing to your server (or `/etc/hosts` for testing)

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourorg/org-stack.git
   cd org-stack
   ```

2. **Configure environment**
   ```bash
   cp .env.example .env
   nano .env  # Edit BASE_DOMAIN, REMOTE_USER, REMOTE_HOST
   ```

   Required changes in `.env`:
   - `BASE_DOMAIN=example.com` → your actual domain
   - `REMOTE_USER=user` → your SSH username
   - `REMOTE_HOST=example.com` → your server hostname/IP

3. **Deploy**
   ```bash
   ./deploy.sh
   ```

   The deploy script will:
   - Generate all required secrets automatically
   - Create configuration files from templates
   - Sync files to your remote server via rsync
   - Start all Docker containers

4. **Access services**
   - **lldap**: https://ldap.yourdomain.com (create users here first)
   - **Authelia**: https://auth.yourdomain.com
   - **Gitea**: https://git.yourdomain.com
   - **Wiki**: https://wiki.yourdomain.com

### First-Time Setup

After deployment, complete these steps:

1. **Create users in lldap**
   - Access https://ldap.yourdomain.com
   - Login with admin credentials (shown by deploy.sh)
   - Create user accounts and assign to `lldap_admin` group for admin privileges

2. **Setup Gitea**
   - Access https://git.yourdomain.com
   - Complete the installation wizard (use defaults)
   - Go to Site Admin → Authentication Sources → Add Authentication Source
     - Type: `OAuth2`
     - Authentication Name: `authelia` ⚠️ **IMPORTANT: Must be lowercase!**
     - Provider: `OpenID Connect`
     - Client ID: `gitea`
     - Client Secret: (shown by deploy.sh)
     - OpenID Connect Auto Discovery URL: `http://authelia:9091/.well-known/openid-configuration`
   - Logout and test "Sign in with OpenID Connect"

3. **Test the wiki**
   - Access https://wiki.yourdomain.com
   - You'll be redirected to Authelia for login
   - After authentication, you'll have admin access if you're in the `lldap_admin` group

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Internet / Users                             │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                     ┌─────────▼──────────┐
                     │   Caddy (HTTPS)    │ ← Automatic Let's Encrypt
                     │  Reverse Proxy     │
                     └──────────┬──────────┘
                                │
            ┌───────────────────┼───────────────────┐
            │                   │                   │
    ┌───────▼────────┐  ┌──────▼────────┐  ┌──────▼────────┐
    │  Gitea (Git)   │  │ JSPWiki (Wiki)│  │  lldap (Admin)│
    │   via OIDC ────┼──┤ via Fwd-Auth ─┼──┤ via Fwd-Auth ─┼──┐
    └────────────────┘  └───────────────┘  └───────────────┘  │
                                                               │
                         ┌─────────────────────────────────────┘
                         │
                ┌────────▼─────────┐
                │     Authelia     │ ← SSO/2FA/OIDC/Forward-Auth
                │  (Auth Server)   │
                └────────┬──────────┘
                         │
                ┌────────▼─────────┐
                │      lldap       │ ← User Database (LDAP)
                └──────────────────┘
```

### Authentication Flow

**OIDC Flow (Gitea)**:
1. User accesses Gitea → redirected to Authelia
2. Authelia validates credentials against lldap via LDAP
3. Authelia enforces 2FA (TOTP)
4. Authelia issues OIDC tokens
5. User redirected back to Gitea, logged in

**Forward-Auth Flow (Wiki, lldap)**:
1. User accesses Wiki → Caddy forwards auth request to Authelia
2. Authelia validates session (or prompts login + 2FA)
3. Authelia returns `Remote-User` header
4. Caddy forwards request to Wiki with authenticated user header
5. Wiki trusts the `Remote-User` header (container authentication)

For detailed architecture documentation, see [ARCHITECTURE.md](./ARCHITECTURE.md).

## Configuration

All configuration is managed through a single `.env` file. The deployment script generates service-specific configs from templates.

### Key Configuration Options

```bash
# Domain Configuration
BASE_DOMAIN=example.com              # Your domain
GITEA_SUBDOMAIN=git                  # Creates git.example.com
WIKI_SUBDOMAIN=wiki                  # Creates wiki.example.com
AUTH_SUBDOMAIN=auth                  # Creates auth.example.com
LLDAP_SUBDOMAIN=ldap                 # Creates ldap.example.com

# TLS Mode
USE_SELF_SIGNED_CERTS=false          # false=Let's Encrypt, true=self-signed

# Authentication
REQUIRE_2FA=true                     # Require TOTP for all services

# Advanced
SESSION_EXPIRATION=1h                # How long sessions last
MAX_RETRIES=3                        # Failed login attempts before ban
```

See `.env.example` for complete documentation of all options.

## Management

The `manage.sh` script provides common operations:

```bash
# View logs
./manage.sh logs              # All services
./manage.sh logs authelia     # Specific service

# Restart services
./manage.sh restart

# Update to latest images
./manage.sh update

# Backup data volumes
./manage.sh backup

# Restore from backup
./manage.sh restore backup-YYYYMMDD-HHMMSS.tar.gz

# Complete reset (DESTRUCTIVE - deletes all data)
./manage.sh reset

# Check service status
./manage.sh status
```

## Security Features

### Secrets Management
All secrets are stored as individual files (not environment variables) following Docker security best practices:
- Mounted read-only to containers
- Not visible in `docker inspect` or process listings
- Individual file permissions (600)
- Never committed to git (secrets/ in .gitignore)

### Authentication Layers
1. **Centralized User Database**: Single source of truth in lldap
2. **SSO Authentication**: Authelia validates all login attempts
3. **Two-Factor Authentication**: TOTP enforcement for all services
4. **Session Management**: Configurable expiration and inactivity timeouts
5. **Rate Limiting**: Brute-force protection with automatic bans

### Network Security
- Internal Docker network isolates services
- Only Caddy exposes ports externally
- All inter-service communication via internal network
- Automatic HTTPS with modern TLS configuration

## Protocols & Technologies

This project demonstrates integration of several authentication protocols:

### LDAP (Lightweight Directory Access Protocol)
- **Implementation**: lldap
- **RFC**: [RFC 4511](https://tools.ietf.org/html/rfc4511)
- **Used for**: Centralized user/group storage, credential verification
- **Resources**:
  - [lldap GitHub](https://github.com/lldap/lldap)
  - [LDAP Wikipedia](https://en.wikipedia.org/wiki/Lightweight_Directory_Access_Protocol)

### OIDC (OpenID Connect)
- **Implementation**: Authelia (provider), Gitea (client)
- **Spec**: [OpenID Connect Core 1.0](https://openid.net/specs/openid-connect-core-1_0.html)
- **Used for**: Gitea SSO authentication
- **Resources**:
  - [OpenID Connect Explained](https://connect2id.com/learn/openid-connect)
  - [Authelia OIDC Docs](https://www.authelia.com/integration/openid-connect/introduction/)

### Forward-Auth
- **Implementation**: Authelia (endpoint), Caddy (proxy)
- **Pattern**: [Traefik Forward-Auth](https://doc.traefik.io/traefik/middlewares/http/forwardauth/)
- **Used for**: Wiki and lldap authentication via trusted headers
- **Resources**:
  - [Authelia Forward-Auth Docs](https://www.authelia.com/integration/proxies/fowarded-headers/)
  - [Caddy forward_auth Directive](https://caddyserver.com/docs/caddyfile/directives/forward_auth)

### TOTP (Time-Based One-Time Password)
- **Implementation**: Authelia, compatible with Google Authenticator/Authy
- **RFC**: [RFC 6238](https://tools.ietf.org/html/rfc6238)
- **Used for**: Two-factor authentication
- **Resources**:
  - [TOTP Wikipedia](https://en.wikipedia.org/wiki/Time-based_One-Time_Password)
  - [Authelia 2FA Docs](https://www.authelia.com/overview/authentication/one-time-password/)

## Troubleshooting

### Check notifications (2FA codes, password resets)
```bash
ssh user@server 'cd ~/org-stack && docker compose exec authelia cat /data/notification.txt'
```

Or use the manage script:
```bash
./manage.sh logs authelia | grep -A 20 "one-time code"
```

### Gitea OIDC not working

**Error: "invalid_request" or "redirect_uri does not match"**
- **Cause**: Authentication source name is case-sensitive
- **Solution**: Name must be exactly `authelia` (lowercase) in Gitea admin panel
- **Why**: Gitea uses the name in redirect URI: `/user/oauth2/{name}/callback`

**Other common issues:**
1. Verify OIDC configuration uses internal URL:
   - Auto Discovery URL: `http://authelia:9091/.well-known/openid-configuration` (NOT https://)
2. Check Authelia logs: `./manage.sh logs authelia`
3. Verify client secret matches what deploy.sh showed

### Services showing 502 errors
1. Check if all containers are running: `./manage.sh status`
2. Check Authelia logs: `./manage.sh logs authelia`
3. Verify secrets are mounted: `ssh user@server 'ls -la ~/org-stack/secrets/authelia'`

### 2FA not working
1. Verify `REQUIRE_2FA=true` in `.env`
2. Redeploy: `./deploy.sh`
3. Check Authelia configuration: `cat authelia/configuration.yml | grep policy`

### Let's Encrypt certificate failures
1. Verify DNS points to your server: `dig yourdomain.com`
2. Verify ports 80 and 443 are accessible externally
3. Check Caddy logs: `./manage.sh logs caddy`
4. If testing, use self-signed: `USE_SELF_SIGNED_CERTS=true` in `.env`

## Backup & Recovery

### Backup
```bash
./manage.sh backup
```

Creates timestamped tarball of all Docker volumes in `backups/` directory.

### Restore
```bash
./manage.sh restore backups/backup-YYYYMMDD-HHMMSS.tar.gz
```

### What's Backed Up
- lldap database (all users and groups)
- Authelia data (sessions, 2FA registrations)
- Gitea data (all repositories)
- JSPWiki data (all wiki pages)
- Caddy data (TLS certificates)

**Note**: The `secrets/` directory is NOT backed up by design. Back it up separately and securely.

## Development

### Testing Changes Locally
```bash
# Use self-signed certs to avoid Let's Encrypt rate limits
echo "USE_SELF_SIGNED_CERTS=true" >> .env

# For local testing without DNS, add to /etc/hosts:
echo "127.0.0.1 git.example.com wiki.example.com auth.example.com ldap.example.com" | sudo tee -a /etc/hosts

# Deploy
./deploy.sh
```

### Project Structure
```
org-stack/
├── .env.example                 # Configuration template
├── deploy.sh                    # Automated deployment script
├── manage.sh                    # Management utilities
├── compose.yml                  # Docker Compose service definitions
├── Caddyfile.*.template         # Caddy templates (prod/test)
├── authelia/
│   └── configuration.yml.template  # Authelia config template
├── jspwiki/
│   ├── Dockerfile               # Custom JSPWiki image
│   ├── RemoteUserFilter.java    # Servlet filter for SSO
│   ├── ldap-sync.sh             # LDAP user synchronization
│   ├── configure-web-xml.sh     # web.xml modification for container auth
│   └── entrypoint.sh            # Container startup script
├── jspwiki-custom.properties    # JSPWiki config (container auth)
├── jspwiki.policy               # JSPWiki security policy
└── secrets/                     # Auto-generated secrets (gitignored)
    ├── lldap/
    │   ├── JWT_SECRET
    │   └── LDAP_USER_PASS
    └── authelia/
        ├── JWT_SECRET
        ├── SESSION_SECRET
        ├── STORAGE_ENCRYPTION_KEY
        ├── OIDC_HMAC_SECRET
        └── OIDC_PRIVATE_KEY
```

## Production Recommendations

1. **DNS Configuration**: Ensure A records point to your server
2. **Firewall**: Open ports 80, 443, and optionally 2222 (Git SSH)
3. **Backups**: Schedule regular backups with `./manage.sh backup`
4. **Monitoring**: Set up monitoring for container health
5. **Updates**: Regularly update with `./manage.sh update`
6. **SMTP**: Configure email notifier in `authelia/configuration.yml.template` (replace filesystem notifier)
7. **Database**: Consider PostgreSQL instead of SQLite for Gitea in high-traffic scenarios

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request with clear description

## License

MIT License - see LICENSE file for details

## Acknowledgments

- **lldap**: Nitnelave and contributors
- **Authelia**: Authelia team
- **Gitea**: Gitea maintainers
- **JSPWiki**: Apache JSPWiki project
- **Caddy**: Caddy team

This project demonstrates integration of these excellent open-source tools into a cohesive authentication platform.

## Support

- **Issues**: [GitHub Issues](https://github.com/yourorg/org-stack/issues)
- **Discussions**: [GitHub Discussions](https://github.com/yourorg/org-stack/discussions)
- **Authelia Support**: [Authelia Discord](https://discord.authelia.com)
- **lldap Support**: [lldap Discussions](https://github.com/lldap/lldap/discussions)
