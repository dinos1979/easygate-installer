#!/usr/bin/env bash
# =============================================================================
# EasyGate - remove the gateway configuration (undoes easygate-gateway-setup.sh)
#
# Removes: the WireGuard tunnel, its keys and config, the endpoint re-resolve timer,
# the EasyGate firewall/NAT rules (restores the firewall that was there before),
# IP forwarding, the EasyGate SSH rules, and the 'easyadmin' management account.
# The hostname, the network settings and other users are not changed.
#
# Run it on the gateway console or over SSH from the LAN (not over the tunnel).
#
# Usage (as root):
#   sudo bash easygate-gateway-remove.sh [--yes] [--keep-user] [--keep-packages]
#     --yes            do not ask for confirmation
#     --keep-user      keep the easyadmin account (its SSH key and sudo rule are still removed)
#     --keep-packages  keep the wireguard-tools package installed
# =============================================================================
set -uo pipefail
VERSION="0.1.1"
ADMIN_USER="easyadmin"
ASSUME_YES=no; KEEP_USER=no; KEEP_PKGS=no

log()  { printf '\e[1;34m[easygate]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warning]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[error]\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)           ASSUME_YES=yes; shift ;;
    --keep-user)     KEEP_USER=yes; shift ;;
    --keep-packages) KEEP_PKGS=yes; shift ;;
    -h|--help)       usage ;;
    *)               die "unknown option: $1 (use --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root (sudo bash $0 ...)"
log "easygate-gateway-remove v${VERSION}"

# ---- Safety checks ----------------------------------------------------------
# Over the tunnel the session would drop half-way, when wg0 goes down.
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  CLIENT_IP="${SSH_CONNECTION%% *}"
  [[ "$CLIENT_IP" =~ ^100\.96\. ]] && die "you are connected over the EasyGate tunnel ($CLIENT_IP). Run this on the gateway console or over SSH from the LAN."
fi
# Deleting the account you are logged in with would leave you without sudo.
if [[ "$KEEP_USER" == no && "${SUDO_USER:-}" == "$ADMIN_USER" ]]; then
  die "you are logged in as $ADMIN_USER. Log in with the site's own admin account, or add --keep-user."
fi
# Make sure another account can still administer this machine after easyadmin is gone.
if [[ "$KEEP_USER" == no ]]; then
  OTHER_ADMINS=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -vx "$ADMIN_USER" | grep -v '^$' | paste -sd' ' -)
  [[ -n "$OTHER_ADMINS" ]] || die "no other account is in the 'sudo' group - removing $ADMIN_USER would leave no admin. Add one first, or use --keep-user."
fi

cat <<EOF

This removes the EasyGate configuration from $(hostname):
  - WireGuard tunnel wg0, its keys and /etc/wireguard (the gateway key is destroyed)
  - the endpoint re-resolve timer and the wg-quick boot settings
  - the EasyGate firewall and NAT rules (the previous firewall is restored)
  - IP forwarding and the EasyGate SSH rules
EOF
if [[ "$KEEP_USER" == no ]]; then echo "  - the $ADMIN_USER account and its home folder"
else echo "  - the SSH key and sudo rule of $ADMIN_USER (the account itself is kept)"; fi
[[ "$KEEP_PKGS" == no ]] && echo "  - the wireguard-tools package"
echo

if [[ "$ASSUME_YES" == no ]]; then
  [[ -r /dev/tty ]] || die "no terminal to confirm on - add --yes"
  read -r -p "Type REMOVE to continue: " ANSWER </dev/tty
  [[ "$ANSWER" == "REMOVE" ]] || die "cancelled - nothing was changed"
fi

FAILED=0
step() {  # step <description> <command...>: run, report, keep going on failure
  local desc="$1"; shift
  if "$@"; then log "$desc"; else warn "$desc - FAILED (continuing)"; FAILED=1; fi
}

# ---- 1. Re-resolve timer ----------------------------------------------------
remove_reresolve() {
  systemctl disable --now easygate-reresolve.timer >/dev/null 2>&1 || true
  systemctl stop easygate-reresolve.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/easygate-reresolve.timer /etc/systemd/system/easygate-reresolve.service \
        /usr/local/sbin/easygate-reresolve
}
step "Removed the endpoint re-resolve timer" remove_reresolve

