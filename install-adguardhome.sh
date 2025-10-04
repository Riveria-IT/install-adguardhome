#!/usr/bin/env bash
# AdGuard Home – Vollautomatischer Installer (Docker + Compose)
# Ziel: Debian/Ubuntu (VM oder Proxmox-LXC)
# - Installiert Docker & Compose
# - Räumt Port 53 frei (systemd-resolved/dnsmasq/bind/unbound)
# - Erstellt Ordner & docker-compose.yml
# - Schreibt fertige AdGuardHome.yaml (mit bcrypt-Admin)
# - Startet Container
set -euo pipefail

############################
# Einstellungen (per ENV überschreibbar)
############################
AGH_DIR="${AGH_DIR:-/etc/docker/containers/adguardhome}"
AGH_IMAGE="${AGH_IMAGE:-adguard/adguardhome:latest}"
TZ_VAL="${TZ_VAL:-Europe/Zurich}"

# Admin – wenn Passwort leer, generieren wir eins
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASS="${AGH_ADMIN_PASS:-}"

# Web-UI & DNS
UI_ADDR="${UI_ADDR:-0.0.0.0}"
UI_PORT="${UI_PORT:-3000}"           # AdGuard UI/Wizard-Port
DNS_BIND_HOSTS="${DNS_BIND_HOSTS:-0.0.0.0}"
DNS_PORT="${DNS_PORT:-53}"

# Upstreams (später im UI änderbar)
UPSTREAM_DNS_CSV="${UPSTREAM_DNS_CSV:-1.1.1.1,9.9.9.9}"
BOOTSTRAP_DNS_CSV="${BOOTSTRAP_DNS_CSV:-9.9.9.10,149.112.112.10}"

############################
# Helpers
############################
say(){ echo -e "\033[36m[i]\033[0m $*"; }
ok(){  echo -e "\033[32m[✓]\033[0m $*"; }
err(){ echo -e "\033[31m[x]\033[0m $*"; }
need_root(){ [[ $EUID -eq 0 ]] || { err "Bitte als root ausführen."; exit 1; }; }
port_in_use(){ ss -ltnup 2>/dev/null | grep -qE ":(^|:)${1}\b" || ss -lunp 2>/dev/null | grep -qE ":(^|:)${1}\b"; }

############################
# Vorbereitungen
############################
need_root
say "Pakete vorbereiten …"
apt-get update -y
apt-get install -y curl ca-certificates gnupg lsb-release iproute2 apache2-utils

# Passwort ggf. generieren
if [[ -z "$AGH_ADMIN_PASS" ]]; then
  AGH_ADMIN_PASS="$(tr -dc 'A-Za-z0-9!@#%^+=' </dev/urandom | head -c 20)"
  GENPASS_INFO="true"
else
  GENPASS_INFO="false"
fi

say "Docker installieren/prüfen …"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
apt-get install -y docker-compose-plugin || true
systemctl enable --now docker

if docker compose version >/dev/null 2>&1; then
  DCMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DCMD="docker-compose"
else
  err "Weder 'docker compose' noch 'docker-compose' verfügbar."
  exit 1
fi
ok "Docker bereit: $($DCMD version | head -n1 || echo compose)"

############################
# Port 53 freiräumen
############################
say "Prüfe Port ${DNS_PORT} …"
if port_in_use "${DNS_PORT}"; then
  say "Deaktiviere ggf. systemd-resolved Stub-Listener …"
  mkdir -p /etc/systemd/resolved.conf.d
  cat >/etc/systemd/resolved.conf.d/adguardhome.conf <<EOF
[Resolve]
DNS=1.1.1.1 9.9.9.9
DNSStubListener=no
EOF
  systemctl reload-or-restart systemd-resolved || true

  # resolv.conf absichern (127.0.0.53 entfernen)
  if [ -L /etc/resolv.conf ] || grep -qi '127.0.0.53' /etc/resolv.conf 2>/dev/null; then
    say "Setze /etc/resolv.conf auf externe Resolver …"
    cat >/etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 9.9.9.9
options edns0 trust-ad
EOF
  fi
  sleep 1
fi

