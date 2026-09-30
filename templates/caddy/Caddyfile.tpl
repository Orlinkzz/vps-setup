# Managed by vps-setup — main Caddyfile (/etc/caddy/Caddyfile)
# HTTPS certificates are obtained and renewed automatically by Caddy.
{{GLOBAL_OPTIONS}}
(security_headers) {
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "geolocation=(), microphone=(), camera=()"
        -Server
    }
}

(hide_dotfiles) {
    @dotfiles {
        path */.*
        not path /.well-known/*
    }
    respond @dotfiles 404
}

# One file per website lives in /etc/caddy/sites-enabled/
import /etc/caddy/sites-enabled/*.caddy

# Anything not matched above (direct IP access, unknown hostnames):
{{CATCHALL}}
