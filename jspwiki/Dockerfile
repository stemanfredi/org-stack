FROM eclipse-temurin:17-jdk AS builder

# Compile Remote-User filter
WORKDIR /build
COPY RemoteUserFilter.java .
RUN javac -cp /usr/local/tomcat/lib/servlet-api.jar:. RemoteUserFilter.java 2>/dev/null || \
    wget -q https://repo1.maven.org/maven2/jakarta/servlet/jakarta.servlet-api/6.0.0/jakarta.servlet-api-6.0.0.jar && \
    javac -cp jakarta.servlet-api-6.0.0.jar RemoteUserFilter.java && \
    jar cf RemoteUserFilter.jar RemoteUserFilter*.class

FROM apache/jspwiki:latest

# Install ldap-utils for LDAP sync
RUN apt-get update && \
    apt-get install -y ldap-utils && \
    rm -rf /var/lib/apt/lists/*

# Copy compiled filter
COPY --from=builder /build/RemoteUserFilter.jar /usr/local/tomcat/webapps/ROOT/WEB-INF/lib/

# Copy LDAP sync script and custom entrypoint
COPY ldap-sync.sh /usr/local/bin/ldap-sync
COPY configure-web-xml.sh /usr/local/bin/configure-web-xml
COPY entrypoint.sh /custom-entrypoint.sh
RUN chmod +x /usr/local/bin/ldap-sync /usr/local/bin/configure-web-xml /custom-entrypoint.sh

# Use custom entrypoint that runs LDAP sync before starting Tomcat
ENTRYPOINT ["/custom-entrypoint.sh"]
