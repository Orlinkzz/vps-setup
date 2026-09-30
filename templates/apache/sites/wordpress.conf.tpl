# Managed by vps-setup — WordPress (PHP-FPM). Files live directly in /var/www/{{DOMAIN}}.
<VirtualHost *:80>
    ServerName {{DOMAIN}}
{{SERVER_ALIAS_LINE}}
    DocumentRoot {{ROOT}}
    DirectoryIndex index.php index.html

    ErrorLog  ${APACHE_LOG_DIR}/{{DOMAIN}}.error.log
    CustomLog ${APACHE_LOG_DIR}/{{DOMAIN}}.access.log combined

    <Directory {{ROOT}}>
        Options -Indexes +FollowSymLinks
        # WordPress permalinks use .htaccess
        AllowOverride All
        Require all granted
    </Directory>

    # Never execute PHP from upload folders.
    <DirectoryMatch "^{{ROOT}}/wp-content/uploads">
        <FilesMatch "\.php$">
            Require all denied
        </FilesMatch>
    </DirectoryMatch>

    <FilesMatch "\.php$">
        SetHandler "proxy:unix:{{PHP_SOCKET_PATH}}|fcgi://localhost"
    </FilesMatch>
</VirtualHost>
