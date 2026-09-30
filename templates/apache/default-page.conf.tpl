# Managed by vps-setup — unknown hostnames / direct IP access: friendly "server ready" page.
<VirtualHost *:80>
    ServerName _default_
    DocumentRoot /var/www/_default
    <Directory /var/www/_default>
        Options -Indexes
        Require all granted
    </Directory>
</VirtualHost>
