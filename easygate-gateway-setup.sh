#!/usr/bin/env bash
# =============================================================================
# EasyGate - Gateway setup (Ubuntu Server 26.04 LTS, single network interface)
#
# Installs WireGuard, creates the outbound tunnel to the EasyGate server,
# applies the gateway firewall + NAT, and creates the 'easyadmin' account that
# the server may use (over the tunnel only) to manage this gateway.
#
# Safe to run again: the WireGuard private key is kept, everything else is
# rewritten from the parameters.
#
# Usage (as root):
#   sudo bash easygate-gateway-setup.sh \
#        --server-pubkey <server WireGuard public key for this customer> \
#        [--server easygate.easytech.com.cy] [--tenant 1] [--port 51001] \
#        [--approved "192.168.1.0/24 10.10.0.0/16"] \
#        --admin-key "ssh-ed25519 AAAA... easygate-portal" \
#        [--mgmt-from "10.0.0.0/24"] [--hostname easygate-gw-cust1] \
#        [--no-mgmt-ssh] [--restart-after 180] [--tcp-port 443]
#
# --restart-after: restart the tunnel when the server has not answered for this
# many seconds (90-3600, default 180; 0 = never). See section 8.
# --tcp-port: TCP 443 fallback for sites that block UDP (default 443; 0 = off on
# this gateway). Whether it may be used is decided on the server. See section 8a.
#
# At the end it prints an ENROLLMENT CODE (EG1....) to paste into the portal:
# it carries the gateway WireGuard key, site IP, LAN and the SSH host key.
# =============================================================================
set -euo pipefail
VERSION="0.4.3"   # = the EasyGate server version (same number in both repositories)

# ---- Defaults ---------------------------------------------------------------
TENANT_ID=1
RESTART_AFTER=180
TCP_PORT=443
TCP_LOCAL=51820   # easygate-tcp listens on 127.0.0.1:$TCP_LOCAL (UDP) for wg0 (section 8a)
PORT=""
SERVER="easygate.easytech.com.cy"
SERVER_ADDR=""
SERVER_PUBKEY=""
APPROVED=""
MGMT_FROM=""
NEW_HOSTNAME=""
MGMT_SSH=yes
ADMIN_USER="easyadmin"
# File services for network devices (section 8b): TFTP / HTTP root, and the SFTP / SCP account locked into its jail
FILES_ROOT="/srv/easygate-files"
FILES_JAIL="/srv/easygate-sftp"
FILES_USER="files"
# Public key(s) allowed to log in as $ADMIN_USER over the tunnel: the EasyGate portal's own
# management key, given by the portal with --admin-key (no key is built into the script).
ADMIN_KEYS=()

log()  { printf '\e[1;34m[easygate]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warning]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[error]\e[0m %s\n' "$*" >&2; exit 1; }

# File helpers. Ubuntu 26.04 ships the Rust coreutils (uutils), whose "install" cannot read
# /dev/stdin on some versions ("install: No such file or directory"), so files are written
# with plain shell redirection instead.
put() {   # put <mode> <file> [owner:group]  - writes stdin to <file> atomically
  local tmp
  tmp=$(mktemp "$(dirname "$2")/.easygate.XXXXXX")   # created mode 600
  cat > "$tmp"
  chmod "$1" "$tmp"
  if [[ -n "${3:-}" ]]; then chown "$3" "$tmp"; fi
  mv -f "$tmp" "$2"
}
mkd() {   # mkd <mode> <dir> [owner:group]
  mkdir -p "$2"
  chmod "$1" "$2"
  if [[ -n "${3:-}" ]]; then chown "$3" "$2"; fi
}

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# ---- Arguments --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)         SERVER="${2:-}"; shift 2 ;;
    --server-pubkey)  SERVER_PUBKEY="${2:-}"; shift 2 ;;
    --tenant)         TENANT_ID="${2:-}"; shift 2 ;;
    --port)           PORT="${2:-}"; shift 2 ;;
    --approved)       APPROVED="${2:-}"; shift 2 ;;
    --mgmt-from)      MGMT_FROM="${2:-}"; shift 2 ;;
    --hostname)       NEW_HOSTNAME="${2:-}"; shift 2 ;;
    --admin-key)      ADMIN_KEYS+=("${2:-}"); shift 2 ;;
    --no-mgmt-ssh)    MGMT_SSH=no; shift ;;
    --restart-after)  RESTART_AFTER="${2:-}"; shift 2 ;;
    --tcp-port)       TCP_PORT="${2:-}"; shift 2 ;;
    -h|--help)        usage ;;
    *)                die "unknown option: $1 (use --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root (sudo bash $0 ...)"
[[ -n "$SERVER" && -n "$SERVER_PUBKEY" ]] || usage
log "easygate-gateway-setup v${VERSION}"

# ---- Validation -------------------------------------------------------------
is_cidr() {
  python3 - "$1" <<'PY' 2>/dev/null
import ipaddress, sys
n = ipaddress.ip_network(sys.argv[1], strict=True)
sys.exit(0 if n.version == 4 else 1)
PY
}
in_net() {  # in_net <ip> <cidr>
  python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2]) else 1)' "$1" "$2" 2>/dev/null
}

