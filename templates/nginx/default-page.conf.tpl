# Managed by vps-setup — unknown hostnames / direct IP access: friendly "server ready" page.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/_default;
    index index.html;

    location / {
        try_files $uri /index.html;
    }
}
