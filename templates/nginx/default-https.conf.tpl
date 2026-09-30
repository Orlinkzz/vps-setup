# Managed by vps-setup — refuse TLS handshakes for unknown hostnames (needs nginx >= 1.19.4).
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
