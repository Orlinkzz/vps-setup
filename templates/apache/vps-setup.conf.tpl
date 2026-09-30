# Managed by vps-setup — global Apache settings.
# File: /etc/apache2/conf-available/vps-setup.conf  (enabled with a2enconf)

# Avoids the "could not determine the server's fully qualified domain name" warning.
ServerName localhost

ServerTokens Prod
ServerSignature Off
TraceEnable Off

<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"
    # HSTS intentionally off by default. Enable only when HTTPS works everywhere:
    # Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
</IfModule>

<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/plain text/html text/css text/xml text/javascript
    AddOutputFilterByType DEFLATE application/json application/javascript application/xml image/svg+xml
</IfModule>

# Never serve dotfiles (.git, .env ...) except ACME challenges.
<DirectoryMatch "/\.(?!well-known)">
    Require all denied
</DirectoryMatch>
<FilesMatch "^\.(?!well-known)">
    Require all denied
</FilesMatch>

# Limit request body size ({{MAX_BODY}} in bytes; 0 = unlimited).
LimitRequestBody {{MAX_BODY_BYTES}}
