#!/bin/bash

# xUI Subscription Injector Script
# This script sets up an Nginx configuration to inject an external backup link
# into xUI subscription URLs interactively.

# Colors for better UI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root (use sudo).${NC}"
  exit 1
fi

# Install prerequisites
echo -e "${YELLOW}Installing prerequisites...${NC}"
apt update && apt install -y nginx nginx-extras sqlite3 curl

# Interactive input
echo -e "${YELLOW}Please provide the following details:${NC}"
read -p "Enter your domain (e.g., dhc.styxx.click): " DOMAIN
read -p "Enter the port for subscriptions (e.g., 2097): " PORT
read -p "Enter the path to SSL fullchain.pem (e.g., /etc/ssl/fullchain.pem): " SSL_CERT
read -p "Enter the path to SSL privkey.pem (e.g., /etc/ssl/privkey.pem): " SSL_KEY
read -p "Enter the external backup link (e.g., https://backup.styxx.click): " BACKUP_LINK

# Validate inputs
if [ -z "$DOMAIN" ] || [ -z "$PORT" ] || [ -z "$SSL_CERT" ] || [ -z "$SSL_KEY" ] || [ -z "$BACKUP_LINK" ]; then
  echo -e "${RED}All fields are required. Exiting.${NC}"
  exit 1
fi

if ! [ -f "$SSL_CERT" ] || ! [ -f "$SSL_KEY" ]; then
  echo -e "${RED}SSL certificate or key file not found. Please provide valid paths.${NC}"
  exit 1
fi

# Create subscriptions directory
mkdir -p /var/www/subscriptions
chown www-data:www-data /var/www/subscriptions
chmod 755 /var/www/subscriptions

# Generate Nginx configuration
cat <<EOF > /etc/nginx/sites-available/xui-subscription.conf
server {
    listen ${PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};

    location ~ ^/sub/(.+)$ {
        set \$sub_id \$1;
        default_type text/plain;

        access_by_lua_block {
            local sub_id = ngx.var.sub_id
            local db = io.popen("sqlite3 /etc/x-ui/x-ui.db \"SELECT json_extract(clients, '\$[0]') FROM inbounds WHERE json_extract(clients, '\$[0].subId') = '" .. sub_id .. "' LIMIT 1\"")
            local client_data = db:read("*a")
            db:close()

            if client_data and client_data ~= "" then
                local json = require "cjson"
                local data = json.decode(client_data)
                local vmess_id = data.id
                local config = "vmess://" .. vmess_id .. "?security=none#sub_" .. sub_id
                ngx.var.subscription_data = config .. "\\n${BACKUP_LINK}"
            else
                ngx.var.subscription_data = "Invalid subId"
            end
        }
        return 200 \$subscription_data;
    }
}
EOF

# Enable the configuration
ln -sf /etc/nginx/sites-available/xui-subscription.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# Check status
if [ $? -eq 0 ]; then
  echo -e "${GREEN}Setup completed successfully!${NC}"
  echo -e "Access your subscriptions at https://${DOMAIN}:${PORT}/sub/<subId>"
else
  echo -e "${RED}Nginx configuration test failed. Please check logs.${NC}"
  exit 1
fi

echo -e "${YELLOW}Note: Ensure x-ui.db is accessible and the Lua module is enabled in Nginx.${NC}"