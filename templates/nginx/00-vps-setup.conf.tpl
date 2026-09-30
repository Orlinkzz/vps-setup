# Managed by vps-setup — global Nginx settings (http context).
# File: /etc/nginx/conf.d/00-vps-setup.conf

server_tokens off;

client_max_body_size {{MAX_BODY}};
client_body_timeout 30s;
client_header_timeout 30s;
keepalive_timeout 30s;
send_timeout 30s;
types_hash_max_size 2048;

gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types text/plain text/css text/xml text/javascript application/json
           application/javascript application/xml application/rss+xml
           application/wasm image/svg+xml font/ttf font/otf;

# Used by reverse-proxy sites for WebSocket support (defined once, here).
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
