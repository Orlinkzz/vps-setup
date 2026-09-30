# Managed by vps-setup — unknown hostnames / direct IP access: close the connection.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
