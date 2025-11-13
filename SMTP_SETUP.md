# SMTP Email Notification Setup

Configure SMTP email notifications for password resets, 2FA codes, and user registration approvals.

## Quick Setup

**All steps are done on your LOCAL machine** (the one with the org-stack git repo).

### 1. Edit Local `.env` File

On your local machine, edit `.env` and add your SMTP credentials:

```bash
# Enable SMTP
SMTP_ENABLED=true

# SMTP Server Configuration
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASSWORD='your-app-password'  # Use single quotes for passwords with special chars
SMTP_FROM=noreply@yourdomain.com
SMTP_USE_TLS=true

# Admin email for registration notifications
REGISTRATION_ADMIN_EMAIL=admin@yourdomain.com
```

**Note**: If your password contains special characters like `( ) $ " '`, wrap it in single quotes.

### 2. Deploy from Local Machine

```bash
./deploy.sh
```

That's it! The deployment script:
- Syncs your `.env` to the remote server
- Automatically configures SMTP in all services
- Restarts containers

## SMTP Provider Examples

### Gmail
```bash
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASSWORD=your-16-char-app-password  # Create at https://myaccount.google.com/apppasswords
SMTP_USE_TLS=true
```

### SendGrid
```bash
SMTP_HOST=smtp.sendgrid.net
SMTP_PORT=587
SMTP_USER=apikey
SMTP_PASSWORD=your-sendgrid-api-key
SMTP_USE_TLS=true
```

### Mailgun
```bash
SMTP_HOST=smtp.mailgun.org
SMTP_PORT=587
SMTP_USER=postmaster@your-domain.mailgun.org
SMTP_PASSWORD=your-mailgun-smtp-password
SMTP_USE_TLS=true
```

### Office 365
```bash
SMTP_HOST=smtp.office365.com
SMTP_PORT=587
SMTP_USER=your-email@yourdomain.com
SMTP_PASSWORD=your-password
SMTP_USE_TLS=true
```

## Testing

### Test Authelia (Password Reset)
1. Go to https://auth.yourdomain.com
2. Click "Forgot password?"
3. Enter your username
4. Check email for reset link

### Test Registration Service
1. Submit a registration at https://register.yourdomain.com
2. Admin receives notification email
3. Approve the request at https://register.yourdomain.com/admin
4. User receives credentials via email

## Troubleshooting

### Check Service Logs

**Authelia:**
```bash
ssh user@host 'cd ~/org-stack && docker compose logs authelia | grep -i smtp'
```

**Registration:**
```bash
ssh user@host 'cd ~/org-stack && docker compose logs registration | grep -i smtp'
```

### Common Issues

**Authentication Failed (535)**
- Gmail: Enable 2FA and create an [App Password](https://myaccount.google.com/apppasswords)
- Verify SMTP_USER and SMTP_PASSWORD are correct

**Connection Refused**
- Check SMTP_HOST and SMTP_PORT are correct
- Verify firewall allows outbound connections on port 587/465

**Certificate Errors**
- Ensure SMTP_USE_TLS=true for port 587
- Use SMTP_USE_TLS=false only for port 25 (not recommended)

### Disable SMTP

To switch back to filesystem logging:

```bash
# In .env
SMTP_ENABLED=false

# Deploy
./deploy.sh
```

## What Gets Sent

### Authelia Sends:
- 2FA setup verification codes
- Password reset links
- New device registration confirmations

### Registration Service Sends:
- Admin notification when user requests registration
- User approval with auto-generated credentials
- User rejection with reason

## Security Notes

- SMTP passwords are stored in `.env` (gitignored, not committed)
- Use app passwords for Gmail/Google Workspace
- Rotate passwords regularly by updating `.env` and redeploying

## See Also

- [Authelia SMTP Configuration](https://www.authelia.com/configuration/notifications/smtp/)
- [Gmail App Passwords](https://support.google.com/accounts/answer/185833)
- [SendGrid SMTP](https://docs.sendgrid.com/for-developers/sending-email/integrating-with-the-smtp-api)
- [Mailgun SMTP](https://documentation.mailgun.com/en/latest/user_manual.html#sending-via-smtp)
