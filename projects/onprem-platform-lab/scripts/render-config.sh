#!/usr/bin/env bash
# Renders everything that contains a secret into ./generated (git-ignored):
#   LDAP users, Rundeck login and API token, the env file Rundeck jobs read, and WireGuard keys.
#   render-config.sh --generate   also creates .env with random passwords if it doesn't exist
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--generate" ] && [ ! -f .env ]; then
  while IFS='=' read -r key _; do
    case "$key" in ''|\#*) continue ;; esac
    echo "$key=$(openssl rand -hex 16)"
  done < .env.example > .env
  echo "created .env with random passwords"
fi
[ -f .env ] || { echo "no .env: copy .env.example or run with --generate" >&2; exit 1; }
set -a; . ./.env; set +a

umask 077
mkdir -p generated/ldap generated/rundeck generated/wireguard

sed -e "s|__ALICE_PASSWORD__|$ALICE_PASSWORD|" -e "s|__BOB_PASSWORD__|$BOB_PASSWORD|" \
  ldap/users.ldif.template > generated/ldap/50-users.ldif

echo "admin:$RUNDECK_ADMIN_PASSWORD,user,admin" > generated/rundeck/realm.properties
echo "admin: $RUNDECK_API_TOKEN,admin" > generated/rundeck/tokens.properties
printf 'MYSQL_MONITOR_PASSWORD=%s\nLDAP_READONLY_PASSWORD=%s\nES_URL=http://elasticsearch:9200\n' \
  "$MYSQL_MONITOR_PASSWORD" "$LDAP_READONLY_PASSWORD" > generated/rundeck/monitor.env

# WireGuard: one key pair per site, written into each gateway's wg0.conf
if [ ! -f generated/wireguard/dc.key ]; then
  for site in dc branch; do
    docker run --rm alpine:3.20 sh -c 'apk add -q --no-cache wireguard-tools >/dev/null && k=$(wg genkey) && echo "$k" && echo "$k" | wg pubkey' \
      > "generated/wireguard/$site.pair"
    sed -n 1p "generated/wireguard/$site.pair" > "generated/wireguard/$site.key"
    sed -n 2p "generated/wireguard/$site.pair" > "generated/wireguard/$site.pub"
    rm "generated/wireguard/$site.pair"
  done
fi
mkdir -p generated/wireguard/dc-gw generated/wireguard/branch-gw
cat > generated/wireguard/dc-gw/wg0.conf <<CONF
[Interface]
Address = 10.99.0.1/24
ListenPort = 51820
PrivateKey = $(cat generated/wireguard/dc.key)

[Peer]
# branch office
PublicKey = $(cat generated/wireguard/branch.pub)
AllowedIPs = 10.99.0.2/32
CONF
cat > generated/wireguard/branch-gw/wg0.conf <<CONF
[Interface]
Address = 10.99.0.2/24
PrivateKey = $(cat generated/wireguard/branch.key)

[Peer]
# Dublin data centre: the tunnel and the lab network behind it
PublicKey = $(cat generated/wireguard/dc.pub)
Endpoint = dc-gw:51820
AllowedIPs = 10.99.0.0/24, 172.30.10.0/24
PersistentKeepalive = 25
CONF

# containers read these as other users
chmod -R a+rX generated
echo "rendered config into generated/"
