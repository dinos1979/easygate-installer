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
#        [--no-mgmt-ssh]
#
# At the end it prints an ENROLLMENT CODE (EG1....) to paste into the portal:
# it carries the gateway WireGuard key, site IP, LAN and the SSH host key.
# =============================================================================
set -euo pipefail
VERSION="0.2.4"

# ---- Defaults ---------------------------------------------------------------
TENANT_ID=1
PORT=""
SERVER="easygate.easytech.com.cy"
SERVER_ADDR=""
SERVER_PUBKEY=""
APPROVED=""
MGMT_FROM=""
NEW_HOSTNAME=""
MGMT_SSH=yes
ADMIN_USER="easyadmin"
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

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

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

# ---- 1. Packages ------------------------------------------------------------
log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q wireguard-tools nftables openssh-server curl unattended-upgrades
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

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
put 644 /etc/ssh/sshd_config.d/80-easygate.conf <<EOF
# EasyGate - generated by easygate-gateway-setup.sh
PermitRootLogin no
X11Forwarding no
AllowUsers${ALLOW}
EOF
sshd -t || { rm -f /etc/ssh/sshd_config.d/80-easygate.conf; die "sshd config invalid - reverted"; }
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

put 755 /usr/local/sbin/easygate-reresolve <<'EOF'
#!/usr/bin/env bash
# Re-resolve the server endpoint when the handshake is stale (> 135 s), e.g. after a server IP change.
set -euo pipefail
IF=wg0; CONF=/etc/wireguard/wg0.conf
ip link show "$IF" >/dev/null 2>&1 || exit 0
# (keys end in '=', so strip the "Name = " prefix instead of splitting on '=')
PEER=$(awk '/^PublicKey[ \t]*=/{sub(/^PublicKey[ \t]*=[ \t]*/,""); print; exit}' "$CONF")
ENDPOINT=$(awk '/^Endpoint[ \t]*=/{sub(/^Endpoint[ \t]*=[ \t]*/,""); print; exit}' "$CONF")
[[ -n "$PEER" && -n "$ENDPOINT" ]] || exit 0
LAST=$(wg show "$IF" latest-handshakes | awk -v p="$PEER" '$1==p{print $2}')
NOW=$(date +%s)
if [[ -z "$LAST" || "$LAST" -eq 0 || $((NOW - LAST)) -gt 135 ]]; then
  wg set "$IF" peer "$PEER" endpoint "$ENDPOINT" && logger -t easygate "re-resolved endpoint $ENDPOINT"
fi
EOF

put 644 /etc/systemd/system/easygate-reresolve.service <<'EOF'
[Unit]
Description=EasyGate - re-resolve VPN server endpoint
After=wg-quick@wg0.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/easygate-reresolve
EOF

put 644 /etc/systemd/system/easygate-reresolve.timer <<'EOF'
[Unit]
Description=EasyGate - re-resolve VPN server endpoint every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload

# ---- 9. Start tunnel --------------------------------------------------------
log "Starting tunnel..."
systemctl enable wg-quick@wg0 >/dev/null 2>&1
systemctl restart wg-quick@wg0
systemctl enable --now easygate-reresolve.timer >/dev/null 2>&1

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
