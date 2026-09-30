# Managed by vps-setup — static website
{{SERVER_NAMES_COMMA}} {
    root * {{ROOT}}
    encode zstd gzip
    import security_headers
    import hide_dotfiles
    file_server
}