# Weitere DNS-Dienste stoppen
if port_in_use "${DNS_PORT}"; then
  for svc in dnsmasq named bind9 unbound; do
    if systemctl is-active --quiet "$svc"; then
      say "Stoppe Dienst: $svc"
      systemctl stop "$svc" || true
      systemctl disable "$svc" || true
    fi
  done
  sleep 1
fi

if port_in_use "${DNS_PORT}"; then
  err "Port ${DNS_PORT} ist weiterhin belegt. Bitte manuell freigeben und Script erneut ausführen."
  ss -ltnup || true
  exit 1
fi
ok "Port ${DNS_PORT} ist frei."

############################
# Verzeichnisse
############################
say "Ordner anlegen …"
mkdir -p "${AGH_DIR}/conf" "${AGH_DIR}/work"
ok "Pfad: ${AGH_DIR}"

############################
# BCrypt-Hash für Admin
############################
say "Erzeuge BCrypt-Hash …"
HASH_LINE="$(htpasswd -nbBC 12 "${AGH_ADMIN_USER}" "${AGH_ADMIN_PASS}")"  # -> user:hash
AGH_PASS_HASH="${HASH_LINE#*:}"

############################
# AdGuardHome.yaml schreiben
############################
say "Schreibe AdGuardHome.yaml …"
IFS=',' read -r -a UPS_ARR <<< "$UPSTREAM_DNS_CSV"
IFS=',' read -r -a BOOT_ARR <<< "$BOOTSTRAP_DNS_CSV"

CFG="${AGH_DIR}/conf/AdGuardHome.yaml"
{
  echo "bind_host: ${UI_ADDR}"
  echo "bind_port: ${UI_PORT}"
  echo "beta_bind_port: 0"
  echo "users:"
  echo "  - name: ${AGH_ADMIN_USER}"
  echo "    password: '${AGH_PASS_HASH}'"
  echo "http:"
  echo "  address: ${UI_ADDR}:${UI_PORT}"
  echo "  session_ttl: 720h"
  echo "dns:"
  echo "  bind_hosts:"
  echo "    - ${DNS_BIND_HOSTS}"
  echo "  port: ${DNS_PORT}"
  echo "  upstream_dns:"
  for x in "${UPS_ARR[@]}"; do
    echo "    - ${x}"
  done
  echo "  bootstrap_dns:"
  for x in "${BOOT_ARR[@]}"; do
    echo "    - ${x}"
  done
  echo "  protection_enabled: true"
  echo "querylog_enabled: true"
  echo "statistics_interval: 1"
  echo "rlimit_nofile: 8192"
  echo "os:"
  echo "  group: \"\""
  echo "  user: \"\""
} > "$CFG"

############################
# docker-compose.yml schreiben
############################
say "Schreibe docker-compose.yml …"
COMPOSE="${AGH_DIR}/docker-compose.yml"
cat >"$COMPOSE" <<EOF
services:
  adguardhome:
    image: ${AGH_IMAGE}
    container_name: adguardhome
    environment:
      - TZ=${TZ_VAL}
    volumes:
      - ./conf:/opt/adguardhome/conf
      - ./work:/opt/adguardhome/work
    ports:
      - "${UI_PORT}:3000/tcp"       # Web UI/Wizard
      - "${DNS_PORT}:53/tcp"        # DNS TCP
      - "${DNS_PORT}:53/udp"        # DNS UDP
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
EOF

############################
# Start
############################
say "Starte AdGuard Home …"
cd "$AGH_DIR"
$DCMD up -d
ok "AdGuard Home läuft."

echo
say "Zugriff:"
echo "  Web-UI:  http://<Server-IP>:${UI_PORT}"
echo "  Login:   ${AGH_ADMIN_USER} / ${AGH_ADMIN_PASS}"
[[ "$GENPASS_INFO" == "true" ]] && echo "  (Passwort wurde generiert – bitte sicher notieren!)"
echo
say "DNS nutzen:"
echo "  Setze deine Clients/Router auf DNS: <Server-IP> Port ${DNS_PORT}"
echo
ok "Update:"
echo "  $DCMD -f ${AGH_DIR}/docker-compose.yml pull && \\"
echo "  $DCMD -f ${AGH_DIR}/docker-compose.yml up -d"
echo
ok "Logs:"
echo "  $DCMD -f ${AGH_DIR}/docker-compose.yml logs -f"
