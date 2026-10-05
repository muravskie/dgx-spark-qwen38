#!/usr/bin/env bash
# Spark side of the LAN-only Agent tunnel. Installs a dedicated sshd account
# that can open exactly one loopback remote forward from Uba.
set -euo pipefail

UBA_LAN_IP="${UBA_LAN_IP:-192.168.1.94}"
UBA_TUNNEL_USER="${UBA_TUNNEL_USER:-cockpit-agent}"
UBA_TUNNEL_PORT="${UBA_TUNNEL_PORT:-14096}"
PUBKEY_FILE="${UBA_TUNNEL_PUBKEY_FILE:-}"
SSHD_DROPIN=/etc/ssh/sshd_config.d/99-qwen38-cockpit-agent.conf
TUNNEL_HOME=/var/lib/qwen38-cockpit-agent
TMP_AUTH="$(mktemp)"
TMP_SSHD="$(mktemp)"
cleanup(){ rm -f "$TMP_AUTH" "$TMP_SSHD"; }
trap cleanup EXIT
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" != 0 ]] || die "run this as the Spark user; the script calls sudo for privileged steps"
[[ "$UBA_LAN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "UBA_LAN_IP must be an IPv4 address"
[[ "$UBA_TUNNEL_PORT" =~ ^[0-9]+$ ]] && (( UBA_TUNNEL_PORT > 0 && UBA_TUNNEL_PORT < 65536 )) \
  || die "UBA_TUNNEL_PORT must be between 1 and 65535"
[[ "$UBA_TUNNEL_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "UBA_TUNNEL_USER must be a simple Unix user name"
[[ -n "$PUBKEY_FILE" && -s "$PUBKEY_FILE" ]] || die "set UBA_TUNNEL_PUBKEY_FILE to Uba's cockpit-agent-tunnel.pub"
command -v sudo >/dev/null || die "sudo is required"
command -v sshd >/dev/null || die "OpenSSH server is required"
command -v useradd >/dev/null || die "useradd is required"
command -v ssh-keygen >/dev/null || die "OpenSSH key tools are required"
ssh-keygen -lf "$PUBKEY_FILE" >/dev/null 2>&1 || die "UBA_TUNNEL_PUBKEY_FILE is not a valid SSH public key"
python3 - "$UBA_LAN_IP" <<'PY' || die "UBA_LAN_IP must be a valid IPv4 address"
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
[[ -x /usr/sbin/nologin ]] || die "/usr/sbin/nologin is required"

read -r KEY_TYPE KEY_DATA KEY_COMMENT < "$PUBKEY_FILE" || die "could not read the public key"
[[ "$KEY_TYPE" = ssh-ed25519 && -n "$KEY_DATA" ]] || die "expected an ed25519 public key"
PUBKEY_LINE="from=\"$UBA_LAN_IP\",restrict,port-forwarding,permitlisten=\"127.0.0.1:$UBA_TUNNEL_PORT\" $KEY_TYPE $KEY_DATA ${KEY_COMMENT:-Uba Cockpit tunnel}"
printf '%s\n' "$PUBKEY_LINE" > "$TMP_AUTH"
cat > "$TMP_SSHD" <<EOF
Match User $UBA_TUNNEL_USER
    AllowTcpForwarding remote
    PermitListen 127.0.0.1:$UBA_TUNNEL_PORT
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ForceCommand /usr/sbin/nologin
Match all
EOF

# Create an account with no login shell, install the LAN-source-limited key,
# then validate sshd's complete config before reloading it.
if ! getent passwd "$UBA_TUNNEL_USER" >/dev/null; then
  sudo useradd --system --create-home --home-dir "$TUNNEL_HOME" --shell /usr/sbin/nologin "$UBA_TUNNEL_USER"
else
  PASSWD_LINE="$(getent passwd "$UBA_TUNNEL_USER")"
  IFS=: read -r _ _ _ _ _ EXISTING_HOME EXISTING_SHELL <<<"$PASSWD_LINE"
  [[ "$EXISTING_HOME" = "$TUNNEL_HOME" && "$EXISTING_SHELL" = /usr/sbin/nologin ]] \
    || die "the existing $UBA_TUNNEL_USER account does not match this restricted tunnel setup"
fi
# sshd's unprivileged key lookup needs to traverse/read these paths. Keep the
# directory and key root-owned so the restricted account cannot edit its own
# authorization, but make them traversable/readable (the key is public data).
sudo install -d -o root -g root -m 755 "$TUNNEL_HOME/.ssh"
sudo install -o root -g root -m 644 "$TMP_AUTH" "$TUNNEL_HOME/.ssh/authorized_keys"
sudo install -o root -g root -m 644 "$TMP_SSHD" "$SSHD_DROPIN"
sudo /usr/sbin/sshd -t
sudo systemctl reload ssh.service

printf 'Restricted SSH account ready: %s\n' "$UBA_TUNNEL_USER"
printf 'Permitted source: %s (LAN); remote listener: 127.0.0.1:%s only\n' "$UBA_LAN_IP" "$UBA_TUNNEL_PORT"
