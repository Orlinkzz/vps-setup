# Managed by vps-setup — Laravel (PHP-FPM). App in /var/www/{{DOMAIN}}, web root is public/.
{{SERVER_NAMES_COMMA}} {
    root * {{ROOT}}
    encode zstd gzip
    import security_headers
    import hide_dotfiles
    php_fastcgi unix/{{PHP_SOCKET_PATH}}
    file_server
}
