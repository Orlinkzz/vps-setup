# Managed by vps-setup — unknown hostnames / direct IP access: 403.
# Loaded first (000-) so it becomes the default virtual host.
<VirtualHost *:80>
    ServerName _default_
    <Location "/">
        Require all denied
    </Location>
</VirtualHost>