[[ "$TENANT_ID" =~ ^[0-9]{1,3}$ ]] && (( TENANT_ID >= 1 && TENANT_ID <= 254 )) || die "--tenant must be 1-254"
[[ -n "$PORT" ]] || PORT=$((51000 + TENANT_ID))
[[ "$PORT" =~ ^[0-9]{4,5}$ ]] && (( PORT >= 1024 && PORT <= 65535 )) || die "--port invalid"
[[ "$SERVER" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || die "--server must be an IPv4 address or DNS name"
if [[ ! "$SERVER" =~ ^[0-9.]+$ ]]; then
  SERVER_ADDR=$(getent ahostsv4 "$SERVER" | awk 'NR==1{print $1}')
  [[ -n "$SERVER_ADDR" ]] || die "cannot resolve $SERVER - check DNS (the name needs an A record)"
fi
[[ "$SERVER_PUBKEY" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$ ]] || die "--server-pubkey is not a WireGuard public key"
[[ "$RESTART_AFTER" =~ ^[0-9]{1,4}$ ]] && (( RESTART_AFTER == 0 || (RESTART_AFTER >= 90 && RESTART_AFTER <= 3600) )) \
  || die "--restart-after must be 0 (never) or 90-3600 seconds"
[[ "$TCP_PORT" =~ ^[0-9]{1,5}$ ]] && (( TCP_PORT <= 65535 )) || die "--tcp-port must be 0 (off) or 1-65535"
[[ -z "$NEW_HOSTNAME" || "$NEW_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "--hostname invalid"
for k in "${ADMIN_KEYS[@]}"; do
  [[ "$k" =~ ^ssh-ed25519\ [A-Za-z0-9+/]{68}(\ [A-Za-z0-9@._-]{1,64})?$ ]] || die "--admin-key is not an ssh-ed25519 public key"
done
if [[ "$MGMT_SSH" == yes && ${#ADMIN_KEYS[@]} -eq 0 ]]; then
  die "--admin-key is required (copy the full command from the EasyGate portal), or use --no-mgmt-ssh"
fi
command -v python3 >/dev/null || die "python3 is required (installed by default on Ubuntu Server)"

SERVER_TUN="100.96.${TENANT_ID}.1"
GW_TUN="100.96.${TENANT_ID}.2"

# ---- Detect the single LAN interface ----------------------------------------
LAN_IF=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[[ -n "$LAN_IF" ]] || die "no default route found - configure the network first"
LAN_NET=$(ip -4 route show dev "$LAN_IF" scope link proto kernel | awk 'NR==1{print $1}')
GW_IP=$(ip -4 -o addr show dev "$LAN_IF" | awk 'NR==1{split($4,a,"/"); print a[1]}')
DEF_ROUTER=$(ip -4 route show default | awk 'NR==1{print $3}')
[[ -n "$LAN_NET" && -n "$GW_IP" ]] || die "could not detect LAN subnet/IP on $LAN_IF"
if ip -4 -o addr show dev "$LAN_IF" | grep -q dynamic; then
  warn "$LAN_IF uses DHCP ($GW_IP). Use a DHCP reservation or a static IP so the gateway address never changes."
fi

[[ -n "$APPROVED" ]] || APPROVED="$LAN_NET"
for n in $APPROVED; do
  is_cidr "$n" || die "--approved: '$n' is not a valid IPv4 network (e.g. 192.168.1.0/24)"
  [[ "${n#*/}" -ge 8 ]] || die "--approved: '$n' is too broad (the gateway must never be an internet exit)"
done

# Management sources = LAN subnet + optional extras + the current SSH client (to avoid lock-out)
MGMT_SRCS="$LAN_NET"
for n in $MGMT_FROM; do
  is_cidr "$n" || die "--mgmt-from: '$n' is not a valid IPv4 network"
  MGMT_SRCS="$MGMT_SRCS $n"
done
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  CLIENT_IP="${SSH_CONNECTION%% *}"
  if [[ "$CLIENT_IP" =~ ^[0-9.]+$ ]] && ! in_net "$CLIENT_IP" "$LAN_NET"; then
    warn "your SSH session comes from $CLIENT_IP (outside $LAN_NET) - adding it to management sources"
    MGMT_SRCS="$MGMT_SRCS $CLIENT_IP/32"
  fi
fi

log "Interface:        $LAN_IF ($GW_IP, LAN $LAN_NET, router $DEF_ROUTER)"
log "Server endpoint:  $SERVER:$PORT ${SERVER_ADDR:+($SERVER_ADDR) }(tenant $TENANT_ID, tunnel $GW_TUN -> $SERVER_TUN)"
log "Approved subnets: $APPROVED"
log "Local management: $MGMT_SRCS"
log "Mgmt SSH via VPN: $MGMT_SSH"
log "TCP fallback:     $( (( TCP_PORT > 0 )) && echo "$SERVER:$TCP_PORT when UDP is blocked (if the server allows it)" || echo "off (--tcp-port 0)")"

# ---- 1. Packages ------------------------------------------------------------
log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q wireguard-tools nftables openssh-server curl unattended-upgrades tftpd-hpa
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
# file services are started only from the portal (section 8b): never at boot
systemctl disable --now tftpd-hpa >/dev/null 2>&1 || true

[[ -n "$NEW_HOSTNAME" ]] && hostnamectl set-hostname "$NEW_HOSTNAME"

# ---- 2. Admin account (key only, no password) -------------------------------
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  log "Creating user $ADMIN_USER..."
  adduser --disabled-password --comment "EasyGate admin" "$ADMIN_USER" >/dev/null
fi
usermod -aG sudo "$ADMIN_USER"
printf '%s\n' "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" | put 440 "/etc/sudoers.d/90-$ADMIN_USER"
mkd 700 "/home/$ADMIN_USER/.ssh" "$ADMIN_USER:$ADMIN_USER"
# Replaces any key from an older installer: only the keys given now may log in.
printf '%s\n' "${ADMIN_KEYS[@]}" | put 600 "/home/$ADMIN_USER/.ssh/authorized_keys" "$ADMIN_USER:$ADMIN_USER"
printf '%s\n' "$VERSION" | put 644 /etc/easygate-gateway.version

# ---- 3. WireGuard key (generated here, never leaves this machine) -----------
mkd 700 /etc/wireguard
if [[ ! -s /etc/wireguard/gw.key ]]; then
  log "Generating WireGuard key pair..."
  (umask 077; wg genkey > /etc/wireguard/gw.key)
fi
wg pubkey < /etc/wireguard/gw.key > /etc/wireguard/gw.pub
chmod 600 /etc/wireguard/gw.key; chmod 644 /etc/wireguard/gw.pub
GW_PUBKEY=$(cat /etc/wireguard/gw.pub)

# ---- 4. Tunnel configuration ------------------------------------------------
log "Writing /etc/wireguard/wg0.conf..."
put 600 /etc/wireguard/wg0.conf <<EOF
# EasyGate tunnel - generated $(date -Is) by easygate-gateway-setup.sh
[Interface]
Address = ${GW_TUN}/30
PostUp = wg set %i private-key /etc/wireguard/gw.key
MTU = 1420

[Peer]
# EasyGate server, tenant ${TENANT_ID}
PublicKey = ${SERVER_PUBKEY}
Endpoint = ${SERVER}:${PORT}
# Only the server tunnel IP: the customer LAN is never routed into the tunnel.
AllowedIPs = ${SERVER_TUN}/32
PersistentKeepalive = 25
EOF

# ---- 5. Kernel settings -----------------------------------------------------
put 644 /etc/sysctl.d/90-easygate.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.forwarding = 0
EOF
sysctl --system >/dev/null

# ---- 6. Firewall + NAT ------------------------------------------------------
join() { local IFS=", "; echo "$*"; }
# shellcheck disable=SC2086
APPROVED_ELEMS=$(join $APPROVED)
# shellcheck disable=SC2086
MGMT_ELEMS=$(join $MGMT_SRCS)

MGMT_TUNNEL_RULE="# management SSH over the tunnel disabled (--no-mgmt-ssh)"
if [[ "$MGMT_SSH" == yes ]]; then
  MGMT_TUNNEL_RULE="iifname \"wg0\" ip saddr \$SERVER_TUN ip daddr \$GW_TUN tcp dport 22 accept   # server management only"
fi

log "Writing /etc/nftables.conf..."
cat > /etc/nftables.conf.new <<EOF
#!/usr/sbin/nft -f
# EasyGate gateway firewall - generated $(date -Is) by easygate-gateway-setup.sh
flush ruleset

define LAN_IF     = "${LAN_IF}"
define SERVER_TUN = ${SERVER_TUN}
define GW_TUN     = ${GW_TUN}

table inet easygate {
  # Destinations the server may reach. Never 0.0.0.0/0 (no internet exit).
  set approved  { type ipv4_addr; flags interval; elements = { ${APPROVED_ELEMS} } }
  # Sources allowed to manage the gateway locally (SSH / web UI)
  set mgmt_src  { type ipv4_addr; flags interval; elements = { ${MGMT_ELEMS} } }

  chain input {
    type filter hook input priority filter; policy drop;
    iif lo accept
    ct state invalid drop
    ct state established,related accept
    iifname "wg0" icmp type echo-request accept
    ${MGMT_TUNNEL_RULE}
    iifname "wg0" limit rate 6/minute log prefix "easygate-in-deny: " drop
    iifname \$LAN_IF ip saddr @mgmt_src tcp dport { 22, 443 } accept
    iifname \$LAN_IF ip saddr @mgmt_src icmp type echo-request accept
    iifname \$LAN_IF udp sport 67 udp dport 68 accept              # DHCP replies
    iifname \$LAN_IF jump files_in                                 # file services, only while started (section 8b)
  }

  # Filled by easygate-files start (TFTP / HTTP / SFTP-SCP ports) and emptied by stop. Empty after every boot.
  chain files_in {
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
    ct state invalid drop
    ct state established,related accept
    iifname "wg0" oifname \$LAN_IF ip saddr \$SERVER_TUN ip daddr @approved accept
    iifname "wg0" limit rate 6/minute log prefix "easygate-fwd-deny: " drop
  }

  chain output { type filter hook output priority filter; policy accept; }
}

table ip easygate_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat;
    oifname \$LAN_IF ip saddr \$SERVER_TUN masquerade   # LAN devices see the gateway IP
  }
}
EOF
nft -c -f /etc/nftables.conf.new || die "firewall rules failed validation - nothing applied"
[[ -f /etc/nftables.conf && ! -f /etc/nftables.conf.pre-easygate ]] && cp -a /etc/nftables.conf /etc/nftables.conf.pre-easygate
mv /etc/nftables.conf.new /etc/nftables.conf
chmod 600 /etc/nftables.conf
systemctl enable nftables >/dev/null 2>&1
nft -f /etc/nftables.conf
log "Firewall applied."

# ---- 7. SSH: who may log in from where --------------------------------------
# LAN / management sources: any local user. Over the tunnel: only $ADMIN_USER from the server.
ALLOW=""
for n in $MGMT_SRCS; do ALLOW="$ALLOW *@$n"; done
[[ "$MGMT_SSH" == yes ]] && ALLOW="$ALLOW ${ADMIN_USER}@${SERVER_TUN}"
# the file-services account (section 8b): locked except while the portal has started SFTP / SCP
ALLOW="$ALLOW ${FILES_USER}"
put 644 /etc/ssh/sshd_config.d/80-easygate.conf <<EOF
# EasyGate - generated by easygate-gateway-setup.sh
PermitRootLogin no
X11Forwarding no
AllowUsers${ALLOW}
EOF
# SFTP / SCP for network devices: the '${FILES_USER}' account is locked into ${FILES_JAIL} (password set by the portal at
# each start). Its own file, ending with "Match all": a Match block would otherwise swallow the lines after it.
put 644 /etc/ssh/sshd_config.d/85-easygate-files.conf <<EOF
# EasyGate file services - generated by easygate-gateway-setup.sh
Match User ${FILES_USER}
    ChrootDirectory ${FILES_JAIL}
    PasswordAuthentication yes
    PubkeyAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    PermitTunnel no
    PermitTTY no
    X11Forwarding no
Match all
EOF
sshd -t || { rm -f /etc/ssh/sshd_config.d/80-easygate.conf /etc/ssh/sshd_config.d/85-easygate-files.conf; die "sshd config invalid - reverted"; }
systemctl restart ssh

# ---- 8. Resilience: boot retry + DNS re-resolve -----------------------------
# wg-quick resolves the server name only once. If DNS is not ready at boot it fails,
# and if the server IP changes later the tunnel would stay on the old address.
mkd 755 /etc/systemd/system/wg-quick@wg0.service.d
put 644 /etc/systemd/system/wg-quick@wg0.service.d/easygate.conf <<'EOF'
[Unit]
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=30
EOF

# Tunnel watchdog (replaces the re-resolve timer of installers up to v0.2.4).
systemctl disable --now easygate-reresolve.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/easygate-reresolve.timer /etc/systemd/system/easygate-reresolve.service /usr/local/sbin/easygate-reresolve

put 755 /usr/local/sbin/easygate-watchdog <<'EOF'
#!/usr/bin/env bash
# EasyGate tunnel watchdog (run every 30 s by easygate-watchdog.timer).
#  - No handshake for > 135 s: re-resolve the server name (its IP may have changed).
#  - No handshake for > RESTART_AFTER s: restart the tunnel. It comes back on a new UDP source port,
#    so every firewall on the way builds a fresh session; a stale firewall session can otherwise
#    block the old port for good. If a restart does not help, the wait doubles (up to 30 min).
#  - TCP 443 fallback (installer v0.4.0, TCP_PORT > 0), for sites that block UDP:
#      UDP silent for > 150 s     -> start easygate-tcp and point wg0 at it (127.0.0.1:TCP_LOCAL), no restart
#      TCP silent for > 150 s     -> back to UDP (the server may refuse the fallback, or TCP is blocked too); TCP is
#                                    not tried again for 30 min (doubling up to 4 h), so UDP restarts get their turn
#      on TCP for 30 min          -> check UDP: stop easygate-tcp (so nothing pulls wg0 back to it), point wg0 at the
#                                    server's UDP port with a fresh session (v0.4.2: peer removed and loaded again, so a
#                                    NEW handshake must complete over UDP) and ask the server's time over the tunnel
#                                    (UDP 123 to .1, allowed by the server). An answer and a new handshake = UDP works:
#                                    stay on it. Otherwise within ~12 s back to TCP; the next check waits twice as long
#                                    (up to 4 h).
# Every restart is counted in /var/lib/easygate-gateway/watchdog.state, which the portal reads.
set -euo pipefail
IF=wg0; CONF=/etc/wireguard/wg0.conf; UNIT=wg-quick@wg0; TCP_UNIT=easygate-tcp
STATE_DIR=/var/lib/easygate-gateway; STATE=$STATE_DIR/watchdog.state
RESTART_AFTER=${RESTART_AFTER:-180}; MAX_WAIT=1800
TCP_PORT=${TCP_PORT:-0}; TCP_LOCAL=${TCP_LOCAL:-51820}
FALLBACK_AFTER=150; PROBE_EVERY=1800; BACKOFF_MAX=14400
[[ "$RESTART_AFTER" =~ ^[0-9]{1,4}$ ]] || RESTART_AFTER=180
[[ "$TCP_PORT" =~ ^[0-9]{1,5}$ ]] || TCP_PORT=0
[[ "$TCP_LOCAL" =~ ^[0-9]{4,5}$ ]] || TCP_LOCAL=51820
RELAY="127.0.0.1:${TCP_LOCAL}"
[[ -f "$CONF" ]] || exit 0
ip link show "$IF" >/dev/null 2>&1 || exit 0            # down or failed: systemd retries wg-quick itself
systemctl is-active --quiet easygate-upgrade && exit 0   # an installer run restarts the tunnel itself

restarts=0; last_restart=0; last_reason=""; last_silence=0; fails=0
transport=udp; switched=0; fallbacks=0; probe_fails=0; tcp_fails=0; tcp_retry_at=0
if [[ -r "$STATE" ]]; then
  while IFS='=' read -r k v; do
    case "$k" in
      restarts)     if [[ "$v" =~ ^[0-9]{1,9}$ ]]; then restarts=$v; fi ;;
      last_restart) if [[ "$v" =~ ^[0-9]{1,12}$ ]]; then last_restart=$v; fi ;;
      last_reason)  if [[ "$v" =~ ^[a-z-]{1,40}$ ]]; then last_reason=$v; fi ;;
      last_silence) if [[ "$v" =~ ^[0-9]{1,9}$ ]]; then last_silence=$v; fi ;;
      fails)        if [[ "$v" =~ ^[0-9]{1,3}$ ]]; then fails=$v; fi ;;
      transport)    if [[ "$v" == udp || "$v" == tcp ]]; then transport=$v; fi ;;
      switched)     if [[ "$v" =~ ^[0-9]{1,12}$ ]]; then switched=$v; fi ;;
      fallbacks)    if [[ "$v" =~ ^[0-9]{1,9}$ ]]; then fallbacks=$v; fi ;;
      probe_fails)  if [[ "$v" =~ ^[0-9]{1,3}$ ]]; then probe_fails=$v; fi ;;
      tcp_fails)    if [[ "$v" =~ ^[0-9]{1,3}$ ]]; then tcp_fails=$v; fi ;;
      tcp_retry_at) if [[ "$v" =~ ^[0-9]{1,12}$ ]]; then tcp_retry_at=$v; fi ;;
    esac
  done < "$STATE"
