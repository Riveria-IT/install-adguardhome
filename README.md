# AdGuard Home – Auto-Installer (Docker + Compose)

**Repo:** https://github.com/Riveria-IT/install-adguardhome

Dieses Skript installiert **AdGuard Home** auf Debian/Ubuntu (VM oder Proxmox‑LXC) in Docker, räumt **Port 53** frei, erzeugt eine Admin‑Konfiguration mit **BCrypt‑Passwort** und startet den Container sofort. Volumes liegen unter `/etc/docker/containers/adguardhome/{conf,work}` und werden im Container nach `/opt/adguardhome/{conf,work}` gemountet (offizielles Layout).

---

## 🚀 Quick Install (Einzeiler)

> Als `root` ausführen – oder vorne `sudo` ergänzen. Ersetze `main`, falls dein Default‑Branch anders heißt.

**curl**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Riveria-IT/install-adguardhome/main/install-adguardhome.sh)
```

**wget**
```bash
bash <(wget -qO- https://raw.githubusercontent.com/Riveria-IT/install-adguardhome/main/install-adguardhome.sh)
```

---

## ✅ Was das Skript macht

- Installiert **Docker** + **Compose‑Plugin** (falls nicht vorhanden)
- Gibt **Port 53** frei (deaktiviert `systemd-resolved` Stub‑Listener, stoppt ggf. dnsmasq/bind/unbound), damit AdGuard Home den DNS‑Port binden kann
- Schreibt `AdGuardHome.yaml` inkl. **BCrypt‑Passwort** und startet den Container
- Published: **TCP/UDP 53** (DNS) und **TCP 3000** (Web‑UI/Erst‑Setup)

**Web‑UI:** `http://<SERVER-IP>:3000`  
**Login:** `admin` / (beim Start ausgegebenes Passwort)

---

## 🔧 Anpassbare Umgebungsvariablen (optional)

Vor dem Einzeiler kannst du Variablen setzen, z. B. so:

```bash
AGH_ADMIN_USER=mike AGH_ADMIN_PASS='Dein!Pass#2025' UI_PORT=8080 DNS_PORT=53 \
bash <(curl -fsSL https://raw.githubusercontent.com/Riveria-IT/install-adguardhome/main/install-adguardhome.sh)
```

**Alle Variablen:**

| Variable | Default | Beschreibung |
|---|---|---|
| `AGH_DIR` | `/etc/docker/containers/adguardhome` | Daten-/Compose‑Pfad am Host |
| `AGH_IMAGE` | `adguard/adguardhome:latest` | Docker‑Image |
| `TZ_VAL` | `Europe/Zurich` | Zeitzone |
| `AGH_ADMIN_USER` | `admin` | Admin‑Benutzer |
| `AGH_ADMIN_PASS` | *(random)* | Admin‑Passwort (wenn leer, generiert das Skript eins) |
| `UI_ADDR` | `0.0.0.0` | Web‑UI Bind‑Adresse |
| `UI_PORT` | `3000` | Web‑UI Port |
| `DNS_BIND_HOSTS` | `0.0.0.0` | DNS Bind‑Adresse(n) |
| `DNS_PORT` | `53` | DNS Port (TCP/UDP) |
| `UPSTREAM_DNS_CSV` | `1.1.1.1,9.9.9.9` | Upstream‑Resolver |
| `BOOTSTRAP_DNS_CSV` | `9.9.9.10,149.112.112.10` | Bootstrap‑Resolver |

---

## 🛡️ OPNsense: Alle Clients über AdGuard Home filtern

Es gibt zwei Wege – du kannst auch **beide** kombinieren:

### 1) DNS per DHCP verteilen (empfohlen)

**Ziel:** Clients erhalten die IP von AdGuard Home als DNS‑Server via DHCP.

- **Services → DHCPv4 (oder aktiver DHCP‑Dienst) → [LAN/VLAN]**  
  Trage bei **DNS servers** die **AGH‑IP** ein (z. B. `192.168.1.10`). Speichern & Übernehmen.

*Tipp:* Unter **System → Settings → General** die Option **„Allow DNS server list to be overridden by DHCP/PPP on WAN“** **deaktivieren**, damit der ISP deine DNS‑Liste nicht überschreibt.

### 2) DNS‑Redirect erzwingen (NAT Port‑Forward)

**Ziel:** Jede ausgehende DNS‑Anfrage (Port 53) aus LAN/VLANs wird **zwangsumgeleitet** zu AdGuard Home – auch bei hartkodierten DNS (8.8.8.8 etc.).

1. **Firewall → NAT → Port Forward → „+“**  
2. Felder setzen (für jedes LAN/VLAN separat):
   - **Interface:** dein LAN/VLAN  
   - **TCP/IP Version:** IPv4 (oder IPv4+IPv6, wenn AGH auch v6 bedient)  
   - **Protocol:** **TCP/UDP**  
   - **Source:** any (oder dein LAN‑Netz)  
   - **Destination:** **any**  
   - **Destination Port:** **DNS (53)**  
   - **Redirect target IP:** **IP deines AGH‑Hosts** (z. B. `192.168.1.10`)  
   - **Redirect target port:** **53**  
   - **Filter rule association:** **Add associated filter rule**  
3. **Save** → **Apply**.

> Optional: **DoT/DoH erschweren** – blocke nach außen **TCP 853 (DoT)** per LAN‑Regel. DoH über 443 ist schwerer pauschal zu verhindern (hier ggf. SNI/Domain‑Listen verwenden).

### Optional: Kombination mit Unbound

Du kannst **Unbound** (OPNsense‑Resolver) beibehalten und als Upstream verwenden. In AdGuard Home Upstream auf `127.0.0.1:53` stellen (wenn Unbound lokal läuft) oder umgekehrt. Wichtig ist, dass **Clients letztlich AGH** als DNS nutzen.

---

## 🔄 Update, Logs & Uninstall

**Update**
```bash
docker compose -f /etc/docker/containers/adguardhome/docker-compose.yml pull \
 && docker compose -f /etc/docker/containers/adguardhome/docker-compose.yml up -d
```

**Logs**
```bash
docker compose -f /etc/docker/containers/adguardhome/docker-compose.yml logs -f
```

**Stoppen/Entfernen**
```bash
docker compose -f /etc/docker/containers/adguardhome/docker-compose.yml down
# (Optional) Daten löschen – ACHTUNG: entfernt auch Settings & Clients!
sudo rm -rf /etc/docker/containers/adguardhome
```

---

## 🧪 Troubleshooting

- **Web‑UI `:3000` nicht erreichbar**  
  Läuft der Container (`docker ps`)? Logs prüfen. Port 3000 im Host/Hypervisor freigegeben?
- **DNS antwortet nicht**  
  Lauscht AGH auf Port 53 (Container‑Logs)? Belegt ein anderer Dienst Port 53? (Das Skript schaltet `systemd-resolved` Stub‑Listener ab und stoppt gängige DNS‑Dienste.)
- **OPNsense‑Clients gehen an AGH vorbei**  
  DHCP verteilt **AGH‑IP** als DNS? NAT‑Redirect aktiv (für alle relevanten Interfaces/VLANs) und mit „Add associated filter rule“ verknüpft?
- **Login‑Probleme in AGH**  
  In `AdGuardHome.yaml` liegt ein **BCrypt‑Hash** in `users[].password`. Hash neu erzeugen (z. B. `htpasswd -B -C 12 -n -b USER PASS`) und Dienst neu starten.

---

## 🔗 Referenzen / weiterführend

- **AdGuard Home Docker / Volumes** – offizielle Hinweise:  
  https://github.com/AdguardTeam/AdGuardHome/wiki/Docker  
  https://hub.docker.com/r/adguard/adguardhome

- **Konfiguration & Passwort (BCrypt)** – offizielle Wiki:  
  https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration

- **OPNsense NAT / Port-Forward & verknüpfte Filterregeln** – Doku:  
  https://docs.opnsense.org/manual/nat.html

- **OPNsense System Settings → General** – Option „Allow DNS server list to be overridden…“:  
  (siehe Diskussion/Workarounds) https://github.com/opnsense/core/issues/6668

---

**Viel Erfolg!** Bei Bedarf liefere ich dir gern eine **Caddy/Traefik‑Konfiguration (TLS)** für die Web‑UI oder Beispiel‑Regeln für **IPv6‑DNS‑Redirects**.
