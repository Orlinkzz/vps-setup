# Managed by vps-setup — generic PHP site (PHP-FPM)
{{SERVER_NAMES_COMMA}} {
    root * {{ROOT}}
    encode zstd gzip
    import security_headers
    import hide_dotfiles
    php_fastcgi unix/{{PHP_SOCKET_PATH}}
    file_server
}
