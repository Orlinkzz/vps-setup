# Managed by vps-setup — reverse proxy to an app on {{UPSTREAM}} (WebSockets work automatically)
{{SERVER_NAMES_COMMA}} {
    encode zstd gzip
    import security_headers
    reverse_proxy {{UPSTREAM}}
}
