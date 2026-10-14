# Managed by vps-setup — Laravel (PHP-FPM). App in /var/www/{{DOMAIN}}, web root is public/.
{{SERVER_NAMES_COMMA}} {
    root * {{ROOT}}
    encode zstd gzip
    import security_headers
{{HSTS_LINE}}
    import hide_dotfiles
    # Only the front controller runs; other .php files under public/ are never executed
    @php_other {
        path *.php
        not path /index.php
    }
    respond @php_other 404
    php_fastcgi unix/{{PHP_SOCKET_PATH}} {
        index index.php
    }
    file_server
}
