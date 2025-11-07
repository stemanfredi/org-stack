FROM python:3.11-alpine

WORKDIR /app

# Install LDAP tools and dependencies
RUN apk add --no-cache openldap-clients

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .
COPY templates/ templates/

# Create data directory for SQLite database
RUN mkdir -p /data && chmod 777 /data

EXPOSE 5000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "5000"]