fi
save() {
  mkdir -p "$STATE_DIR"; chmod 755 "$STATE_DIR"
  local tmp; tmp=$(mktemp "$STATE_DIR/.watchdog.XXXXXX")
  printf 'restarts=%s\nlast_restart=%s\nlast_reason=%s\nlast_silence=%s\nfails=%s\ntransport=%s\nswitched=%s\nfallbacks=%s\nprobe_fails=%s\ntcp_fails=%s\ntcp_retry_at=%s\n' \
    "$restarts" "$last_restart" "$last_reason" "$last_silence" "$fails" "$transport" "$switched" "$fallbacks" \
    "$probe_fails" "$tcp_fails" "$tcp_retry_at" > "$tmp"
  chmod 644 "$tmp"; mv -f "$tmp" "$STATE"
}
[[ -f "$STATE" ]] || save

# (keys end in '=', so strip the "Name = " prefix instead of splitting on '=')
PEER=$(awk '/^PublicKey[ \t]*=/{sub(/^PublicKey[ \t]*=[ \t]*/,""); print; exit}' "$CONF")
ENDPOINT=$(awk '/^Endpoint[ \t]*=/{sub(/^Endpoint[ \t]*=[ \t]*/,""); print; exit}' "$CONF")
[[ -n "$PEER" && -n "$ENDPOINT" ]] || exit 0
NOW=$(date +%s)
LAST=$(wg show "$IF" latest-handshakes 2>/dev/null | awk -v p="$PEER" '$1==p{print $2}' || true)
[[ "$LAST" =~ ^[0-9]{1,12}$ ]] || LAST=0
# When the tunnel (re)started: counts as the start of the silence if there was no handshake since.
STARTED=$(systemctl show --timestamp=unix -P ActiveEnterTimestamp "$UNIT" 2>/dev/null | tr -dc '0-9' || true)
[[ "$STARTED" =~ ^[0-9]{1,12}$ ]] && (( STARTED > 0 )) || STARTED=$NOW

