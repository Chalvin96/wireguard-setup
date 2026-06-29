#!/bin/bash
#
# setup-homelab-waf.sh - Install Caddy (+ proxy_protocol listener wrapper)
# and CrowdSec on the homelab, with an example Caddyfile that:
#   - unwraps PROXY Protocol v2 sent by the VPS HAProxy,
#   - recovers the real client IP as Caddy's $remote_addr,
#   - feeds access logs to CrowdSec,
#   - bounces malicious IPs via the hslatman/caddy-crowdsec-bouncer module.
#
# Environment variables (optional):
#   VPS_TUNNEL_IP  - WireGuard IP of the VPS, allowed to send PROXY headers
#                    (default: 10.8.0.1)
#   BACKEND_PORT   - local port Caddy reverse-proxies to (default: 8080)
#
set -e

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root"
  exit 1
fi

VPS_TUNNEL_IP="${VPS_TUNNEL_IP:-10.8.0.1}"
BACKEND_PORT="${BACKEND_PORT:-8080}"

CADDY_CONF_DIR="/etc/caddy"
CADDY_CONF_FILE="$CADDY_CONF_DIR/Caddyfile"
CADDY_EXAMPLE="$CADDY_CONF_DIR/Caddyfile.example"
LOG_DIR="/var/log/caddy"

# ---------------------------------------------------------------------------
# 1. Caddy
# ---------------------------------------------------------------------------
if ! command -v caddy >/dev/null 2>&1; then
  echo "Installing Caddy from the official repo..."
  apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt update
  apt install -y caddy
fi

# Add the CrowdSec bouncer module. The official Debian Caddy build supports
# `caddy add-package`, which fetches a custom binary containing the module.
BOUNCER_MODULE="github.com/hslatman/caddy-crowdsec-bouncer/http"
echo "Adding CrowdSec bouncer module to Caddy: $BOUNCER_MODULE"
caddy add-package "$BOUNCER_MODULE"

# Ensure Caddy can write logs.
mkdir -p "$LOG_DIR"
chown -R caddy:caddy "$LOG_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. CrowdSec
# ---------------------------------------------------------------------------
if ! command -v cscli >/dev/null 2>&1; then
  echo "Installing CrowdSec..."
  curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
  apt install -y crowdsec
fi

# Point CrowdSec at Caddy's JSON access log.
echo "Configuring CrowdSec acquisition (Caddy access log)..."
cat > /etc/crowdsec/acquis.yaml << EOF
filenames:
  - /var/log/caddy/access.log
labels:
  type: caddy
EOF

systemctl restart crowdsec

# ---------------------------------------------------------------------------
# 3. Example Caddyfile
# ---------------------------------------------------------------------------
mkdir -p "$CADDY_CONF_DIR"
[[ -f "$CADDY_CONF_FILE" && ! -f "${CADDY_CONF_FILE}.backup" ]] \
  && cp "$CADDY_CONF_FILE" "${CADDY_CONF_FILE}.backup"

echo "Writing example Caddyfile to $CADDY_EXAMPLE ..."

cat > "$CADDY_EXAMPLE" << EOF
{
    servers {
        protocols h1 h2 h3
    }

    # CrowdSec bouncer app (global config).
    # Replace <CROWDSEC_API_KEY> with the key from:
    #   sudo cscli bouncers add caddy-bouncer
    crowdsec {
        api_url http://localhost:8080
        api_key <CROWDSEC_API_KEY>
        ticker_interval 15s
    }
}

(logging) {
    log {
        output file /var/log/caddy/access.log {
            roll_size 10mb
            roll_keep 5
        }
        format json
    }
}

example.com {
    import logging

    # Unwrap PROXY Protocol v2 sent by the VPS HAProxy before TLS.
    # Only the VPS tunnel IP is allowed to send PROXY headers.
    listener_wrappers {
        proxy_protocol {
            timeout 2s
            allow $VPS_TUNNEL_IP
        }
        tls
    }

    route {
        crowdsec
        reverse_proxy localhost:$BACKEND_PORT
    }
}
EOF

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo "  1. Register a CrowdSec bouncer and copy the printed API key:"
echo "       sudo cscli bouncers add caddy-bouncer"
echo "  2. Edit $CADDY_EXAMPLE:"
echo "       - replace 'example.com' with your domain,"
echo "       - replace <CROWDSEC_API_KEY> with the key from step 1,"
echo "       - adjust BACKEND_PORT (currently $BACKEND_PORT)."
echo "  3. Apply it:"
echo "       sudo cp $CADDY_EXAMPLE $CADDY_CONF_FILE"
echo "       sudo caddy validate --config $CADDY_CONF_FILE --adapter caddyfile"
echo "       sudo systemctl restart caddy"
echo "  4. Verify the real client IP reaches logs:"
echo "       tail -f /var/log/caddy/access.log   # remote_ip should be the"
echo "                                           # browser's public IP, not 10.8.0.1"
echo "  5. Watch CrowdSec:"
echo "       sudo cscli metrics"
echo "       journalctl -u crowdsec -f"