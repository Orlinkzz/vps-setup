# Managed by vps-setup — generic PHP site (PHP-FPM)
server {
    listen 80;
    listen [::]:80;
    server_name {{SERVER_NAMES}};

    root {{ROOT}};
    index index.php index.html;

    access_log /var/log/nginx/{{DOMAIN}}.access.log;
    error_log  /var/log/nginx/{{DOMAIN}}.error.log;

    include snippets/vps-setup/security-headers.conf;
    include snippets/vps-setup/deny-hidden.conf;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:{{PHP_SOCKET_PATH}};
    }

    location ~* \.(?:css|js|mjs|jpe?g|gif|png|svg|ico|webp|avif|woff2?|ttf|otf)$ {
        include snippets/vps-setup/static-cache.conf;
        try_files $uri =404;
    }
}
