#!/bin/bash
# Configure web.xml to use RemoteUserFilter for SSO
set -e

WEB_XML="/usr/local/tomcat/webapps/ROOT/WEB-INF/web.xml"
MARKER="<!-- REMOTE_USER_FILTER_CONFIGURED -->"

echo "Configuring JSPWiki for Remote-User SSO..." >&2

# Check if already configured
if grep -q "$MARKER" "$WEB_XML" 2>/dev/null; then
    echo "✓ RemoteUserFilter already configured" >&2
    exit 0
fi

# Add RemoteUserFilter configuration after <web-app> opening tag completes
# Find the line with version="5.0"> which closes the web-app opening tag
sed -i '/version="5.0">/a\
\
  <!-- REMOTE_USER_FILTER_CONFIGURED -->\
  <!-- Remote-User Filter for Authelia SSO -->\
  <filter>\
    <filter-name>RemoteUserFilter</filter-name>\
    <filter-class>RemoteUserFilter</filter-class>\
  </filter>\
  <filter-mapping>\
    <filter-name>RemoteUserFilter</filter-name>\
    <url-pattern>/*</url-pattern>\
  </filter-mapping>' "$WEB_XML"

echo "✓ RemoteUserFilter configured in web.xml" >&2
