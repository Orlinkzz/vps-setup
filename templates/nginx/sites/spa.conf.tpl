# Managed by vps-setup — single-page app (React / Vue / Svelte build output)
server {
    listen 80;
    listen [::]:80;
    server_name {{SERVER_NAMES}};

    root {{ROOT}};
    index index.html;

    access_log /var/log/nginx/{{DOMAIN}}.access.log;
    error_log  /var/log/nginx/{{DOMAIN}}.error.log;

    include snippets/vps-setup/security-headers.conf;
    include snippets/vps-setup/deny-hidden.conf;

    # Every unknown path falls back to the app shell (client-side routing).
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Hashed build assets can be cached for a long time ...
    location ~* \.(?:css|js|mjs|jpe?g|gif|png|svg|ico|webp|avif|woff2?|ttf|otf)$ {
        include snippets/vps-setup/static-cache.conf;
        try_files $uri =404;
    }

    # ... but the app shell must always be revalidated.
    location = /index.html {
        add_header Cache-Control "no-cache" always;
        include snippets/vps-setup/security-headers.conf;
    }
}
