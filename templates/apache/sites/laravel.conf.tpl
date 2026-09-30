# Managed by vps-setup — Laravel (PHP-FPM). App in /var/www/{{DOMAIN}}, web root is public/.
<VirtualHost *:80>
    ServerName {{DOMAIN}}
{{SERVER_ALIAS_LINE}}
    DocumentRoot {{ROOT}}
    DirectoryIndex index.php

    ErrorLog  ${APACHE_LOG_DIR}/{{DOMAIN}}.error.log
    CustomLog ${APACHE_LOG_DIR}/{{DOMAIN}}.access.log combined

    <Directory {{ROOT}}>
        Options -Indexes +FollowSymLinks
        # Laravel's public/.htaccess needs mod_rewrite
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch "\.php$">
        SetHandler "proxy:unix:{{PHP_SOCKET_PATH}}|fcgi://localhost"
    </FilesMatch>
</VirtualHost>
