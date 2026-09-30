# Managed by vps-setup — Laravel (PHP-FPM). App lives in /var/www/{{DOMAIN}}, web root is its public/ folder.
server {
    listen 80;
    listen [::]:80;
    server_name {{SERVER_NAMES}};

    root {{ROOT}};
    index index.php;
    charset utf-8;

    access_log /var/log/nginx/{{DOMAIN}}.access.log;
    error_log  /var/log/nginx/{{DOMAIN}}.error.log;

    include snippets/vps-setup/security-headers.conf;
    include snippets/vps-setup/deny-hidden.conf;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ ^/index\.php(/|$) {
        fastcgi_pass unix:{{PHP_SOCKET_PATH}};
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 60s;
    }

    # Only index.php may execute; any other .php file is not served.
    location ~ \.php$ {
        return 404;
    }

    location ~* \.(?:css|js|mjs|jpe?g|gif|png|svg|ico|webp|avif|woff2?|ttf|otf)$ {
        include snippets/vps-setup/static-cache.conf;
        try_files $uri =404;
    }
}
