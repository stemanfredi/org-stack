# Gitea SSO Setup Guide

This guide explains how to set up Single Sign-On (SSO) for Gitea using Authelia OIDC.

## Why Auto-Registration is Disabled

Gitea's OIDC auto-registration requires claims that Authelia doesn't provide by default (`nickname`). Instead, we use **account linking** with pre-created accounts, which is more reliable and gives admins control over who can access Gitea.

## User Account Setup Workflows

### Option 1: Automatic User Sync (Recommended)

Use the provided script to automatically create Gitea accounts for all lldap users:

```bash
./sync-gitea-users.sh
```

This script will:
- Query lldap for all users
- Create matching Gitea accounts
- Set random passwords (users won't need them)
- Configure accounts for auto-linking

**After running this script**, users can:
1. Go to https://git.rocketscale.it
2. Click "Sign in with OpenID Connect"
3. Authenticate via Authelia
4. Their account will automatically link to OIDC
5. They're logged in!

### Option 2: Manual User Creation

As a Gitea admin:

1. Log in to Gitea
2. Go to Site Administration → User Accounts → Create User Account
3. Enter user details:
   - **Username**: Must match lldap username exactly
   - **Email**: Must match lldap email
   - **Password**: Can be random (user won't need it)
4. Uncheck "Force user to change password"
5. Create the account

The user can then log in via OIDC and the account will auto-link.

### Option 3: User Self-Registration + Manual Linking

1. User creates account at https://git.rocketscale.it/user/sign_up
2. User logs in with local credentials
3. User goes to Settings → Applications → Manage Account Links
4. User clicks "Link External Account" and selects "authelia"
5. User authenticates via Authelia
6. Account is linked, SSO enabled

## Initial Gitea Setup

If you've just reset Gitea, you need to complete the initial setup:

1. **Access Gitea**: Go to https://git.rocketscale.it
2. **Initial Configuration**:
   - Database: Keep defaults (SQLite3)
   - General Settings: Already pre-configured via environment variables
   - Administrator Account: Create your admin account
3. **Complete Setup**

4. **Configure OIDC Authentication Source**:
   - Go to Site Administration → Authentication Sources
   - Click "Add Authentication Source"
   - Select "OAuth2"
   - Configure:
     - **Authentication Name**: `authelia`
     - **OAuth2 Provider**: OpenID Connect
     - **Client ID**: `gitea`
     - **Client Secret**: Get from deployment output or `.env` file
     - **Auto Discovery URL**: `https://auth.rocketscale.it/.well-known/openid-configuration`
     - **Icon URL**: (optional) `https://www.authelia.com/images/branding/logo-cropped.png`
     - Check: "This authentication source is activated"
   - Save

5. **Sync Users** (if using Option 1):
   ```bash
   ./sync-gitea-users.sh
   ```

## Verifying SSO Works

1. Open an incognito/private browser window
2. Go to https://git.rocketscale.it
3. Click "Sign in with OpenID Connect"
4. You should be redirected to Authelia
5. Log in with your lldap credentials
6. You should be redirected back to Gitea and logged in

## Troubleshooting

### "Missing fields: email,nickname" Error

This error appears when auto-registration is enabled. Make sure `GITEA__oauth2_client__ENABLE_AUTO_REGISTRATION=false` in `compose.yml`.

### "No account linked" Error

The user account doesn't exist in Gitea yet. Either:
- Run `./sync-gitea-users.sh` to create it
- Create the account manually (Option 2)
- Have the user self-register first (Option 3)

### User Can't Link Account

Make sure:
1. The OIDC authentication source is configured correctly
2. The username in Gitea exactly matches the username in lldap
3. The email in Gitea exactly matches the email in lldap

### OIDC Login Button Not Showing

1. Check that the Authelia authentication source is activated
2. Restart Gitea: `docker compose restart gitea`
3. Clear browser cache

## How Auto-Linking Works

With `GITEA__oauth2_client__ACCOUNT_LINKING=auto`:

1. User authenticates via OIDC
2. Gitea receives the authenticated user's information
3. Gitea looks for an existing account with matching username/email
4. If found, Gitea automatically links that account to the OIDC provider
5. User is logged in
6. Future logins via OIDC will use the linked account

This eliminates the need for users to manually link accounts, while still giving admins control over who can access Gitea.

## Security Notes

- Users who haven't linked their accounts can still log in with local credentials
- Once linked, users can log in via either method (local or OIDC)
- Admins can see linked accounts in Site Administration → User Accounts
- To force OIDC-only login, you can disable password authentication in Gitea's settings
