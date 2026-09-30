# Managed by vps-setup — single-page app (React / Vue / Svelte build output)
{{SERVER_NAMES_COMMA}} {
    root * {{ROOT}}
    encode zstd gzip
    import security_headers
    import hide_dotfiles
    try_files {path} /index.html
    file_server
}
