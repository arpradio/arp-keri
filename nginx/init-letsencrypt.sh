#!/usr/bin/env bash
## One-time bootstrap for the nginx + certbot services in
## docker-compose.keri.prod.yml. Run this once (from a host with `docker
## compose` and this repo checked out) before the first `docker compose up`
## of the full stack, or whenever the cert volume is wiped.
##
## Why this exists: nginx/keria.conf's HTTPS server blocks reference
## certs at /etc/letsencrypt/live/keria.arpradio.media/ that don't exist
## until certbot has run once — but certbot's webroot method needs nginx
## already serving the ACME challenge path on port 80 to obtain them. This
## script breaks that chicken-and-egg loop the standard way: start nginx
## with dummy self-signed certs in place so it can boot, request the real
## certs through it, then reload nginx with the real ones.
##
## Adapted from the well-known certbot/nginx webroot bootstrap pattern
## (https://github.com/wmnnd/nginx-certbot).
##
## Usage:
##   cd infra
##   LETSENCRYPT_EMAIL=you@example.com ./nginx/init-letsencrypt.sh
##   LETSENCRYPT_STAGING=1 ./nginx/init-letsencrypt.sh   # test run, no rate limits, untrusted cert

set -euo pipefail

# Compose auto-loads .env for the containers it starts, but this script runs
# on the host directly, so pick up LETSENCRYPT_EMAIL (and anything else set
# there) the same way if the caller hasn't already exported it.
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

domains=(keria.arpradio.media keria-boot.arpradio.media keria-admin.arpradio.media)
cert_name="${domains[0]}"
rsa_key_size=4096
email="${LETSENCRYPT_EMAIL:-}"
staging="${LETSENCRYPT_STAGING:-0}"

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required on PATH." >&2
    exit 1
fi

compose() { docker compose -f docker-compose.keri.prod.yml "$@"; }

if [ -z "$email" ]; then
    echo "Set LETSENCRYPT_EMAIL to the address Let's Encrypt should use for expiry/abuse notices." >&2
    exit 1
fi

echo "### Downloading recommended TLS parameters ..."
compose run --rm --entrypoint sh certbot -c '
    set -e
    mkdir -p /etc/letsencrypt
    if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
        wget -q -O /etc/letsencrypt/options-ssl-nginx.conf https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf
    fi
    if [ ! -f /etc/letsencrypt/ssl-dhparam.pem ]; then
        wget -q -O /etc/letsencrypt/ssl-dhparam.pem https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem
    fi
'

echo "### Creating dummy certificate for $cert_name ..."
compose run --rm --entrypoint sh certbot -c "
    set -e
    mkdir -p /etc/letsencrypt/live/$cert_name
    openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1 \
        -keyout '/etc/letsencrypt/live/$cert_name/privkey.pem' \
        -out '/etc/letsencrypt/live/$cert_name/fullchain.pem' \
        -subj '/CN=localhost'
"

echo "### Starting nginx ..."
compose up -d nginx

echo "### Deleting dummy certificate for $cert_name ..."
compose run --rm --entrypoint sh certbot -c "rm -rf /etc/letsencrypt/live/$cert_name /etc/letsencrypt/archive/$cert_name /etc/letsencrypt/renewal/$cert_name.conf"

echo "### Requesting real certificate for ${domains[*]} ..."
domain_args=()
for d in "${domains[@]}"; do domain_args+=(-d "$d"); done

staging_arg=""
if [ "$staging" != "0" ]; then
    staging_arg="--staging"
fi

compose run --rm --entrypoint certbot certbot certonly \
    --webroot -w /var/www/certbot \
    "${domain_args[@]}" \
    --email "$email" \
    --rsa-key-size "$rsa_key_size" \
    --agree-tos \
    --no-eff-email \
    $staging_arg

echo "### Reloading nginx ..."
compose exec nginx nginx -s reload

echo "### Done. Certs live in the certbot-conf volume; the certbot service"
echo "### auto-renews on its own schedule (see the compose file)."