# A handshake after the last restart: the tunnel works, forget earlier failed attempts.
if (( LAST > last_restart && fails > 0 )); then fails=0; save; fi

REF=$(( LAST > STARTED ? LAST : STARTED ))
SILENCE=$(( NOW - REF ))

# ---- TCP 443 fallback ----
CUR=$(wg show "$IF" endpoints 2>/dev/null | awk -v p="$PEER" '$1==p{print $2}' || true)
to_udp() {   # wg0 back to the server's UDP endpoint (re-resolves the name); the TCP client stops
  systemctl stop "$TCP_UNIT" >/dev/null 2>&1 || true
  wg set "$IF" peer "$PEER" endpoint "$ENDPOINT" 2>/dev/null || true
  transport=udp; switched=$NOW; save
}
to_tcp() {
  systemctl start "$TCP_UNIT" >/dev/null 2>&1 || { logger -t easygate-watchdog "TCP fallback: easygate-tcp did not start"; return 1; }
  sleep 2   # the client connects first, so wg0's next packets find it
  wg set "$IF" peer "$PEER" endpoint "$RELAY"
  transport=tcp; switched=$NOW; save
}
backoff() {   # $1 = failures so far: 30 min, doubling, up to 4 h
  local w=$PROBE_EVERY i
  for (( i = 1; i < $1 && w < BACKOFF_MAX; i++ )); do w=$(( w * 2 )); done
  echo $(( w > BACKOFF_MAX ? BACKOFF_MAX : w ))
}
# The server's tunnel address (.1 next to the gateway's .2) answers time queries from the gateway (UDP 123).
GW_ADDR=$(awk '/^Address[ \t]*=/{sub(/^Address[ \t]*=[ \t]*/,""); sub(/\/.*/,""); print; exit}' "$CONF")
SRV_TUN=""
if [[ "$GW_ADDR" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\.([0-9]{1,3})$ ]] && (( BASH_REMATCH[2] > 0 )); then
  SRV_TUN="${BASH_REMATCH[1]}.$(( BASH_REMATCH[2] - 1 ))"
fi
server_answers() {   # one NTP request through the tunnel, up to 4 tries of 3 s: 0 = the server answered
  [[ -n "$SRV_TUN" ]] || return 1
  python3 -I - "$SRV_TUN" >/dev/null 2>&1 <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
for _ in range(4):
    try:
        s.sendto(b"\x1b" + bytes(47), (sys.argv[1], 123)); s.recvfrom(512); sys.exit(0)
    except OSError:
        pass
sys.exit(1)
PY
}
if [[ "$CUR" != "$RELAY" && $transport == tcp ]]; then
  if (( STARTED > switched )); then
    # the tunnel restarted (boot, installer, restart below): wg0 is on UDP again
    systemctl stop "$TCP_UNIT" >/dev/null 2>&1 || true
    transport=udp; switched=$NOW; save
  else
    # (v0.4.3) Not restarted: a packet from the server came in over UDP and WireGuard moved the endpoint to it (roaming).
    # One stray packet does not mean UDP works (the handshake reply may still be blocked): back to the TCP client.
    logger -t easygate-watchdog "the tunnel endpoint moved off the TCP fallback to ${CUR:-none} (a packet from the server came in over UDP): pointing it back to TCP"
    systemctl start "$TCP_UNIT" >/dev/null 2>&1 || true
    wg set "$IF" peer "$PEER" endpoint "$RELAY" 2>/dev/null || true
    CUR=$RELAY
  fi
