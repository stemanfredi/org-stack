#!/bin/bash
set -e

# Configure web.xml for container authentication
echo "Configuring JSPWiki for container authentication..." >&2
/usr/local/bin/configure-web-xml

# Read lldap admin password from secret file
if [ -f "/secrets-lldap/LDAP_USER_PASS" ]; then
    export LLDAP_ADMIN_PASSWORD=$(cat /secrets-lldap/LDAP_USER_PASS)
fi

# Sync LDAP users to JSPWiki
echo "Syncing LDAP users to JSPWiki..." >&2
if /usr/local/bin/ldap-sync; then
    echo "✓ LDAP sync successful" >&2
else
    echo "⚠ LDAP sync failed - JSPWiki may not have users initialized" >&2
    echo "  Check LDAP connection and credentials in secret file" >&2
fi

# Start Tomcat using the official image's entrypoint
exec /usr/local/tomcat/bin/catalina.sh run
