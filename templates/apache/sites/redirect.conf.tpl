# Managed by vps-setup — permanent (301) redirect to {{REDIRECT_TARGET}}
<VirtualHost *:80>
    ServerName {{DOMAIN}}
{{SERVER_ALIAS_LINE}}
    ErrorLog ${APACHE_LOG_DIR}/{{DOMAIN}}.error.log
    RedirectMatch permanent ^(.*)$ {{REDIRECT_TARGET}}$1
</VirtualHost>
