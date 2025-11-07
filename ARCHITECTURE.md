# Architecture Deep-Dive

This document provides a detailed technical explanation of how the Organization Stack components interact, including protocol details, authentication flows, and design decisions.

## Table of Contents

- [System Architecture](#system-architecture)
- [Authentication Protocols](#authentication-protocols)
  - [LDAP Integration](#ldap-integration)
  - [OIDC Flow](#oidc-flow)
  - [Forward-Auth Pattern](#forward-auth-pattern)
- [Component Details](#component-details)
- [Security Model](#security-model)
- [Network Architecture](#network-architecture)
- [Data Flow Examples](#data-flow-examples)
- [Design Decisions](#design-decisions)

## System Architecture

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                          Internet / Users                                              │
│                                                                                        │
│  https://git.example.com   https://wiki.example.com   https://register.example.com     │
└──────────────────────────────────┬─────────────────────────────────────────────────────┘
                                   │
                                   │ HTTPS (TLS 1.2+)
                                   ▼
                         ┌─────────────────────┐
                         │   Caddy             │
                         │   Reverse Proxy     │
                         │   - TLS Termination │
                         │   - Forward-Auth    │
                         │   - HTTP Routing    │
                         └──────────┬──────────┘
                                    │
          ┌─────────────────────────┼──────────────────────────┬──────────────────────┐
          │                         │                          │                      │
          │ OIDC                    │ Forward-Auth             │ Forward-Auth         │ Public + Forward-Auth
          ▼                         ▼                          ▼                      ▼
┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐    ┌─────────────────┐
│   Gitea         │       │   JSPWiki       │       │   lldap (Web)   │    │  Registration   │
│                 │       │                 │       │                 │    │                 │
│   Port: 3000    │       │   Port: 8080    │       │   Port: 17170   │    │   Port: 5000    │
│                 │       │                 │       │                 │    │                 │
│   Auth: OIDC    │       │ Auth: Remote-   │       │ Auth: Remote-   │    │ / - Public      │
│   (OAuth2)      │       │   User Header   │       │   User Header   │    │ /admin - Auth   │
└────────┬────────┘       └────────┬────────┘       └─────────────────┘    └────────┬────────┘
         │                         │                                                 │
         │ OIDC Protocol           │ LDAP Query                           GraphQL API│
         │                         │ (User Sync)                          (Create User)
         ▼                         ▼                                                 │
┌────────────────────────────────────────────┐                                      │
│          Authelia                          │                                      │
│                                            │                                      │
│  - OIDC Provider (/.well-known/...)        │                                      │
│  - Forward-Auth Endpoint (/api/authz/...)  │                                      │
│  - Session Management                      │                                      │
│  - 2FA/TOTP Validation                     │                                      │
│  - Access Control Policies                 │                                      │
│                                            │                                      │
│  Port: 9091                                │                                      │
└──────────────────┬─────────────────────────┘                                      │
                   │                                                                 │
                   │ LDAP Protocol                                                   │
                   │ (Credential Validation)                                         │
                   ▼                                                                 ▼
         ┌──────────────────────┐ ◄─────────────────────────────────────────────────┘
         │   lldap              │
         │                      │
         │   User Database      │
         │   - Users            │
         │   - Groups           │
         │   - Credentials      │
         │                      │
         │   LDAP: 3890         │
         │   HTTP: 17170        │
         └──────────────────────┘
```

## Authentication Protocols

### LDAP Integration

**What is LDAP?**

LDAP (Lightweight Directory Access Protocol) is a protocol for accessing and maintaining distributed directory information services. Think of it as a specialized database optimized for read-heavy operations on hierarchical data structures.

**How we use it:**

```
lldap Storage Structure:
dc=example,dc=com                    (Base DN)
├── ou=people                        (Users)
│   ├── uid=alice                    (User Entry)
│   │   ├── cn: Alice Smith
│   │   ├── mail: alice@example.com
│   │   ├── userPassword: {SSHA}...
│   │   └── objectClass: person
│   └── uid=bob
│       ├── cn: Bob Jones
│       └── ...
└── ou=groups                        (Groups)
    └── cn=lldap_admin               (Admin Group)
        ├── member: uid=alice,ou=people,dc=example,dc=com
        └── objectClass: groupOfUniqueNames
```

**Authentication Flow:**

1. Authelia connects to lldap using bind credentials:
   ```
   BIND uid=admin,ou=people,dc=example,dc=com
   PASSWORD: <from secrets/lldap/LDAP_USER_PASS>
   ```

2. User attempts login with username "alice"

3. Authelia performs LDAP search:
   ```ldap
   SEARCH base_dn: ou=people,dc=example,dc=com
   FILTER: (&(uid=alice)(objectClass=person))
   ```

4. Authelia validates password by attempting bind as user:
   ```
   BIND uid=alice,ou=people,dc=example,dc=com
   PASSWORD: <user's password>
   ```

5. If successful, Authelia queries groups:
   ```ldap
   SEARCH base_dn: ou=groups,dc=example,dc=com
   FILTER: (member=uid=alice,ou=people,dc=example,dc=com)
   ```

**References:**
- [RFC 4511 - LDAP Protocol](https://tools.ietf.org/html/rfc4511)
- [lldap Documentation](https://github.com/lldap/lldap)

### OIDC Flow

**What is OpenID Connect?**

OIDC is an identity layer built on top of OAuth 2.0. It allows clients to verify user identity and obtain basic profile information in an interoperable REST-like manner.

**Components:**
- **Provider (OP)**: Authelia - issues tokens, manages authentication
- **Relying Party (RP)**: Gitea - trusts tokens from provider

**Authorization Code Flow (Detailed):**

```
User                    Gitea                   Authelia                lldap
 │                       │                         │                      │
 │ 1. GET /login         │                         │                      │
 ├──────────────────────►│                         │                      │
 │                       │                         │                      │
 │                       │ 2. Redirect to Authelia │                      │
 │                       │    /authorize?          │                      │
 │                       │    client_id=gitea      │                      │
 │                       │    &redirect_uri=...    │                      │
 │                       │    &scope=openid...     │                      │
 │◄──────────────────────┤                         │                      │
 │                       │                         │                      │
 │ 3. GET /authorize     │                         │                      │
 ├───────────────────────┴─────────────────────────►                      │
 │                                                 │                      │
 │ 4. Login form (if not authenticated)            │                      │
 │◄────────────────────────────────────────────────┤                      │
 │                                                 │                      │
 │ 5. POST credentials                             │                      │
 ├─────────────────────────────────────────────────►                      │
 │                                                 │                      │
 │                                                 │ 6. Validate password │
 │                                                 ├─────────────────────►│
 │                                                 │    LDAP BIND         │
 │                                                 │◄─────────────────────┤
 │                                                 │    SUCCESS           │
 │                                                 │                      │
 │ 7. TOTP prompt (if 2FA enabled)                 │                      │
 │◄────────────────────────────────────────────────┤                      │
 │                                                 │                      │
 │ 8. POST TOTP code                               │                      │
 ├─────────────────────────────────────────────────►                      │
 │                                                 │                      │
 │ 9. Redirect to Gitea with code                  │                      │
 │    /callback?code=abc123                        │                      │
 │◄────────────────────────────────────────────────┤                      │
 │                       │                         │                      │
 │ 10. GET /callback?    │                         │                      │
 │     code=abc123       │                         │                      │
 ├──────────────────────►│                         │                      │
 │                       │                         │                      │
 │                       │ 11. POST /token         │                      │
 │                       │     code=abc123         │                      │
 │                       │     client_secret=...   │                      │
 │                       ├─────────────────────────►                      │
 │                       │                         │                      │
 │                       │ 12. Access token +      │                      │
 │                       │     ID token            │                      │
 │                       │◄────────────────────────┤                      │
 │                       │                         │                      │
 │                       │ 13. GET /userinfo       │                      │
 │                       ├─────────────────────────►                      │
 │                       │                         │                      │
 │                       │ 14. User profile        │                      │
 │                       │◄────────────────────────┤                      │
 │                       │                         │                      │
 │ 15. Logged in         │                         │                      │
 │◄──────────────────────┤                         │                      │
```

**Key Endpoints:**

Authelia provides these OIDC endpoints:
- `/.well-known/openid-configuration` - Discovery document
- `/api/oidc/authorization` - Authorization endpoint
- `/api/oidc/token` - Token endpoint
- `/api/oidc/userinfo` - User info endpoint
- `/api/oidc/jwks` - Public keys for token verification

**Token Format (JWT):**

```json
{
  "header": {
    "alg": "RS256",
    "kid": "key-id"
  },
  "payload": {
    "iss": "https://auth.example.com",
    "sub": "alice",
    "aud": "gitea",
    "exp": 1234567890,
    "iat": 1234564290,
    "email": "alice@example.com",
    "preferred_username": "alice",
    "groups": ["lldap_admin"]
  },
  "signature": "..."
}
```

**References:**
- [OpenID Connect Core 1.0](https://openid.net/specs/openid-connect-core-1_0.html)
- [OAuth 2.0 Authorization Code Flow](https://tools.ietf.org/html/rfc6749#section-4.1)
- [Authelia OIDC Documentation](https://www.authelia.com/integration/openid-connect/introduction/)

### Forward-Auth Pattern

**What is Forward-Auth?**

Forward-Auth is a proxy-level authentication pattern where a reverse proxy delegates authentication decisions to an external service before forwarding requests to backends.

**How it works:**

```
User                 Caddy                  Authelia               JSPWiki
 │                     │                        │                      │
 │ 1. GET /wiki/Main   │                        │                      │
 ├────────────────────►│                        │                      │
 │                     │                        │                      │
 │                     │ 2. Sub-request to      │                      │
 │                     │    /api/authz/         │                      │
 │                     │    forward-auth        │                      │
 │                     ├────────────────────────►                      │
 │                     │    (with all cookies)  │                      │
 │                     │                        │                      │
 │                     │ 3a. If NOT authenticated                      │
 │                     │     401 + redirect URL │                      │
 │                     │◄───────────────────────┤                      │
 │                     │                        │                      │
 │ 4. Redirect to      │                        │                      │
 │    Authelia login   │                        │                      │
 │◄────────────────────┤                        │                      │
 │                     │                        │                      │
 │ [User logs in with  │                        │                      │
 │  credentials + 2FA] │                        │                      │
 │                     │                        │                      │
 │ 5. Redirect back    │                        │                      │
 │    to /wiki/Main    │                        │                      │
 ├────────────────────►│                        │                      │
 │                     │                        │                      │
 │                     │ 6. Sub-request to      │                      │
 │                     │    /api/authz/         │                      │
 │                     │    forward-auth        │                      │
 │                     ├────────────────────────►                      │
 │                     │    (with session       │                      │
 │                     │     cookie)            │                      │
 │                     │                        │                      │
 │                     │ 7. 200 OK +            │                      │
 │                     │    Remote-User: alice  │                      │
 │                     │    Remote-Groups: ...  │                      │
 │                     │◄───────────────────────┤                      │
 │                     │                        │                      │
 │                     │ 8. Forward to JSPWiki  │                      │
 │                     │    with Remote-User    │                      │
 │                     │    header              │                      │
 │                     ├──────────────────────────────────────────────►│
 │                     │                        │                      │
 │                     │ 9. Response            │                      │
 │                     │◄──────────────────────────────────────────────┤
 │                     │                        │                      │
 │ 10. Page delivered  │                        │                      │
 │◄────────────────────┤                        │                      │
```

**Caddyfile Configuration:**

```caddyfile
# Reusable forward-auth snippet
(auth) {
    forward_auth authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
    }
}

# Wiki with authentication
wiki.example.com {
    import auth
    reverse_proxy jspwiki:8080
}
```

**Headers Passed:**

When authentication succeeds, Authelia returns these headers:
- `Remote-User`: Username (e.g., "alice")
- `Remote-Groups`: Comma-separated groups (e.g., "lldap_admin,developers")
- `Remote-Email`: User's email
- `Remote-Name`: Display name

**JSPWiki Container Authentication:**

JSPWiki is configured to trust the `Remote-User` header via our custom `RemoteUserFilter`:

```java
// RemoteUserFilter.java
public class RemoteUserFilter implements Filter {
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain) {
        HttpServletRequest httpRequest = (HttpServletRequest) request;
        String remoteUser = httpRequest.getHeader("Remote-User");

        if (remoteUser != null && !remoteUser.isEmpty()) {
            // Wrap request to return Remote-User as getRemoteUser()
            HttpServletRequestWrapper wrapper = new HttpServletRequestWrapper(httpRequest) {
                @Override
                public String getRemoteUser() {
                    return remoteUser;
                }
                @Override
                public Principal getUserPrincipal() {
                    return new Principal() {
                        public String getName() { return remoteUser; }
                    };
                }
            };
            chain.doFilter(wrapper, response);
        } else {
            chain.doFilter(request, response);
        }
    }
}
```

**Security Considerations:**

⚠️ **Critical**: The backend MUST NOT be accessible except through the proxy. If an attacker can reach JSPWiki directly, they can forge the `Remote-User` header.

Our setup ensures this by:
1. All services on internal Docker network
2. Only Caddy exposes external ports
3. JSPWiki port 8080 not exposed to host

**References:**
- [Authelia Forward-Auth Docs](https://www.authelia.com/integration/proxies/fowarded-headers/)
- [Caddy forward_auth](https://caddyserver.com/docs/caddyfile/directives/forward_auth)

## Component Details

### lldap - LDAP Directory

**Purpose**: Central user and group database

**Why LDAP?**
- Industry standard protocol
- Supported by virtually all enterprise software
- Hierarchical data model perfect for organizational structure
- Read-optimized for authentication use cases

**Why lldap specifically?**
- Lightweight alternative to heavyweight solutions (OpenLDAP, Active Directory)
- Simple web UI for user management
- SQLite backend (no PostgreSQL/MySQL dependency)
- Built in Rust for memory safety

**Schema:**
```
objectClass: person
├── uid (username)
├── cn (common name / display name)
├── mail (email address)
├── userPassword (hashed password)
└── ... (standard LDAP attributes)

objectClass: groupOfUniqueNames
├── cn (group name)
└── member (DN of member users)
```

**Ports:**
- 3890: LDAP protocol
- 17170: Web admin interface

### Authelia - SSO Server

**Purpose**: Central authentication authority, session management, 2FA enforcement

**Why Authelia?**
- Supports multiple auth methods (LDAP, file, etc.)
- Built-in TOTP/2FA support
- Both OIDC provider AND forward-auth endpoint
- Flexible access control policies
- Session management with Redis or SQLite

**Key Features:**
1. **Multi-factor Authentication**: TOTP (RFC 6238), WebAuthn planned
2. **Single Sign-On**: One login session across all services
3. **Access Control**: Domain-based policies (bypass, one_factor, two_factor)
4. **Session Management**: Configurable lifespans, remember-me
5. **Rate Limiting**: Brute-force protection

**Configuration Structure:**
```yaml
authentication_backend:   # How to validate credentials
  ldap:                   # Use LDAP (lldap)
    address: ldap://lldap:3890
    base_dn: dc=example,dc=com

access_control:           # Who can access what
  default_policy: deny    # Deny by default
  rules:                  # Explicit allow rules
    - domain: wiki.example.com
      policy: two_factor  # Require 2FA

identity_providers:       # What protocols to provide
  oidc:                   # OIDC provider config
    clients:
      - client_id: gitea
        authorization_policy: two_factor
```

**Storage:**
- SQLite database in `/data/db.sqlite3`
- Contains: sessions, 2FA registrations, access logs

### Gitea - Git Hosting

**Purpose**: Self-hosted Git repository platform

**Authentication Method**: OIDC (OAuth 2.0 + OpenID Connect)

**Why OIDC for Gitea?**
- Gitea has native OIDC support
- Allows full SSO experience (no double-login)
- Automatic user provisioning from OIDC claims
- Group synchronization via OIDC groups claim

**Configuration:**
```ini
[auth]
ENABLE_OAUTH2 = true

[openid]
ENABLE_OPENID_SIGNIN = true
ENABLE_OPENID_SIGNUP = true
```

Configured via web UI to use Authelia as OIDC provider.

⚠️ **Important**: The authentication source name in Gitea must be exactly `authelia` (lowercase). Gitea constructs the redirect URI using this name: `/user/oauth2/{name}/callback`. Since OAuth2 redirect URIs are case-sensitive, using "Authelia" (capital A) will cause authentication to fail with an `invalid_request` error.

### JSPWiki - Wiki Platform

**Purpose**: Collaborative wiki and knowledge base

**Authentication Method**: Container authentication via forward-auth

**Why not OIDC for JSPWiki?**
JSPWiki doesn't natively support OIDC, but it does support "container authentication" (trusting the servlet container's authentication).

**Our Solution:**
1. Caddy enforces authentication via forward-auth
2. Caddy passes `Remote-User` header
3. Our custom `RemoteUserFilter` servlet filter wraps the request
4. JSPWiki sees an authenticated user via standard servlet APIs (`request.getRemoteUser()`)

**LDAP Synchronization:**

JSPWiki needs users in its own XML databases for permissions. Our `ldap-sync.sh` script:
1. Queries lldap via `ldapsearch`
2. Generates `userdatabase.xml` with all LDAP users
3. Maps `lldap_admin` group to JSPWiki's `Admin` group
4. Runs on container startup

**Files:**
- `/var/jspwiki/pages/` - Wiki pages (markdown)
- `/var/jspwiki/etc/userdatabase.xml` - User database (synced from LDAP)
- `/var/jspwiki/etc/groupdatabase.xml` - Group mappings

### Registration Service - User Self-Provisioning

**Purpose**: Allow users to request accounts without admin intervention in lldap

**Architecture**: FastAPI + SQLite + lldap GraphQL API

**Why a separate service?**
- lldap doesn't have built-in self-registration
- Maintains audit trail of registration requests
- Allows admin approval workflow
- Generates secure random passwords automatically

**Authentication Methods**:
1. **Public Route** (`/`) - Registration form (no auth required)
2. **Protected Route** (`/admin`) - Admin dashboard (forward-auth via Authelia)

**Workflow:**

```
┌─────────────┐
│   User      │
│   (Public)  │
└──────┬──────┘
       │
       │ 1. Fill registration form
       │    (username, email, name, reason)
       ▼
┌────────────────────┐
│  Registration      │
│  Service           │
│  (FastAPI)         │
└─────┬──────────────┘
      │
      │ 2. Store in SQLite
      │    status='pending'
      │
      │ 3. Notify admin (email)
      │
      ▼
┌────────────────────┐
│   Admin            │
│   (Authenticated)  │
└─────┬──────────────┘
      │
      │ 4. Review at /admin
      │    (protected by Authelia)
      │
      │ 5. Approve or Reject
      │
      ▼
┌────────────────────┐
│  Registration      │
│  Service           │
│  (GraphQL Client)  │
└─────┬──────────────┘
      │
      │ 6. If approved:
      │    - Generate random password
      │    - Create user via GraphQL
      │
      ▼
┌────────────────────┐
│   lldap            │
│   (GraphQL API)    │
└─────┬──────────────┘
      │
      │ 7. User created
      │
      ▼
┌────────────────────┐
│   User             │
│   (Email)          │
└────────────────────┘
      8. Receive credentials
         via email
```

**Database Schema:**

```sql
CREATE TABLE registration_requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    email TEXT NOT NULL,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    reason TEXT,
    status TEXT DEFAULT 'pending',        -- pending, approved, rejected
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    reviewed_at TIMESTAMP,
    reviewed_by TEXT,                     -- from Remote-User header
    rejection_reason TEXT,
    ip_address TEXT,
    user_agent TEXT
);

CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id INTEGER,
    action TEXT NOT NULL,                 -- CREATED, APPROVED, REJECTED, APPROVE_FAILED
    performed_by TEXT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    details TEXT,
    FOREIGN KEY (request_id) REFERENCES registration_requests(id)
);
```

**lldap GraphQL Integration:**

The service authenticates to lldap's GraphQL API using the admin credentials from `/secrets-lldap/LDAP_USER_PASS`:

```python
# 1. Login to get JWT token
POST http://lldap:17170/auth/simple/login
Body: {"username": "admin", "password": "..."}
Response: {"token": "eyJhbGciOi..."}

# 2. Create user via GraphQL
POST http://lldap:17170/api/graphql
Headers: Authorization: Bearer eyJhbGciOi...
Body: {
  "query": "mutation CreateUser($user: CreateUserInput!) { ... }",
  "variables": {
    "user": {
      "id": "newuser",
      "email": "user@example.com",
      "displayName": "New User",
      "firstName": "New",
      "lastName": "User"
    }
  }
}

# 3. Set password
POST http://lldap:17170/api/graphql
Body: {
  "query": "mutation UpdatePassword($userId: String!, $password: String!) { ... }",
  "variables": {
    "userId": "newuser",
    "password": "random-generated-password"
  }
}
```

**Configuration** (`.env`):
- `REGISTRATION_SUBDOMAIN=register` - Subdomain for registration service
- `REGISTRATION_ADMIN_EMAIL` - Email for admin notifications (optional)
- `SMTP_ENABLED=false` - Enable SMTP for email notifications (future feature)

**Security Considerations:**
- Public form validates input (alphanumeric usernames, valid emails)
- Rate limiting via Caddy (not yet implemented - recommended for production)
- Admin dashboard protected by Authelia forward-auth
- lldap admin credentials read from file-based secrets (read-only mount)
- Audit trail tracks all actions with timestamps and actors
- Random password generation uses Python `secrets` module (cryptographically secure)

**Storage:**
- SQLite database: `/data/registrations.db`
- Backed up with Docker volume `registration_data`

**Port:** 5000 (internal, not exposed - accessed via Caddy)

#### LDAP Coherence Strategy

**The Problem:**

The registration service maintains a record of approved users in its SQLite database, but these users are also stored in lldap. If an admin deletes a user directly from lldap (via the lldap web UI or ldapdelete command), the registration service's database becomes inconsistent with reality:

```
Registration DB: user 'bob' - status='approved'
lldap Reality:   user 'bob' - does not exist ❌
```

This creates a coherence problem: Should the registration service automatically recreate deleted users? Automatically update its database? Or require manual intervention?

**Design Decision: Manual Reconciliation with Visual Feedback**

We chose a **manual reconciliation** approach rather than automatic synchronization:

**Rationale:**
1. **Visibility**: Admins can see when users have been deleted from lldap via status badges
2. **Control**: Admins explicitly choose whether to recreate deleted users or leave them deleted
3. **Audit Trail**: All actions are logged, showing who made what decision
4. **Safety**: Prevents automated recreation of intentionally deleted users
5. **Simplicity**: No background sync jobs, no conflict resolution logic

**Trade-offs:**
- ✅ Clear admin intent (explicit action required)
- ✅ No hidden automation bugs
- ✅ Simple implementation and testing
- ❌ Requires admin awareness (must check dashboard)
- ❌ Not real-time (status checked on page load)

**Implementation:**

The admin dashboard checks LDAP existence for each approved user on every page load:

```python
# Check lldap existence for approved users
for user in approved:
    user_dict['exists_in_lldap'] = check_user_exists_in_lldap(user['username'])
```

**Visual Feedback:**
- ✅ **Active badge**: User exists in lldap (green)
- ❌ **Deleted from LDAP badge**: User missing from lldap (red)

**Smart Button Logic:**

The UI adapts based on LDAP status:

| User Status | LDAP Status | Button Shown | Action |
|-------------|-------------|--------------|---------|
| Approved | Exists | "Reject" | Delete from LDAP + move to rejected |
| Approved | Missing | "Approve" | Recreate in LDAP with new password |
| Rejected | - | "Approve" | Create in LDAP + move to approved |

**Endpoint Consolidation:**

The `/admin/re-approve/{request_id}` endpoint handles both scenarios intelligently:

```python
@app.post('/admin/re-approve/{request_id}')
async def re_approve_request(request_id: int, request: Request):
    """Re-approve rejected user or recreate deleted approved user in lldap"""

    # Works for both rejected users and approved users deleted from LDAP
    if req['status'] not in ('rejected', 'approved'):
        return RedirectResponse(url='/admin', status_code=303)

    # Skip if user already exists in LDAP
    if check_user_exists_in_lldap(req['username']):
        return RedirectResponse(url='/admin', status_code=303)

    # Create user in lldap with new generated password
    success, password, error = await create_lldap_user(...)

    if success:
        if req['status'] == 'rejected':
            # Update database: rejected → approved
            db.execute('UPDATE registration_requests SET status = "approved" ...')
            log_audit(request_id, 'RE_APPROVED', admin_user, ...)
        else:
            # Already approved, just recreating in LDAP (status stays 'approved')
            log_audit(request_id, 'RECREATED_IN_LDAP', admin_user, ...)

        # Notify user with new password
        notify_user_approved(req['email'], req['username'], password)
```

**Key Implementation Details:**

1. **LDAP Existence Check**: Uses `ldapsearch` to query lldap for each user
2. **Password Generation**: Always generates a new 20-character random password on recreation
3. **Audit Logging**: Different audit log entries for RE_APPROVED vs RECREATED_IN_LDAP
4. **Email Notification**: User receives new credentials when recreated
5. **Idempotency**: Recreating an existing user is a no-op (safe button mashing)

**Performance Consideration:**

The LDAP existence check runs for every approved user on every admin dashboard page load. For large user counts (100+ approved users), consider:
- Caching LDAP status with TTL (e.g., 60 seconds)
- Pagination of approved users (already limited to 20 via `LIMIT 20`)
- Background job to update status asynchronously

For deployments with <100 users, the current implementation is performant and simple.

**Alternative Approaches Considered:**

1. **Automatic Recreation**: Background job recreates deleted users
   - ❌ Defeats purpose of deletion (user deleted for a reason)
   - ❌ Hidden automation, harder to debug

2. **Automatic Status Update**: Mark approved users as "deleted" in registration DB
   - ❌ Loses approval history
   - ❌ Requires new status value, complicates state machine

3. **Soft Delete in lldap**: Flag users as deleted instead of removing
   - ❌ Requires lldap schema changes
   - ❌ Not under our control (lldap is upstream project)

4. **Real-time Webhook**: lldap notifies registration service on user deletion
   - ❌ lldap doesn't support webhooks
   - ❌ Added complexity (webhook listener, retry logic)

**Recommended Workflow:**

For admins using this system:

1. **Regular Review**: Check admin dashboard periodically for "Deleted from LDAP" badges
2. **Intentional Deletion**: When deleting users from lldap, move them to "rejected" in registration service first
3. **Accidental Deletion**: If user accidentally deleted, click "Approve" to recreate with new password
4. **User Communication**: Always notify users when their account is deleted or recreated

**Future Enhancements:**

If automatic synchronization becomes necessary:
- Add cron job that runs nightly: compare approved users with lldap
- Send email digest to admins listing discrepancies
- Optionally: auto-archive approved users missing from lldap (status → 'archived')

### Caddy - Reverse Proxy

**Purpose**: TLS termination, routing, authentication enforcement

**Why Caddy?**
- Automatic HTTPS via Let's Encrypt (or self-signed for testing)
- Simple configuration
- Built-in `forward_auth` directive
- HTTP/2 and HTTP/3 support
- Zero-downtime config reloads

**Key Functions:**
1. **TLS Termination**: Handles HTTPS, obtains/renews certificates
2. **Routing**: Routes requests to correct backend service
3. **Auth Enforcement**: Forward-auth for wiki and lldap
4. **Header Injection**: Adds `Remote-User` to backend requests

**Snippet Pattern:**

We use Caddy's snippet feature for DRY configuration:
```caddyfile
(auth) {
    forward_auth authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
    }
}

wiki.example.com {
    import auth              # Reuse auth snippet
    reverse_proxy jspwiki:8080
}
```

## Security Model

### Defense in Depth

**Layer 1: Network Isolation**
- All services on internal Docker network (`org-network`)
- Only Caddy exposes ports externally
- Services communicate via service names (Docker DNS)

**Layer 2: Reverse Proxy**
- All external traffic through Caddy
- TLS 1.2+ only
- HTTPS redirect (except ACME challenges)

**Layer 3: Authentication (Authelia)**
- Centralized authentication
- LDAP credential validation
- Session management
- Failed attempt tracking

**Layer 4: Authorization (Authelia)**
- Domain-based access policies
- Group-based permissions
- Admin-only access controls

**Layer 5: Multi-Factor Authentication**
- TOTP (Time-based One-Time Password)
- Per-user 2FA registration
- Enforced by policy

**Layer 6: Application-Level Security**
- Gitea: OIDC token validation
- JSPWiki: User/group permissions
- lldap: Admin-only management UI

### Secret Management

**File-Based Secrets (Docker Best Practice):**

Instead of environment variables, we use Docker secret files:

```yaml
# compose.yml
authelia:
  environment:
    - AUTHELIA_SESSION_SECRET_FILE=/secrets/SESSION_SECRET
  volumes:
    - ./secrets/authelia:/secrets:ro  # Read-only mount
```

**Benefits:**
- Not visible in `docker inspect`
- Not visible in process listing (`ps aux`)
- Individual file permissions (600)
- Easier to rotate (replace file, restart container)
- Not logged accidentally

**Secret Types:**
- **Symmetric Keys**: SESSION_SECRET, STORAGE_ENCRYPTION_KEY (AES-256)
- **HMAC Keys**: OIDC_HMAC_SECRET, JWT_SECRET (SHA-256)
- **Asymmetric Keys**: OIDC_PRIVATE_KEY (RSA-2048)
- **Passwords**: LDAP_USER_PASS (bcrypt/SSHA)

**Generation:**
```bash
# Strong random secrets
openssl rand -hex 32

# RSA key pair
authelia crypto pair rsa generate --bits 2048
```

### Session Security

**Session Lifecycle:**
1. User authenticates → Authelia creates session
2. Session stored in SQLite with unique ID
3. Cookie sent to user: `authelia_session=<id>`
4. Cookie attributes:
   - `HttpOnly`: Not accessible via JavaScript
   - `Secure`: Only sent over HTTPS
   - `SameSite=Lax`: CSRF protection
   - `Domain=.example.com`: Shared across subdomains

**Session Expiration:**
- `SESSION_EXPIRATION`: Absolute lifetime (e.g., 1h)
- `SESSION_INACTIVITY`: Idle timeout (e.g., 5m)
- `SESSION_REMEMBER_ME`: Extended lifetime if opted in (e.g., 1M)

**Session Invalidation:**
- Logout: Immediate deletion
- Password change: All sessions invalidated
- Inactivity timeout: Automatic cleanup

## Network Architecture

**Docker Network Topology:**

```
External Internet
       │
       │ :80, :443
       ▼
 ┌───────────┐
 │   Caddy   │ (ports published)
 └─────┬─────┘
       │ org-network (172.x.0.0/16)
       │
       ├─────► lldap:17170 (web UI)
       ├─────► lldap:3890 (LDAP)
       ├─────► authelia:9091
       ├─────► gitea:3000
       └─────► jspwiki:8080
```

**Service Discovery:**

Docker's internal DNS resolves service names:
- `lldap` → container IP (e.g., 172.19.0.2)
- `authelia` → container IP (e.g., 172.19.0.3)
- etc.

**Why this matters:**
- Services use service names in config (e.g., `ldap://lldap:3890`)
- Works in any environment (local, cloud, etc.)
- No hardcoded IPs
- Automatic failover if container restarts

## Data Flow Examples

### Example 1: First-Time Login to Wiki

```
1. User: Navigate to https://wiki.example.com
2. Browser → Caddy: GET /
3. Caddy → Authelia: Forward-auth subrequest
4. Authelia: No session cookie → 401 Unauthorized
5. Caddy → Browser: 302 Redirect to https://auth.example.com?rd=...
6. Browser → Authelia: GET /login?rd=...
7. Authelia → Browser: Login form
8. User: Enter username + password
9. Browser → Authelia: POST /login (credentials)
10. Authelia → lldap: LDAP BIND (validate password)
11. lldap → Authelia: BIND successful
12. Authelia → Browser: TOTP form (2FA)
13. User: Enter TOTP code from authenticator app
14. Browser → Authelia: POST /2fa (TOTP code)
15. Authelia: Validate TOTP, create session
16. Authelia → Browser: 302 Redirect to wiki + session cookie
17. Browser → Caddy: GET / (with session cookie)
18. Caddy → Authelia: Forward-auth subrequest (with cookie)
19. Authelia: Validate session → 200 OK + Remote-User: alice
20. Caddy → JSPWiki: GET / (with Remote-User header)
21. JSPWiki: Trust Remote-User, render page as alice
22. JSPWiki → Caddy: HTML response
23. Caddy → Browser: HTML response
24. User: Sees wiki page, logged in as alice
```

### Example 2: Gitea SSO via OIDC

```
1. User: Click "Sign in with OpenID Connect" on Gitea
2. Gitea → Browser: Redirect to Authelia authorize endpoint
3. Browser → Authelia: GET /api/oidc/authorization?client_id=gitea&...
4. Authelia: Check session → Valid (from wiki login earlier)
5. Authelia: Check consent → Not required (trusted client)
6. Authelia → Browser: Redirect to Gitea callback with code
7. Browser → Gitea: GET /callback?code=abc123
8. Gitea → Authelia: POST /api/oidc/token (exchange code for tokens)
9. Authelia: Validate code, issue access_token + id_token
10. Authelia → Gitea: Tokens (JWT)
11. Gitea: Decode id_token, extract user info
12. Gitea: Create/update user account for alice
13. Gitea: Create Gitea session
14. Gitea → Browser: Set Gitea session cookie, redirect to dashboard
15. User: Logged into Gitea without entering credentials again (SSO!)
```

## Design Decisions

### Why File-Based Secrets?

**Decision**: Use individual files for secrets instead of environment variables.

**Rationale:**
- **Security**: Not visible in `docker inspect` or process listing
- **Auditability**: File permissions and access can be monitored
- **Rotation**: Easy to update (replace file + restart)
- **Best Practice**: Recommended by Docker, Kubernetes

**Trade-off**: Slightly more complex volume mounts, but worth it for security.

### Why Both OIDC and Forward-Auth?

**Decision**: Use OIDC for Gitea, forward-auth for JSPWiki/lldap.

**Rationale:**
- **Native Support**: Gitea has excellent OIDC support, provides better UX
- **SSO Experience**: OIDC gives true SSO, no credential re-entry
- **Compatibility**: JSPWiki doesn't support OIDC, forward-auth is universal
- **Flexibility**: Demonstrates both patterns for learning purposes

**Trade-off**: Two authentication flows to understand, but appropriate for each service.

### Why JSPWiki LDAP Sync?

**Decision**: Synchronize LDAP users to JSPWiki's XML database on startup.

**Rationale:**
- **Permission Model**: JSPWiki's permission system needs users in its database
- **Group Mapping**: Allows mapping LDAP groups to JSPWiki roles
- **Offline Operation**: JSPWiki can function if LDAP is temporarily down

**Trade-off**: Users must be synced before they can access wiki, but this happens automatically on container start.

### Why SQLite for Production?

**Decision**: Use SQLite for Gitea and Authelia databases (optional PostgreSQL upgrade path).

**Rationale:**
- **Simplicity**: No external database to manage
- **Sufficient for Small Orgs**: Handles thousands of users easily
- **Backup Simplicity**: Single file to backup
- **Zero Config**: Works out of the box

**Trade-off**:
- For large installations (>10k repos, >100 concurrent users), PostgreSQL recommended
- Easy migration path available if needed

### Why Automatic LDAP_BASE_DN Derivation?

**Decision**: Auto-generate `dc=example,dc=com` from `BASE_DOMAIN=example.com`.

**Rationale:**
- **DRY**: Don't repeat yourself - one config value
- **Fewer Errors**: Less to configure = fewer mistakes
- **Convention**: Standard LDAP DN format from domain

**Trade-off**: Less flexibility if you need non-standard DN, but can override with manual setting.

## Performance Considerations

### Bottlenecks

1. **Authelia LDAP Lookups**: Each login queries LDAP
   - *Mitigation*: Authelia caches results per session
   - *Scale*: LDAP is read-optimized, handles thousands of auth/sec

2. **OIDC Token Validation**: Gitea validates tokens on each request
   - *Mitigation*: JWTs are stateless, validation is local
   - *Scale*: CPU-bound, scales horizontally

3. **SQLite Lock Contention**: Multiple writers can cause locking
   - *Mitigation*: WAL mode enabled by default
   - *Scale*: If bottleneck appears, migrate to PostgreSQL

### Optimization Recommendations

**For Heavy Load:**
1. Deploy Redis for Authelia session storage (instead of SQLite)
2. Use PostgreSQL for Gitea database
3. Enable HTTP/3 (QUIC) in Caddy
4. Increase Authelia session cache size
5. Deploy multiple Authelia instances behind load balancer

**For Low Latency:**
1. Enable HTTP/2 server push in Caddy
2. Tune session expiration for use case
3. Use CDN for static assets (Gitea avatars, etc.)

## Monitoring and Observability

**Logs:**
All containers log to stdout/stderr, accessible via:
```bash
docker compose logs -f [service]
```

**Metrics:**
- Authelia exposes Prometheus metrics on `/metrics`
- Caddy exposes metrics via admin API
- Gitea has built-in metrics endpoint

**Recommended Monitoring:**
1. Container health checks (Authelia provides `/api/health`)
2. Certificate expiration monitoring (Caddy auto-renews, but monitor anyway)
3. Failed login attempts (Authelia logs)
4. Session counts (Authelia database)
5. Repository count/size (Gitea admin panel)

## Disaster Recovery

**Backup Strategy:**

**Critical Data:**
1. `lldap_data` - User database (highest priority)
2. `gitea_data` - All repositories
3. `jspwiki_data` - Wiki content
4. `authelia_data` - Sessions, 2FA registrations
5. `caddy_data` - TLS certificates
6. `secrets/` directory - All secrets

**Recovery Procedure:**
1. Restore `secrets/` directory
2. Restore Docker volumes from backup
3. Deploy stack: `./deploy.sh`
4. Verify all services start
5. Test authentication flow

**RPO (Recovery Point Objective)**: How much data loss is acceptable?
- Recommended: Daily backups of volumes
- Critical orgs: Hourly backups + off-site replication

**RTO (Recovery Time Objective)**: How quickly to recover?
- With backups: ~15 minutes
- From scratch (users recreate accounts): Several hours

## Conclusion

This architecture demonstrates modern authentication and authorization patterns using open-source components. The system is designed for:
- **Security**: Defense in depth, modern protocols
- **Usability**: Single sign-on, familiar UX
- **Maintainability**: Simple deployment, clear structure
- **Scalability**: Can grow from 10 to 10,000 users with appropriate tuning

For questions or improvements, see the main [README.md](./README.md) or open an issue on GitHub.