fi
if (( TCP_PORT > 0 )); then
  MODE_REF=$(( REF > switched ? REF : switched ))
  MODE_SILENCE=$(( NOW - MODE_REF ))
  if [[ $transport == tcp ]]; then
    # a handshake over TCP: the fallback works, forget earlier TCP failures
    if (( LAST > switched && tcp_fails > 0 )); then tcp_fails=0; tcp_retry_at=0; save; fi
    if (( MODE_SILENCE > FALLBACK_AFTER )); then
      tcp_fails=$(( tcp_fails + 1 )); tcp_retry_at=$(( NOW + $(backoff "$tcp_fails") ))
      logger -t easygate-watchdog "no reply over the TCP fallback for ${MODE_SILENCE}s either (the server may not allow it): back to UDP, TCP not tried again for $(( tcp_retry_at - NOW ))s"
      to_udp   # then the restart rules below, as for UDP
    elif (( NOW - switched >= $(backoff $(( probe_fails + 1 ))) )); then
      # Check UDP. Stop the TCP client first: packets the server sends through it would move wg0 straight back.
      systemctl stop "$TCP_UNIT" >/dev/null 2>&1 || true
      # Drop the current session (remove the peer, load it again from wg0.conf with the UDP endpoint): the
      # check must make a NEW handshake over UDP. Some firewalls pass WireGuard data but drop the server's
      # handshake reply; with the old session a reply came back, but the tunnel died at the next rekey.
      PROBE_AT=$(date +%s)
      wg set "$IF" peer "$PEER" remove 2>/dev/null || true
      wg syncconf "$IF" <(wg-quick strip "$IF") 2>/dev/null || wg set "$IF" peer "$PEER" endpoint "$ENDPOINT" 2>/dev/null || true
      HS_OK=0
      if server_answers; then
        HS=$(wg show "$IF" latest-handshakes 2>/dev/null | awk -v p="$PEER" '$1==p{print $2}' || true)
        [[ "$HS" =~ ^[0-9]{1,12}$ ]] && (( HS >= PROBE_AT )) && HS_OK=1
      fi
      if (( HS_OK )); then
        logger -t easygate-watchdog "UDP works again: leaving the TCP fallback"
        probe_fails=0; transport=udp; switched=$NOW; save
        exit 0
      fi
      probe_fails=$(( probe_fails + 1 ))
      if to_tcp; then
        server_answers || true   # through TCP: the server moves back to the relay at once
        logger -t easygate-watchdog "UDP still gets no reply: staying on the TCP fallback (next check in $(backoff $(( probe_fails + 1 )))s)"
      else
        transport=udp; switched=$NOW; save
      fi
      exit 0
    else
      exit 0
    fi
  else
    # on UDP and working: the TCP client is not needed
    if (( SILENCE <= 135 )) && systemctl is-active --quiet "$TCP_UNIT"; then systemctl stop "$TCP_UNIT" >/dev/null 2>&1 || true; fi
    if (( MODE_SILENCE > FALLBACK_AFTER && NOW >= tcp_retry_at )); then
      logger -t easygate-watchdog "no reply over UDP for ${MODE_SILENCE}s: switching to the TCP fallback ($(awk -F: '{print $1}' <<<"$ENDPOINT"):${TCP_PORT})"
      if to_tcp; then fallbacks=$(( fallbacks + 1 )); probe_fails=0; save; exit 0; fi
    fi
  fi
fi

(( SILENCE > 135 )) || exit 0

[[ $transport == udp ]] && { wg set "$IF" peer "$PEER" endpoint "$ENDPOINT" 2>/dev/null || true; }   # re-resolve the server name

(( RESTART_AFTER > 0 )) || exit 0
WAIT=$RESTART_AFTER
for (( i = 0; i < fails && WAIT < MAX_WAIT; i++ )); do WAIT=$(( WAIT * 2 )); done
if (( WAIT > MAX_WAIT )); then WAIT=$MAX_WAIT; fi
if (( WAIT < RESTART_AFTER )); then WAIT=$RESTART_AFTER; fi
(( SILENCE >= WAIT )) || exit 0

restarts=$(( restarts + 1 )); fails=$(( fails + 1 )); last_restart=$NOW
last_reason=no-handshake; last_silence=$(( LAST > 0 ? NOW - LAST : SILENCE ))
systemctl stop "$TCP_UNIT" >/dev/null 2>&1 || true
transport=udp; switched=$NOW
save
logger -t easygate-watchdog "no reply from the EasyGate server for ${SILENCE}s: restarting the tunnel (restart #${restarts}, next try after $(( WAIT * 2 > MAX_WAIT ? MAX_WAIT : WAIT * 2 ))s)"
systemctl restart "$UNIT"
EOF

put 644 /etc/systemd/system/easygate-watchdog.service <<EOF
[Unit]
Description=EasyGate - tunnel watchdog
After=wg-quick@wg0.service

[Service]
Type=oneshot
Environment=RESTART_AFTER=${RESTART_AFTER}
Environment=TCP_PORT=${TCP_PORT}
Environment=TCP_LOCAL=${TCP_LOCAL}
ExecStart=/usr/local/sbin/easygate-watchdog
EOF

# ---- 8a. TCP 443 fallback client (installer v0.4.0) -------------------------
# For sites that block outbound UDP. Started only by the watchdog when UDP gets no reply: it takes wg0's packets on
# 127.0.0.1:${TCP_LOCAL} (UDP) and carries them inside TLS to ${SERVER}:${TCP_PORT}, where the EasyGate relay passes
# them to this customer's WireGuard port. WireGuard still encrypts and authenticates everything; TLS only makes the
# traffic look like HTTPS. The certificate is not checked on purpose (WireGuard proves the server; firewalls that
# inspect TLS replace the certificate). The server decides whether this customer may use it, from its site IPs only.
put 755 /usr/local/sbin/easygate-tcp <<'EOF'
#!/usr/bin/env python3
"""EasyGate TCP 443 fallback client: wg0 <-> UDP 127.0.0.1:EG_LOCAL <-> TLS EG_SERVER:EG_TCP_PORT (EasyGate relay)."""
import asyncio, os, socket, ssl, struct, sys, time

SERVER = os.environ.get("EG_SERVER", "")
PORT = int(os.environ.get("EG_TCP_PORT", "443"))
TENANT = int(os.environ.get("EG_TENANT", "0"))
LOCAL = int(os.environ.get("EG_LOCAL", "51820"))
MAX_FRAME = 2048          # WireGuard packets on a 1420-byte tunnel are ~1500 bytes
MAX_BUFFER = 512 * 1024   # a stuck TCP connection drops packets instead of queuing them (WireGuard retries)


def log(msg):
    print(msg, file=sys.stderr, flush=True)


class Local(asyncio.DatagramProtocol):
    """The UDP side: wg0 sends here; replies go back to the port wg0 used last."""
    def __init__(self):
        self.transport = None
        self.wg = None
        self.writer = None

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        self.wg = addr
        w = self.writer
        if w is None or not data or len(data) > MAX_FRAME or w.transport.get_write_buffer_size() > MAX_BUFFER:
            return
        w.write(struct.pack(">H", len(data)) + data)

    def to_wg(self, data):
        if self.wg is not None:
            self.transport.sendto(data, self.wg)


