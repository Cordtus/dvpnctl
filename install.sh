#!/usr/bin/env bash
# dvpnctl root install. Run:  sudo ./install.sh <username>
#
# Installs:
#   * the engine (sentinel-dvpncli): uses one already on PATH, else downloads
#     the official release, else builds a static binary from source;
#   * /usr/local/bin/dvpnctl (symlink into this repo);
#   * a systemd unit that owns the tunnel as root;
#   * a root-only keyring so the unit can sign the session handshake;
#   * a sudoers rule so `dvpnctl up|down|switch` toggle without a password.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-${1:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  echo "usage: sudo $0 <username>" >&2
  exit 1
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
CFG_DIR="$TARGET_HOME/.config/dvpnctl"
ROOT_HOME="/var/lib/dvpnctl"
UNIT="dvpnctl.service"
BINDIR="/usr/local/bin"

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

for bin in wg wg-quick iptables ip6tables resolvconf systemctl curl; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
done

# --- 1. engine ------------------------------------------------------------
ENGINE=""
find_engine() {
  local c
  for c in "$BINDIR/sentinel-dvpncli" "$TARGET_HOME/.local/bin/sentinel-dvpncli"; do
    [[ -x "$c" ]] && ENGINE="$c" && return 0
  done
  c="$(command -v sentinel-dvpncli 2>/dev/null || true)"
  [[ -n "$c" ]] && ENGINE="$c" && return 0
  return 1
}

download_engine() {
  local ver asset tmp
  ver="$(curl -fsSL https://api.github.com/repos/sentinel-official/sentinel-dvpncli/releases/latest \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$ver" ]] || return 1
  tmp="$(mktemp -d)"
  echo "downloading sentinel-dvpncli $ver ..."
  if curl -fsSL -o "$tmp/engine" \
       "https://github.com/sentinel-official/sentinel-dvpncli/releases/download/$ver/sentinel-dvpncli" \
     && chmod +x "$tmp/engine" \
     && "$tmp/engine" version >/dev/null 2>&1; then
    install -m755 "$tmp/engine" "$BINDIR/sentinel-dvpncli"
    ENGINE="$BINDIR/sentinel-dvpncli"
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

# The upstream musl-linked release needs a loader some hosts lack; fall back to
# a static build from source. Requires Go and network access to the module proxy.
build_engine() {
  command -v go >/dev/null || return 1
  local tmp
  tmp="$(mktemp -d)"
  echo "building sentinel-dvpncli from source (static) ..."
  if git clone --depth 1 https://github.com/sentinel-official/cli-client "$tmp/src" \
     && ( cd "$tmp/src" && CGO_ENABLED=0 go build -ldflags="-s -w" -o "$tmp/engine" . ) \
     && install -m755 "$tmp/engine" "$BINDIR/sentinel-dvpncli"; then
    ENGINE="$BINDIR/sentinel-dvpncli"
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

if find_engine && "$ENGINE" version >/dev/null 2>&1; then
  echo "engine: using existing $ENGINE"
elif download_engine; then
  echo "engine: installed release binary"
elif build_engine; then
  echo "engine: installed static build"
else
  echo "could not obtain sentinel-dvpncli; install it manually and re-run" >&2
  exit 1
fi

# --- 2. wrapper -----------------------------------------------------------
ln -sf "$HERE/dvpnctl" "$BINDIR/dvpnctl"

install -d -m700 -o "$TARGET_USER" -g "$TARGET_USER" "$CFG_DIR"
sed -e "s|@CFG_DIR@|$CFG_DIR|g" -e "s|@ROOT_HOME@|$ROOT_HOME|g" \
    -e "s|@CLI@|$BINDIR/sentinel-dvpncli|g" \
    "$HERE/systemd/dvpnctl.service" > "/etc/systemd/system/$UNIT"
chmod 644 "/etc/systemd/system/$UNIT"
install -d -m700 "$ROOT_HOME"

# watchdog: oneshot health probe + timer (opt-in; `systemctl enable --now`)
sed -e "s|@CFG_DIR@|$CFG_DIR|g" -e "s|@TARGET_HOME@|$TARGET_HOME|g" \
    -e "s|@TARGET_USER@|$TARGET_USER|g" \
    "$HERE/systemd/dvpnctl-watch.service" > /etc/systemd/system/dvpnctl-watch.service
cp "$HERE/systemd/dvpnctl-watch.timer" /etc/systemd/system/dvpnctl-watch.timer
chmod 644 /etc/systemd/system/dvpnctl-watch.service /etc/systemd/system/dvpnctl-watch.timer

# --- 3. root keyring ------------------------------------------------------
# `connect` signs the session handshake, so the unit needs the wallet key. The
# "test" backend stores it under $ROOT_HOME (0700, root-only), no passphrase.
if ! "$BINDIR/sentinel-dvpncli" --home "$ROOT_HOME" --keyring.backend test \
      keys list --output-format json 2>/dev/null | grep -q '"name":"main"'; then
  if [[ -f "$CFG_DIR/wallet-backup.json" ]]; then
    MN="$(python3 -c \
      "import json;print(json.load(open('$CFG_DIR/wallet-backup.json'))['mnemonic'])")"
    printf '%s\n\n' "$MN" | "$BINDIR/sentinel-dvpncli" --home "$ROOT_HOME" \
      --keyring.backend test keys add main >/dev/null
    echo "root service keyring: created"
  else
    echo "warning: $CFG_DIR/wallet-backup.json not found; run 'dvpnctl init' first" >&2
  fi
fi

# --- 4. DNS (openresolv must own /etc/resolv.conf for wg-quick) -----------
# NetworkManager otherwise writes its own header and openresolv's libc
# subscriber aborts wg-quick with "signature mismatch".
if command -v nmcli >/dev/null; then
  install -d -m755 /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/90-dvpnctl-resolvconf.conf <<'EOF'
[main]
rc-manager=resolvconf
EOF
  if ! head -1 /etc/resolv.conf 2>/dev/null | grep -q "Generated by resolvconf"; then
    resolvconf -u >/dev/null 2>&1 || true
    systemctl restart NetworkManager >/dev/null 2>&1 || true
    sleep 2
  fi
  if ! head -1 /etc/resolv.conf 2>/dev/null | grep -q "Generated by resolvconf"; then
    echo "warning: /etc/resolv.conf is not openresolv-managed; wg-quick DNS may fail" >&2
  fi
fi

# --- 5. sudoers -----------------------------------------------------------
cat > /etc/sudoers.d/dvpnctl <<EOF
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start $UNIT, /usr/bin/systemctl stop $UNIT, /usr/bin/systemctl restart $UNIT, /usr/bin/systemctl reset-failed $UNIT
EOF
chmod 440 /etc/sudoers.d/dvpnctl
visudo -cf /etc/sudoers.d/dvpnctl >/dev/null

systemctl daemon-reload
systemctl reset-failed "$UNIT" 2>/dev/null || true

echo "installed."
echo "next: as $TARGET_USER run  dvpnctl init  (once),  dvpnctl fund,  dvpnctl up best"
echo "optional auto-failover watchdog:  sudo systemctl enable --now dvpnctl-watch.timer"
