# Managed by vps-setup — permanent (301) redirect to {{REDIRECT_TARGET}}
server {
    listen 80;
    listen [::]:80;
    server_name {{SERVER_NAMES}};

    access_log off;
    error_log  /var/log/nginx/{{DOMAIN}}.error.log;

    location / {
        return 301 {{REDIRECT_TARGET}}$request_uri;
    }
}