async def session(local):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(["http/1.1"])
    reader, writer = await asyncio.wait_for(
        asyncio.open_connection(SERVER, PORT, ssl=ctx, server_hostname=SERVER), 20)
    sock = writer.get_extra_info("socket")
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    for opt, val in (("TCP_KEEPIDLE", 30), ("TCP_KEEPINTVL", 10), ("TCP_KEEPCNT", 3)):
        if hasattr(socket, opt):
            sock.setsockopt(socket.IPPROTO_TCP, getattr(socket, opt), val)
    writer.write(b"EGT1" + bytes([TENANT]))
    await writer.drain()
    log(f"connected to {SERVER}:{PORT} ({writer.get_extra_info('peername')[0]})")
    local.writer = writer
    try:
        while True:
            head = await reader.readexactly(2)
            n = struct.unpack(">H", head)[0]
            if n == 0 or n > MAX_FRAME:
                raise ValueError(f"bad frame length {n}")
            local.to_wg(await reader.readexactly(n))
    finally:
        local.writer = None
        writer.close()


async def main():
    if not SERVER or not 1 <= TENANT <= 254 or not 1 <= PORT <= 65535:
        log("EG_SERVER, EG_TCP_PORT and EG_TENANT must be set")
        sys.exit(2)
    loop = asyncio.get_running_loop()
    _, local = await loop.create_datagram_endpoint(Local, local_addr=("127.0.0.1", LOCAL))
    wait = 5
    while True:
        started = time.monotonic()
        try:
            await session(local)
            log("the server closed the connection")
        except asyncio.IncompleteReadError:
            log(f"{SERVER}:{PORT}: closed by the server (TCP fallback not allowed for this customer or site IP, or switched off)")
        except (OSError, asyncio.TimeoutError, ssl.SSLError, ValueError) as e:
            log(f"{SERVER}:{PORT}: {type(e).__name__}: {e}")
        if time.monotonic() - started > 60:
            wait = 5
        await asyncio.sleep(wait)
        wait = min(wait * 2, 60)


if __name__ == "__main__":
    asyncio.run(main())
EOF

put 644 /etc/systemd/system/easygate-tcp.service <<EOF
[Unit]
Description=EasyGate - tunnel over TCP ${TCP_PORT} (started by the watchdog when UDP is blocked)
After=network-online.target

[Service]
Environment=EG_SERVER=${SERVER}
Environment=EG_TCP_PORT=${TCP_PORT}
Environment=EG_TENANT=${TENANT_ID}
Environment=EG_LOCAL=${TCP_LOCAL}
ExecStart=/usr/bin/python3 /usr/local/sbin/easygate-tcp
Restart=always
RestartSec=5
DynamicUser=yes
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
EOF
# never at boot: the watchdog starts it only when UDP gets no reply
systemctl disable easygate-tcp >/dev/null 2>&1 || true

put 644 /etc/systemd/system/easygate-watchdog.timer <<'EOF'
[Unit]
Description=EasyGate - tunnel watchdog every 30 seconds

[Timer]
OnBootSec=1min
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
mkd 755 /var/lib/easygate-gateway
systemctl daemon-reload

# ---- 8b. File services for network devices (TFTP, HTTP, SFTP / SCP) ---------
# Devices at the site copy firmware from (and configs to) this gateway. Everything is OFF until an admin starts it in
# the EasyGate portal, which then copies the chosen library files here, opens the ports on the LAN only (firewall chain
# files_in), and sets a new password for the '${FILES_USER}' account. Stop (or the auto-stop timer, or a reboot) closes
# the ports, stops the servers and locks the account. Files stay on the gateway (library copies and what devices
# uploaded into received/) until deleted in the portal (user's choice, v0.3.2).
#   ${FILES_ROOT}            TFTP and HTTP root: library copies (read-only for devices)
#   ${FILES_ROOT}/received   uploads from devices (TFTP / SFTP / SCP); not readable over TFTP or HTTP
#   ${FILES_JAIL}            chroot of '${FILES_USER}' (sh, scp, sftp-server only); ${FILES_ROOT} is bind-mounted at files/
log "File services (off until started in the portal)..."
getent group "$FILES_USER" >/dev/null || groupadd --system "$FILES_USER"
if ! id "$FILES_USER" >/dev/null 2>&1; then
  useradd --system --gid "$FILES_USER" --home-dir /files --no-create-home --shell /bin/sh --comment "EasyGate file services" "$FILES_USER"
fi
usermod --lock "$FILES_USER" >/dev/null
id -nG tftp 2>/dev/null | grep -qw "$FILES_USER" || usermod -aG "$FILES_USER" tftp
mkd 755 "$FILES_ROOT" root:root
mkd 2770 "$FILES_ROOT/received" "root:$FILES_USER"

# The jail: root-owned all the way down (sshd requires it), with only what legacy SCP and SFTP need.
SFTP_SERVER=$(sshd -T 2>/dev/null | awk '$1=="subsystem" && $2=="sftp" {print $3; exit}')
[[ -n "$SFTP_SERVER" && "$SFTP_SERVER" != internal-sftp ]] || SFTP_SERVER=/usr/lib/openssh/sftp-server
rm -rf "${FILES_JAIL:?}/bin" "${FILES_JAIL:?}/usr" "${FILES_JAIL:?}/lib" "${FILES_JAIL:?}/lib64" "${FILES_JAIL:?}/dev" "${FILES_JAIL:?}/etc"
mkd 755 "$FILES_JAIL" root:root
jail_copy() {   # jail_copy <program> [path in the jail]: the program and the libraries it loads
  local src dst lib
  src=$(readlink -f "$1"); dst="$FILES_JAIL${2:-$1}"
  [[ -x "$src" ]] || die "file services: $1 not found"
  mkdir -p "$(dirname "$dst")"; cp -L "$src" "$dst"; chmod 755 "$dst"
  for lib in $(ldd "$src" 2>/dev/null | grep -o '/[^ )]*'); do
    [[ -f "$lib" ]] || continue
    mkdir -p "$FILES_JAIL$(dirname "$lib")"; cp -L "$lib" "$FILES_JAIL$lib"
  done
}
jail_copy /bin/sh /bin/sh
jail_copy /usr/bin/scp
jail_copy "$SFTP_SERVER"
mkd 755 "$FILES_JAIL/dev" root:root
[[ -e "$FILES_JAIL/dev/null" ]] || mknod -m 666 "$FILES_JAIL/dev/null" c 1 3
# scp looks up its own user name: only the 'files' account is known inside the jail (no passwords in it)
mkd 755 "$FILES_JAIL/etc" root:root
printf 'root:x:0:0::/:/usr/sbin/nologin\n%s:x:%s:%s::/files:/bin/sh\n' "$FILES_USER" "$(id -u "$FILES_USER")" "$(id -g "$FILES_USER")" | put 644 "$FILES_JAIL/etc/passwd" root:root
printf 'root:x:0:\n%s:x:%s:\n' "$FILES_USER" "$(id -g "$FILES_USER")" | put 644 "$FILES_JAIL/etc/group" root:root
chown -R root:root "$FILES_JAIL/bin" "$FILES_JAIL/usr" "$FILES_JAIL/dev" "$FILES_JAIL/etc"
[[ -d "$FILES_JAIL/lib" ]] && chown -R root:root "$FILES_JAIL/lib"
[[ -d "$FILES_JAIL/lib64" ]] && chown -R root:root "$FILES_JAIL/lib64"
mkd 755 "$FILES_JAIL/files" root:root
FSTAB_LINE="${FILES_ROOT} ${FILES_JAIL}/files none bind,nodev,nosuid 0 0"
grep -qF "$FSTAB_LINE" /etc/fstab || printf '%s\n' "$FSTAB_LINE" >> /etc/fstab
mountpoint -q "$FILES_JAIL/files" || mount --bind -o nodev,nosuid "$FILES_ROOT" "$FILES_JAIL/files"

