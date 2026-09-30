# Managed by vps-setup — static website
<VirtualHost *:80>
    ServerName {{DOMAIN}}
{{SERVER_ALIAS_LINE}}
    DocumentRoot {{ROOT}}

    ErrorLog  ${APACHE_LOG_DIR}/{{DOMAIN}}.error.log
    CustomLog ${APACHE_LOG_DIR}/{{DOMAIN}}.access.log combined

    <Directory {{ROOT}}>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    <IfModule mod_expires.c>
        ExpiresActive On
        ExpiresByType text/css "access plus 30 days"
        ExpiresByType application/javascript "access plus 30 days"
        ExpiresByType image/png "access plus 30 days"
        ExpiresByType image/jpeg "access plus 30 days"
        ExpiresByType image/webp "access plus 30 days"
        ExpiresByType image/svg+xml "access plus 30 days"
        ExpiresByType font/woff2 "access plus 30 days"
    </IfModule>
</VirtualHost>