# ---- 2. WireGuard tunnel ----------------------------------------------------
remove_tunnel() {
  systemctl disable --now wg-quick@wg0 >/dev/null 2>&1 || true
  if ip link show wg0 >/dev/null 2>&1; then ip link delete wg0 || return 1; fi
  rm -rf /etc/systemd/system/wg-quick@wg0.service.d
  rm -rf /etc/wireguard
  systemctl daemon-reload
  systemctl reset-failed wg-quick@wg0 easygate-reresolve.service >/dev/null 2>&1 || true
}
step "Stopped the tunnel and deleted /etc/wireguard (keys included)" remove_tunnel

# ---- 3. Firewall + NAT ------------------------------------------------------
restore_firewall() {
  nft delete table inet easygate >/dev/null 2>&1 || true
  nft delete table ip easygate_nat >/dev/null 2>&1 || true
  if [[ -f /etc/nftables.conf.pre-easygate ]]; then
    mv -f /etc/nftables.conf.pre-easygate /etc/nftables.conf
    log "Restored the firewall rules from before EasyGate"
  else
    # Ubuntu's default: an empty ruleset that allows everything
    install -m 755 /dev/stdin /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
	chain input {
		type filter hook input priority filter;
	}
	chain forward {
		type filter hook forward priority filter;
	}
	chain output {
		type filter hook output priority filter;
	}
}
EOF
    systemctl disable nftables >/dev/null 2>&1 || true
    log "No earlier firewall found - restored Ubuntu's default (empty) ruleset"
  fi
  nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf
}
step "Removed the EasyGate firewall and NAT rules" restore_firewall

# ---- 4. Kernel settings -----------------------------------------------------
remove_sysctl() {
  rm -f /etc/sysctl.d/90-easygate.conf
  sysctl -q -w net.ipv4.ip_forward=0 >/dev/null
  sysctl --system >/dev/null
}
step "Turned off IP forwarding" remove_sysctl

# ---- 5. SSH rules -----------------------------------------------------------
remove_ssh_rules() {
  local f=/etc/ssh/sshd_config.d/80-easygate.conf
  [[ -f "$f" ]] || return 0
  mv "$f" /root/80-easygate.conf.removed
  if sshd -t; then systemctl restart ssh; rm -f /root/80-easygate.conf.removed
  else mv /root/80-easygate.conf.removed "$f"; return 1; fi
}
step "Removed the EasyGate SSH rules" remove_ssh_rules

# ---- 6. Management account --------------------------------------------------
remove_admin() {
  rm -f "/etc/sudoers.d/90-$ADMIN_USER"
  id "$ADMIN_USER" >/dev/null 2>&1 || return 0
  rm -f "/home/$ADMIN_USER/.ssh/authorized_keys"
  if [[ "$KEEP_USER" == yes ]]; then
    gpasswd -d "$ADMIN_USER" sudo >/dev/null 2>&1 || true
    return 0
  fi
  pkill -KILL -u "$ADMIN_USER" >/dev/null 2>&1 || true
  sleep 1
  userdel -r "$ADMIN_USER" 2>/dev/null || userdel "$ADMIN_USER"
}
if [[ "$KEEP_USER" == yes ]]; then
  step "Removed the SSH key and sudo rights of $ADMIN_USER (account kept)" remove_admin
else
  step "Deleted the $ADMIN_USER account" remove_admin
fi

# ---- 7. Packages ------------------------------------------------------------
remove_packages() {
  export DEBIAN_FRONTEND=noninteractive
  local pkgs=()
  for p in wireguard-tools wireguard; do dpkg -s "$p" >/dev/null 2>&1 && pkgs+=("$p"); done
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  apt-get purge -y -q "${pkgs[@]}" >/dev/null
}
[[ "$KEEP_PKGS" == no ]] && step "Removed the WireGuard package" remove_packages

logger -t easygate "gateway configuration removed by easygate-gateway-remove.sh v${VERSION}"

# ---- Summary ----------------------------------------------------------------
cat <<EOF

=====================================================================
 EasyGate configuration removed from $(hostname)  ($(date '+%Y-%m-%d %H:%M'))
=====================================================================
 Kept: hostname, network settings, other users, nftables and SSH.

 Tell the EasyGate server administrator, so the server side of this
 customer's tunnel (peer key and site IP) can be removed as well.
=====================================================================
EOF
[[ $FAILED -eq 0 ]] || { warn "some steps failed - see the warnings above"; exit 1; }
