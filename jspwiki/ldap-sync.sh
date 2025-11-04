#!/bin/bash
# Sync LDAP users to JSPWiki XML databases
# Queries LLDAP via ldapsearch and generates JSPWiki XML files

set -euo pipefail

JSPWIKI_USERS="/var/jspwiki/etc/userdatabase.xml"
JSPWIKI_GROUPS="/var/jspwiki/etc/groupdatabase.xml"

# LDAP connection parameters (from environment or defaults)
LDAP_HOST="${LDAP_HOST:-lldap}"
LDAP_PORT="${LDAP_PORT:-3890}"
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=example,dc=com}"
LDAP_BIND_DN="uid=admin,ou=people,${LDAP_BASE_DN}"
LDAP_BIND_PASSWORD="${LLDAP_ADMIN_PASSWORD:-changeme}"

echo "Syncing LDAP users to JSPWiki..." >&2
echo "LDAP Host: ${LDAP_HOST}:${LDAP_PORT}" >&2
echo "Base DN: ${LDAP_BASE_DN}" >&2

# Create JSPWiki etc directory if it doesn't exist
mkdir -p "$(dirname "$JSPWIKI_USERS")"

# Check if ldapsearch is available
if ! command -v ldapsearch &> /dev/null; then
    echo "ERROR: ldapsearch not found. Install ldap-utils package." >&2
    exit 1
fi

# Test LDAP connection
echo "Testing LDAP connection..." >&2
if ! ldapsearch -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PASSWORD}" -b "${LDAP_BASE_DN}" -s base &>/dev/null; then
    echo "ERROR: Cannot connect to LDAP server" >&2
    exit 1
fi
echo "✓ LDAP connection successful" >&2

# Query all users from LDAP
echo "Querying LDAP users..." >&2
USERS_LDIF=$(ldapsearch -x -LLL -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PASSWORD}" \
    -b "ou=people,${LDAP_BASE_DN}" \
    "(objectClass=person)" uid displayName mail)

# Start building userdatabase.xml
cat > "$JSPWIKI_USERS" << 'EOF_HEADER'
<?xml version="1.0" encoding="UTF-8"?>
<users>
EOF_HEADER

# Parse LDIF and create JSPWiki user entries
echo "$USERS_LDIF" | awk '
BEGIN {
    uid=""; displayName=""; mail="";
}
/^dn:/ {
    # Save previous user if exists
    if (uid) {
        print "  <user";
        print "    loginName=\"" uid "\"";
        print "    fullName=\"" displayName "\"";
        print "    wikiName=\"" uid "\"";
        print "    password=\"{SSHA}placeholder\"";
        print "    email=\"" mail "\" />";
    }
    uid=""; displayName=""; mail="";
}
/^uid: / { uid = $2; }
/^displayName: / {
    displayName = substr($0, 14);
    gsub(/^[ \t]+|[ \t]+$/, "", displayName);
}
/^mail: / { mail = $2; }
END {
    # Save last user
    if (uid) {
        print "  <user";
        print "    loginName=\"" uid "\"";
        print "    fullName=\"" displayName "\"";
        print "    wikiName=\"" uid "\"";
        print "    password=\"{SSHA}placeholder\"";
        print "    email=\"" mail "\" />";
    }
}
' >> "$JSPWIKI_USERS"

# Close userdatabase.xml
cat >> "$JSPWIKI_USERS" << 'EOF_FOOTER'
</users>
EOF_FOOTER

USER_COUNT=$(grep -c 'loginName=' "$JSPWIKI_USERS" || echo 0)
echo "✓ Synced $USER_COUNT users" >&2

# Query groups from LDAP
echo "Querying LDAP groups..." >&2
GROUPS_LDIF=$(ldapsearch -x -LLL -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PASSWORD}" \
    -b "ou=groups,${LDAP_BASE_DN}" \
    "(objectClass=groupOfUniqueNames)" cn uniqueMember)

# Build groupdatabase.xml
cat > "$JSPWIKI_GROUPS" << 'EOF_HEADER'
<?xml version="1.0" encoding="UTF-8"?>
<groups>
EOF_HEADER

# Parse groups and create JSPWiki group entries
# Map LLDAP's lldap_admin group to JSPWiki's Admin group
echo "$GROUPS_LDIF" | awk -v base_dn="$LDAP_BASE_DN" '
BEGIN {
    cn=""; members=""; in_admin_group=0;
}
/^dn:/ {
    # Save previous group if it was lldap_admin
    if (cn == "lldap_admin" && members) {
        print "  <group name=\"Admin\">";
        print members;
        print "  </group>";
    }
    cn=""; members=""; in_admin_group=0;
}
/^cn: / {
    cn = $2;
    if (cn == "lldap_admin") in_admin_group=1;
}
/^uniqueMember: / && in_admin_group {
    # Extract uid from DN like "uid=admin,ou=people,dc=example,dc=com"
    dn = substr($0, 15);
    # Extract uid value using portable AWK
    if (index(dn, "uid=") > 0) {
        uid_part = substr(dn, index(dn, "uid=") + 4);
        comma_pos = index(uid_part, ",");
        if (comma_pos > 0) {
            uid_value = substr(uid_part, 1, comma_pos - 1);
        } else {
            uid_value = uid_part;
        }
        members = members "    <member principal=\"" uid_value "\" />\n";
    }
}
END {
    # Save last group if it was lldap_admin
    if (cn == "lldap_admin" && members) {
        print "  <group name=\"Admin\">";
        print members;
        print "  </group>";
    }
}
' >> "$JSPWIKI_GROUPS"

# Close groupdatabase.xml
cat >> "$JSPWIKI_GROUPS" << 'EOF_FOOTER'
</groups>
EOF_FOOTER

ADMIN_COUNT=$(grep -c 'member principal=' "$JSPWIKI_GROUPS" || echo 0)
echo "✓ Synced Admin group with $ADMIN_COUNT members" >&2
echo "✓ LDAP sync complete" >&2