# TFTP: root = ${FILES_ROOT}; may create files (devices upload into received/), reads of received/ are refused.
put 644 /etc/easygate-files.tftp-map <<'EOF'
# EasyGate: devices may upload into received/ but never read it over TFTP
rG ^received/.* no-access/denied
rG ^/received/.* no-access/denied
EOF
put 644 /etc/default/tftpd-hpa <<EOF
# EasyGate - generated by easygate-gateway-setup.sh (started only from the portal)
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="${FILES_ROOT}"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure --create --permissive --umask 027 --verbose --map-file /etc/easygate-files.tftp-map"
EOF

# HTTP: a plain file server with folder listing (like HFS), read-only, port set at each start.
put 644 /etc/systemd/system/easygate-files-http.service <<EOF
[Unit]
Description=EasyGate - HTTP file server for network devices (started from the portal)

[Service]
EnvironmentFile=/run/easygate-files/http.env
ExecStart=/usr/bin/python3 -m http.server \${HTTP_PORT} --directory ${FILES_ROOT}
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ReadOnlyPaths=${FILES_ROOT}
InaccessiblePaths=${FILES_ROOT}/received
RestrictAddressFamilies=AF_INET AF_INET6
EOF

put 755 /usr/local/sbin/easygate-files <<EOF
#!/usr/bin/env bash
# EasyGate file services (TFTP, HTTP, SFTP / SCP) - run by the EasyGate portal over the tunnel (sudo).
#   easygate-files start [--tftp] [--http PORT] [--sftp] --minutes N     (--sftp: the new password on stdin)
#   easygate-files stop | status | list
#   easygate-files put NAME SIZE      (file on stdin, into the library copies)
#   easygate-files get NAME           (a file from received/, to stdout)
#   easygate-files delete lib|received NAME
set -euo pipefail
ROOT="${FILES_ROOT}"; USER_NAME="${FILES_USER}"; STATE=/run/easygate-files/state
die() { echo "\$*" >&2; exit 2; }
name_ok() { [[ "\$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\$ ]] || die "invalid file name"; }
fw() { nft "\$@" 2>/dev/null || true; }
EOF
cat >> /usr/local/sbin/easygate-files <<'EOF'
mkdir -p /run/easygate-files; chmod 755 /run/easygate-files

stop_all() {
  fw flush chain inet easygate files_in
  # only the timer: when the auto-stop itself runs this, stopping its own service would end it half-way
  systemctl stop easygate-files-autostop.timer >/dev/null 2>&1 || true
  systemctl stop tftpd-hpa easygate-files-http >/dev/null 2>&1 || true
  usermod --lock "$USER_NAME" >/dev/null 2>&1 || true
  pkill -KILL -u "$USER_NAME" >/dev/null 2>&1 || true
  # files stay: they are removed only with "delete" from the portal; leftovers of an interrupted copy go
  find "$ROOT" -maxdepth 1 -type f -name '.put.*' -delete
  rm -f "$STATE"
}

case "${1:-}" in
  start)
    shift; tftp=0; http=0; sftp=0; minutes=60
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --tftp) tftp=1; shift ;;
        --http) http="${2:-}"; shift 2 ;;
        --sftp) sftp=1; shift ;;
        --minutes) minutes="${2:-}"; shift 2 ;;
        *) die "unknown option $1" ;;
      esac
    done
    [[ "$minutes" =~ ^[0-9]{1,4}$ ]] && (( minutes >= 1 && minutes <= 1440 )) || die "minutes: 1-1440"
    [[ "$http" =~ ^[0-9]{1,5}$ ]] && (( http == 0 || (http >= 1 && http <= 65535 && http != 22 && http != 443 && http != 69) )) || die "invalid HTTP port"
    (( tftp || http || sftp )) || die "nothing to start"
    pw=""
    if (( sftp )); then
      IFS= read -r pw || true
      [[ "$pw" =~ ^[A-Za-z0-9]{12,64}$ ]] || die "invalid password"
    fi
    fw flush chain inet easygate files_in
    systemctl stop easygate-files-autostop.timer >/dev/null 2>&1 || true
    if (( tftp )); then systemctl restart tftpd-hpa; fw add rule inet easygate files_in udp dport 69 accept comment '"easygate tftp"'
    else systemctl stop tftpd-hpa >/dev/null 2>&1 || true; fi
    if (( http )); then
      printf 'HTTP_PORT=%s\n' "$http" > /run/easygate-files/http.env
      systemctl restart easygate-files-http
      fw add rule inet easygate files_in tcp dport "$http" accept comment '"easygate http"'
    else systemctl stop easygate-files-http >/dev/null 2>&1 || true; fi
    if (( sftp )); then
      printf '%s:%s\n' "$USER_NAME" "$pw" | chpasswd
      usermod --unlock "$USER_NAME" >/dev/null
      fw add rule inet easygate files_in tcp dport 22 accept comment '"easygate sftp"'
    else usermod --lock "$USER_NAME" >/dev/null 2>&1 || true; pkill -KILL -u "$USER_NAME" >/dev/null 2>&1 || true; fi
    until=$(( $(date +%s) + minutes * 60 ))
    systemd-run --on-active="${minutes}m" --unit=easygate-files-autostop --collect --quiet /usr/local/sbin/easygate-files stop
    printf 'tftp=%s\nhttp=%s\nsftp=%s\nuntil=%s\n' "$tftp" "$http" "$sftp" "$until" > "$STATE"
    echo started
    ;;
  stop) stop_all; echo stopped ;;
  status)
    if [[ -r "$STATE" ]]; then cat "$STATE"; else printf 'tftp=0\nhttp=0\nsftp=0\nuntil=0\n'; fi
    printf 'tftp_active=%s\nhttp_active=%s\n' "$(systemctl is-active tftpd-hpa 2>/dev/null || true)" "$(systemctl is-active easygate-files-http 2>/dev/null || true)"
    printf 'free=%s\n' "$(df -B1 --output=avail "$ROOT" | tail -1 | tr -dc '0-9')"
    printf 'lan_ip=%s\n' "$(ip -4 -o addr show dev "$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')" | awk 'NR==1{split($4,a,"/"); print a[1]}')"
    ;;
  list)
    find "$ROOT" -maxdepth 1 -type f -printf 'lib\t%s\t%T@\t%f\n'
    find "$ROOT/received" -maxdepth 1 -type f -printf 'received\t%s\t%T@\t%f\n'
    ;;
  put)
    name="${2:-}"; size="${3:-}"; name_ok "$name"
    [[ "$size" =~ ^[0-9]{1,13}$ ]] || die "invalid size"
    avail=$(df -B1 --output=avail "$ROOT" | tail -1 | tr -dc '0-9')
    (( avail > size + 104857600 )) || die "not enough free space on the gateway ($(( avail / 1048576 )) MB free)"
    tmp=$(mktemp "$ROOT/.put.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    head -c "$size" > "$tmp"
    [[ $(stat -c %s "$tmp") == "$size" ]] || die "incomplete copy"
    chmod 644 "$tmp"; mv -f "$tmp" "$ROOT/$name"; trap - EXIT
    echo ok
    ;;
  get) name="${2:-}"; name_ok "$name"; [[ -f "$ROOT/received/$name" ]] || die "no such file"; cat "$ROOT/received/$name" ;;
  delete)
    where="${2:-}"; name="${3:-}"; name_ok "$name"
    case "$where" in lib) rm -f "$ROOT/$name" ;; received) rm -f "$ROOT/received/$name" ;; *) die "lib or received" ;; esac
    echo ok
    ;;
  *) die "usage: easygate-files start|stop|status|list|put|get|delete" ;;
