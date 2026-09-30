# Managed by vps-setup — WordPress (PHP-FPM). Files live directly in /var/www/{{DOMAIN}}.
{{SERVER_NAMES_COMMA}} {
    root * {{ROOT}}
    encode zstd gzip
    import security_headers
    import hide_dotfiles

    # Never execute PHP from upload folders.
    @uploads_php path_regexp ^/wp-content/uploads/.*\.php$
    respond @uploads_php 403

    php_fastcgi unix/{{PHP_SOCKET_PATH}}
    file_server
}
