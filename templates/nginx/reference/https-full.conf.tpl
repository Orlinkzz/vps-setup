# REFERENCE ONLY — not used automatically.
# A complete HTTPS vhost written by hand (what Certbot generates for you, made explicit).
# Use it if you manage certificates yourself. Replace paths, then:
#   nginx -t && systemctl reload nginx

server {
    listen 80;
    listen [::]:80;
    server_name {{SERVER_NAMES}};

    # ACME HTTP-01 challenge must stay reachable over HTTP.
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    # Ubuntu 22.04 / 24.04 ship nginx 1.18 / 1.24: HTTP/2 is enabled on the listen line.
    # On nginx >= 1.25.1 use plain "listen 443 ssl;" plus a separate "http2 on;" line instead.
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {{SERVER_NAMES}};

    ssl_certificate     /etc/letsencrypt/live/{{DOMAIN}}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{DOMAIN}}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # Enable only when you are sure HTTPS will keep working (browsers remember it).
    # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    include snippets/vps-setup/security-headers.conf;

    root {{ROOT}};
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