esac
EOF
chmod 755 /usr/local/sbin/easygate-files

# Closed after every boot: no ports, servers stopped, account locked (files stay).
put 644 /etc/systemd/system/easygate-files-reset.service <<'EOF'
[Unit]
Description=EasyGate - file services off after boot
After=nftables.service tftpd-hpa.service
Wants=nftables.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/easygate-files stop

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable easygate-files-reset.service >/dev/null 2>&1
/usr/local/sbin/easygate-files stop >/dev/null || warn "file services: reset failed"

# ---- 9. Start tunnel --------------------------------------------------------
log "Starting tunnel..."
systemctl enable wg-quick@wg0 >/dev/null 2>&1
# the tunnel starts on UDP; the watchdog switches to the TCP fallback again if UDP is still blocked
systemctl stop easygate-tcp >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0
systemctl enable --now easygate-watchdog.timer >/dev/null 2>&1
if (( RESTART_AFTER > 0 )); then
  log "Watchdog:         restarts the tunnel after ${RESTART_AFTER}s without reply from the server"
else
  log "Watchdog:         re-resolves the server name only (--restart-after 0)"
fi

# ---- 9b. Time: the EasyGate server over the VPN first, Ubuntu's servers as fallback ----
# The server answers time requests on its tunnel address only to this gateway.
TIME_SYNC="not configured"
if command -v chronyc >/dev/null 2>&1 && [[ -d /etc/chrony ]]; then
  mkd 755 /etc/chrony/sources.d
  put 644 /etc/chrony/sources.d/easygate.sources <<EOF
# EasyGate server over the VPN (generated by easygate-gateway-setup.sh). Ubuntu's own sources stay as fallback.
server ${SERVER_TUN} iburst prefer minpoll 6 maxpoll 10
EOF
  chronyc reload sources >/dev/null 2>&1 || systemctl restart chrony
  TIME_SYNC="chrony: ${SERVER_TUN} (EasyGate server, preferred), Ubuntu servers as fallback"
elif systemctl cat systemd-timesyncd.service >/dev/null 2>&1; then
  mkd 755 /etc/systemd/timesyncd.conf.d
  put 644 /etc/systemd/timesyncd.conf.d/easygate.conf <<EOF
# EasyGate server over the VPN (generated by easygate-gateway-setup.sh)
[Time]
NTP=${SERVER_TUN}
FallbackNTP=ntp.ubuntu.com
EOF
  systemctl restart systemd-timesyncd
  TIME_SYNC="systemd-timesyncd: ${SERVER_TUN} (EasyGate server), ntp.ubuntu.com as fallback"
else
  warn "neither chrony nor systemd-timesyncd is installed: the gateway clock is not synchronised"
fi
log "Time sync:        $TIME_SYNC"

PUBLIC_IP=$(curl -4 -s --max-time 8 https://api.ipify.org || true)
[[ "$PUBLIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || PUBLIC_IP=""

# ---- 10. Enrollment code ----------------------------------------------------
# EG1.<base64url JSON>.<first 8 hex of sha256(base64 part)>: one paste gives the portal the
# WireGuard key, site IP, LAN and the SSH host key it pins (no "trust on first use").
[[ -s /etc/ssh/ssh_host_ed25519_key.pub ]] || ssh-keygen -A >/dev/null
HOST_KEY=$(awk '{print $1" "$2}' /etc/ssh/ssh_host_ed25519_key.pub)
[[ "$HOST_KEY" =~ ^ssh-ed25519\ AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}$ ]] || die "unexpected SSH host key format in /etc/ssh/ssh_host_ed25519_key.pub"
[[ "$GW_PUBKEY" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$ ]] || die "unexpected WireGuard public key format"
THIS_HOST=$(hostname)
[[ "$THIS_HOST" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || THIS_HOST=""
# every value is validated above, so plain printf builds valid JSON
PAYLOAD=$(printf '{"v":1,"t":%d,"k":"%s","ip":"%s","lan":"%s","h":"%s","hk":"%s","ver":"%s"}' \
  "$TENANT_ID" "$GW_PUBKEY" "$PUBLIC_IP" "$LAN_NET" "$THIS_HOST" "$HOST_KEY" "$VERSION")
B64=$(printf '%s' "$PAYLOAD" | base64 -w0 | tr '+/' '-_' | tr -d '=')
SUM=$(printf '%s' "$B64" | sha256sum | cut -c1-8)
ENROLL_CODE="EG1.${B64}.${SUM}"
HOST_FP=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')

# ---- Summary ----------------------------------------------------------------
cat <<EOF

=====================================================================
 EasyGate gateway configured  v${VERSION}  (${THIS_HOST:-$(hostname)}, $(date '+%Y-%m-%d %H:%M'))
=====================================================================
 Gateway LAN:          $LAN_IF  $GW_IP  ($LAN_NET via $DEF_ROUTER)
 Tunnel:               $GW_TUN -> $SERVER_TUN  ($SERVER:$PORT)
 Approved subnets:     $APPROVED
 Site public IP:       ${PUBLIC_IP:-unknown - check with your router}
 SSH host key:         $HOST_FP
 Time sync:            $TIME_SYNC
 Tunnel watchdog:      $( (( RESTART_AFTER > 0 )) && echo "restart after ${RESTART_AFTER}s without reply" || echo "off (re-resolve only)")
 TCP fallback:         $( (( TCP_PORT > 0 )) && echo "TLS to $SERVER:$TCP_PORT when UDP is blocked (if the server allows it)" || echo "off")

 >>> Paste this ENROLLMENT CODE into the EasyGate portal <<<
     (customer page -> Setup instructions -> Paste the enrollment code)

EOF
printf '%s\n' "$ENROLL_CODE"
cat <<EOF

 The tunnel connects as soon as the portal accepts the code.
 Check with:   sudo wg show
 (Older portal? The gateway public key is: $GW_PUBKEY)
=====================================================================
EOF
