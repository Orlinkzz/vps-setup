# Managed by vps-setup — single-page app (React / Vue / Svelte build output)
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
        # Unknown paths fall back to the app shell (client-side routing).
        FallbackResource /index.html
    </Directory>

    <Files "index.html">
        Header set Cache-Control "no-cache"
    </Files>
</VirtualHost>
