# Managed by vps-setup — generic PHP site (PHP-FPM via proxy_fcgi)
<VirtualHost *:80>
    ServerName {{DOMAIN}}
{{SERVER_ALIAS_LINE}}
    DocumentRoot {{ROOT}}
    DirectoryIndex index.php index.html

    ErrorLog  ${APACHE_LOG_DIR}/{{DOMAIN}}.error.log
    CustomLog ${APACHE_LOG_DIR}/{{DOMAIN}}.access.log combined

    <Directory {{ROOT}}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch "\.php$">
        SetHandler "proxy:unix:{{PHP_SOCKET_PATH}}|fcgi://localhost"
    </FilesMatch>
</VirtualHost>
