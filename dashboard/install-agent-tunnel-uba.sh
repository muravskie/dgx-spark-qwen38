#!/usr/bin/env bash
# Uba side of the Cockpit Agent connection. OpenCode remains on Uba loopback;
# this is an SSH reverse forward over the LAN to a loopback-only Spark port.
set -euo pipefail

SPARK_LAN_IP="${SPARK_LAN_IP:-192.168.1.64}"
SPARK_USER="${SPARK_USER:-cockpit-agent}"
SPARK_HOSTKEY_SHA256="${SPARK_HOSTKEY_SHA256:-SHA256:Fc2dJPuu9ZlQhqKIgJsu58RI6lonbJQJO6lj/UQu9Rw}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
TUNNEL_PORT="${TUNNEL_PORT:-14096}"
UNIT=qwen38-agent-tunnel.service
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_PATH="$UNIT_DIR/$UNIT"
KEY_PATH="$HOME/.ssh/cockpit-agent-tunnel"
MODE="${1:---prepare}"

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" != 0 ]] || die "run this as the Uba user that runs OpenCode, not root"
[[ "$MODE" = --prepare || "$MODE" = --install ]] || die "usage: $0 [--prepare|--install]"
[[ "$SPARK_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "SPARK_USER must be a simple Unix user name"
[[ "$HOME" != *[[:space:]]* ]] || die "the Uba home path cannot contain spaces"
for value in "$SPARK_LAN_IP" "$OPENCODE_PORT" "$TUNNEL_PORT"; do
  [[ "$value" =~ ^[0-9.]+$ ]] || die "LAN address and ports must be numeric"
done
python3 - "$SPARK_LAN_IP" <<'PY' || die "SPARK_LAN_IP must be a valid IPv4 address"
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
[[ "$OPENCODE_PORT" =~ ^[0-9]+$ && "$TUNNEL_PORT" =~ ^[0-9]+$ ]] || die "ports must be numeric"
(( OPENCODE_PORT > 0 && OPENCODE_PORT < 65536 && TUNNEL_PORT > 0 && TUNNEL_PORT < 65536 )) \
  || die "ports must be between 1 and 65535"
command -v ssh >/dev/null || die "OpenSSH client is required"
command -v ssh-keygen >/dev/null || die "OpenSSH key tools are required"
command -v curl >/dev/null || die "curl is required"
command -v systemctl >/dev/null || die "systemd is required"
command -v loginctl >/dev/null || die "systemd-logind is required"
command -v ip >/dev/null || die "iproute2 is required"
command -v ss >/dev/null || die "iproute2 is required"
command -v ssh-keyscan >/dev/null || die "OpenSSH client tools are required"
ROUTE="$(ip route get "$SPARK_LAN_IP" 2>/dev/null | head -1)"
[[ -n "$ROUTE" && "$ROUTE" != *tailscale* ]] || die "Spark route is not a local-network interface: $ROUTE"

# Refuse to tunnel an OpenCode listener that is reachable beyond Uba itself.
LISTENERS="$(ss -H -ltn "sport = :$OPENCODE_PORT" | awk '{print $4}')"
[[ -n "$LISTENERS" ]] || die "nothing is listening on TCP port $OPENCODE_PORT"
while IFS= read -r listener; do
  [[ "$listener" = "127.0.0.1:$OPENCODE_PORT" || "$listener" = "[::1]:$OPENCODE_PORT" ]] \
    || die "OpenCode must listen only on loopback port $OPENCODE_PORT (found $listener)"
done <<<"$LISTENERS"

# The OpenCode API must already be running locally. 200 means no server auth;
# 401 is fine too: the Spark relay adds its Basic credentials inside the tunnel.
HEALTH_CODE="$(curl --noproxy '*' --silent --output /dev/null --max-time 3 \
  --write-out '%{http_code}' "http://127.0.0.1:$OPENCODE_PORT/api/info" || true)"
[[ "$HEALTH_CODE" = 200 || "$HEALTH_CODE" = 401 ]] \
  || die "OpenCode is not answering on 127.0.0.1:$OPENCODE_PORT (HTTP $HEALTH_CODE)"

# Do not reuse Uba's ordinary passwordless SSH key. Spark installs this key on a
# dedicated account whose sshd Match block permits only this remote listener.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [[ ! -s "$KEY_PATH" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C 'qwen38 cockpit agent tunnel' -f "$KEY_PATH"
  chmod 600 "$KEY_PATH"
  chmod 644 "$KEY_PATH.pub"
fi

# Pin Spark's ed25519 SSH host key before connecting. The fingerprint was read
# from Spark's host public key; keyscan itself is only used to fetch that public
# key over the LAN.
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
if ! ssh-keygen -F "$SPARK_LAN_IP" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
  KEY_LINE="$(ssh-keyscan -T 4 -t ed25519 "$SPARK_LAN_IP" 2>/dev/null | awk -v h="$SPARK_LAN_IP" '$1 == h {print; exit}')"
  [[ -n "$KEY_LINE" ]] || die "could not read Spark's SSH host key over the LAN"
  KEY_TMP="$(mktemp)"
  trap 'rm -f "$KEY_TMP"' EXIT
  awk '{print $2, $3}' <<<"$KEY_LINE" > "$KEY_TMP"
  FOUND_FP="$(ssh-keygen -lf "$KEY_TMP" -E sha256 2>/dev/null | awk '{print $2}')"
  [[ "$FOUND_FP" = "$SPARK_HOSTKEY_SHA256" ]] \
    || die "Spark host key fingerprint mismatch ($FOUND_FP); expected $SPARK_HOSTKEY_SHA256"
  printf '%s\n' "$KEY_LINE" >> "$KNOWN_HOSTS"
  chmod 600 "$KNOWN_HOSTS"
  rm -f "$KEY_TMP"
  trap - EXIT
fi

if [[ "$MODE" = --prepare ]]; then
  printf 'Prepared a dedicated tunnel key. Next, install its public half on Spark in the restricted cockpit-agent SSH account.\n'
  cat "$KEY_PATH.pub"
  printf 'After Spark installs that account, run this script again with --install.\n'
  exit 0
fi

mkdir -p "$UNIT_DIR"
cat > "$UNIT_PATH" <<EOF
[Unit]
Description=LAN-only reverse SSH tunnel for Spark Cockpit Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ssh -N -T -i $KEY_PATH -o IdentitiesOnly=yes -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=yes -R 127.0.0.1:$TUNNEL_PORT:127.0.0.1:$OPENCODE_PORT $SPARK_USER@$SPARK_LAN_IP
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
chmod 644 "$UNIT_PATH"
systemctl --user daemon-reload
systemctl --user enable "$UNIT"
# A re-run may change OPENCODE_PORT. daemon-reload + enable --now leaves an
# already active user service running its old ExecStart, silently forwarding to
# the previous port; restart so the requested target takes effect immediately.
systemctl --user restart "$UNIT"

UBA_USER="$(id -un)"
LINGER="$(loginctl show-user "$UBA_USER" -p Linger --value 2>/dev/null || true)"
if [[ "$LINGER" != yes ]]; then
  printf 'NOTE: this user service will stop at logout until linger is enabled. Run on Uba: sudo loginctl enable-linger %s\n' "$UBA_USER"
fi
printf 'Tunnel service: %s\n' "$(systemctl --user is-active "$UNIT" 2>/dev/null || true)"
printf 'OpenCode loopback health: HTTP %s\n' "$HEALTH_CODE"
printf 'Forward target on Spark: http://127.0.0.1:%s -> Uba 127.0.0.1:%s over LAN SSH\n' "$TUNNEL_PORT" "$OPENCODE_PORT"
printf 'Install this public key on Spark for the restricted cockpit-agent account:\n'
cat "$KEY_PATH.pub"
