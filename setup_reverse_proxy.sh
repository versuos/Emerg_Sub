#!/bin/bash

# Script to install and configure Nginx as a Reverse Proxy for x-ui subscription
# Run as root: sudo bash setup_reverse_proxy.sh

# Exit on error
set -e

# Variables
DOMAIN="mor.nitruqen.ir"
SUBSCRIPTION_PORT="2053"
SUBSCRIPTION_PATH="/sub/"
USER_ID="ke89sxv61efh1u0x"
VLESS_CONFIG="vless://8443b331-a885-4786-bed7-5e8dfe34cd49@serv.styxx.click:32362?type=tcp&security=none#TCP-wldsldnv"
NGINX_CONFIG="/etc/nginx/sites-available/reverse_proxy"
PROXY_SCRIPT="/usr/local/bin/proxy_modifier.py"

# Step 1: Update system and install Nginx and Certbot
echo "Updating system and installing Nginx and Certbot..."
apt-get update -y
apt-get install -y nginx python3-certbot-nginx

# Step 2: Configure Nginx Reverse Proxy
echo "Configuring Nginx Reverse Proxy..."
cat > $NGINX_CONFIG <<EOL
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # Redirect HTTP to HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    # SSL configuration (to be filled by Certbot)
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/nginx/snippets/ssl-params.conf;

    location $SUBSCRIPTION_PATH {
        proxy_pass http://127.0.0.1:$SUBSCRIPTION_PORT$SUBSCRIPTION_PATH;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass_request_headers on;
    }
}
EOL

# Step 3: Create SSL params snippet
echo "Creating SSL parameters snippet..."
mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/ssl-params.conf <<EOL
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384;
ssl_ecdh_curve secp384r1;
ssl_session_timeout 10m;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";
add_header X-Frame-Options DENY;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
ssl_dhparam /etc/ssl/certs/dhparam.pem;
EOL

# Step 4: Generate Diffie-Hellman group
echo "Generating Diffie-Hellman group..."
openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048

# Step 5: Enable Nginx configuration
echo "Enabling Nginx configuration..."
ln -sf $NGINX_CONFIG /etc/nginx/sites-enabled/reverse_proxy
rm -f /etc/nginx/sites-enabled/default

# Step 6: Test and reload Nginx
echo "Testing and reloading Nginx..."
nginx -t
systemctl reload nginx

# Step 7: Obtain SSL certificate with Certbot
echo "Obtaining SSL certificate..."
certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN

# Step 8: Create Python script to modify subscription response
echo "Creating Python script to append VLESS config..."
cat > $PROXY_SCRIPT <<EOL
#!/usr/bin/env python3
import sys
import base64

# Read input from stdin (Nginx proxy response)
input_data = sys.stdin.read()

# Decode if base64-encoded
try:
    decoded_data = base64.b64decode(input_data).decode('utf-8')
except:
    decoded_data = input_data

# Append VLESS config
vless_config = "$VLESS_CONFIG"
output_data = decoded_data + "\\n" + vless_config

# Encode back to base64 if needed
print(base64.b64encode(output_data.encode('utf-8')).decode('utf-8'))
EOL

# Make Python script executable
chmod +x $PROXY_SCRIPT

# Step 9: Update Nginx to use Python script
echo "Updating Nginx to use Python script..."
sed -i "/proxy_pass_request_headers on;/a \    proxy_pass http://127.0.0.1:8080;" $NGINX_CONFIG
cat >> $NGINX_CONFIG <<EOL

server {
    listen 8080;
    location $SUBSCRIPTION_PATH {
        proxy_pass http://127.0.0.1:$SUBSCRIPTION_PORT$SUBSCRIPTION_PATH;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass_request_headers on;
        # Pipe response through Python script
        filter_by_lua_block {
            local handle = io.popen("$PROXY_SCRIPT", "r+")
            handle:write(ngx.arg[1])
            handle:close()
            ngx.arg[1] = handle:read("*a")
        }
    }
}
EOL

# Step 10: Install Lua module for Nginx
echo "Installing Nginx Lua module..."
apt-get install -y lua-nginx-module

# Step 11: Test and reload Nginx again
echo "Testing and reloading Nginx..."
nginx -t
systemctl reload nginx

# Step 12: Enable Nginx and Certbot auto-renewal
echo "Enabling Nginx and Certbot auto-renewal..."
systemctl enable nginx
echo "30 2 * * 1 /usr/bin/certbot renew --quiet && systemctl reload nginx" >> /etc/crontab

echo "Setup complete! Access your subscription at https://$DOMAIN$SUBSCRIPTION_PATH$USER_ID"