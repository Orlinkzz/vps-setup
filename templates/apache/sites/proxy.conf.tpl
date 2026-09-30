# Managed by vps-setup — reverse proxy to an app on {{UPSTREAM}}
# Needs: proxy proxy_http proxy_wstunnel rewrite headers (enabled by vps-setup)
<VirtualHost *:80>
    ServerName {{DOMAIN}}
{{SERVER_ALIAS_LINE}}
    ErrorLog  ${APACHE_LOG_DIR}/{{DOMAIN}}.error.log
    CustomLog ${APACHE_LOG_DIR}/{{DOMAIN}}.access.log combined

    ProxyPreserveHost On
    ProxyRequests Off
    RequestHeader set X-Forwarded-Proto "http"
    RequestHeader set X-Forwarded-Port "80"

    # WebSocket upgrade
    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} =websocket [NC]
    RewriteRule /(.*) ws://{{UPSTREAM}}/$1 [P,L]

    ProxyPass        / http://{{UPSTREAM}}/
    ProxyPassReverse / http://{{UPSTREAM}}/
</VirtualHost>
