#!/bin/bash
# WifiScreen — One-command VPS setup (Ubuntu 20.04 / 22.04)
# Usage: bash setup.sh

set -e

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RESET='\033[0m'

echo ""
echo -e "${BOLD}  WifiScreen Setup${RESET}"
echo "  ─────────────────────────────"
echo ""

# ── Node.js 20 ──
if ! command -v node &>/dev/null; then
  echo "  Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
echo -e "  ${GREEN}✓${RESET} Node $(node -v)"

# ── LiveKit Server ──
if ! command -v livekit-server &>/dev/null; then
  echo "  Installing LiveKit server..."
  curl -sSL https://get.livekit.io | bash
fi
echo -e "  ${GREEN}✓${RESET} LiveKit $(livekit-server --version 2>/dev/null | head -1)"

# ── PM2 ──
if ! command -v pm2 &>/dev/null; then
  echo "  Installing PM2..."
  sudo npm install -g pm2
fi
echo -e "  ${GREEN}✓${RESET} PM2 $(pm2 -v)"

# ── Server dependencies ──
echo ""
echo "  Installing Node dependencies..."
cd server && npm install --production && cd ..

# ── .env ──
if [ ! -f .env ]; then
  cp .env.example .env

  # Generate a strong random secret (32 chars)
  SECRET=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
  APIKEY="wifiscreen$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)"

  # Detect public IP
  PUBLIC_IP=$(curl -s ifconfig.me)

  sed -i "s/devkey/$APIKEY/" .env
  sed -i "s/devsecret000000000000000000000000/$SECRET/" .env
  sed -i "s|ws://localhost:7880|ws://$PUBLIC_IP:7880|" .env

  # Also update livekit.yaml
  sed -i "s/devkey: devsecret000000000000000000000000/$APIKEY: $SECRET/" livekit.yaml

  echo ""
  echo -e "  ${CYAN}Generated credentials:${RESET}"
  echo "  API Key:    $APIKEY"
  echo "  API Secret: $SECRET"
  echo "  (saved to .env)"
fi

# Load env
export $(grep -v '^#' .env | xargs)

# ── Start LiveKit ──
echo ""
echo "  Starting LiveKit server..."
pm2 delete livekit 2>/dev/null || true
pm2 start livekit-server --name livekit -- --config livekit.yaml
pm2 save

# ── Start WifiScreen signaling server ──
echo "  Starting WifiScreen server..."
pm2 delete wifiscreen 2>/dev/null || true
pm2 start server/server.js --name wifiscreen --env production
pm2 save

# ── Startup on reboot ──
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u $USER --hp $HOME 2>/dev/null || true

PUBLIC_IP=$(curl -s ifconfig.me)
echo ""
echo -e "  ${GREEN}✓ WifiScreen is live!${RESET}"
echo ""
echo "  Broadcaster: http://$PUBLIC_IP:3000/broadcaster.html"
echo "  Viewer:      http://$PUBLIC_IP:3000/viewer.html"
echo "  Landing:     http://$PUBLIC_IP:3000/landing/"
echo ""
echo "  Max viewers: 50 (via LiveKit SFU)"
echo ""

# ── Firewall ──
if command -v ufw &>/dev/null; then
  echo "  Opening required ports..."
  sudo ufw allow 3000/tcp   # Signaling server
  sudo ufw allow 7880/tcp   # LiveKit WebSocket
  sudo ufw allow 7881/tcp   # LiveKit RTC/TCP
  sudo ufw allow 7882/udp   # LiveKit RTC/UDP
  sudo ufw allow 50000:60000/udp  # LiveKit media range
  echo -e "  ${GREEN}✓${RESET} Firewall ports opened"
fi

# ── Optional Nginx + SSL ──
echo ""
read -p "  Set up Nginx + SSL for a domain? (y/n): " setup_nginx
if [ "$setup_nginx" = "y" ]; then
  read -p "  Enter your domain (e.g. app.wifiscreen.io): " DOMAIN

  sudo apt-get install -y nginx certbot python3-certbot-nginx

  sudo tee /etc/nginx/sites-available/wifiscreen > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    # Signaling API + static files
    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # LiveKit WebSocket
    location /livekit/ {
        proxy_pass http://localhost:7880/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

  sudo ln -sf /etc/nginx/sites-available/wifiscreen /etc/nginx/sites-enabled/
  sudo nginx -t && sudo systemctl reload nginx

  sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

  # Update .env with domain
  sed -i "s|ws://.*:7880|wss://$DOMAIN/livekit|" .env
  pm2 restart wifiscreen

  echo ""
  echo -e "  ${GREEN}✓ Domain configured: https://$DOMAIN${RESET}"
fi

echo ""
echo "  Management:"
echo "  pm2 status               — check both services"
echo "  pm2 logs wifiscreen      — signaling server logs"
echo "  pm2 logs livekit         — LiveKit server logs"
echo "  pm2 restart all          — restart everything"
echo ""
