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
SEED_ONLY=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --seed-keyring) SEED_ONLY=1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
TARGET_USER="${SUDO_USER:-${POSITIONAL[0]:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  echo "usage: sudo $0 <username>" >&2
  echo "       sudo $0 --seed-keyring   (internal; called by 'dvpnctl init')" >&2
  exit 1
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
CFG_DIR="$TARGET_HOME/.config/dvpnctl"
ROOT_HOME="/var/lib/dvpnctl"
UNIT="dvpnctl.service"
BINDIR="/usr/local/bin"
KEYRING_MARKER="$CFG_DIR/root-keyring-ok"

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

# Seed the root-only keyring from the user's mnemonic backup, then drop a
# user-readable readiness marker so `dvpnctl doctor`/`up` can tell it is done.
# Idempotent; safe to call on its own via --seed-keyring.
seed_root_keyring() {
  install -d -m700 "$ROOT_HOME"
  if "$BINDIR/sentinel-dvpncli" --home "$ROOT_HOME" --keyring.backend test \
        keys list --output-format json 2>/dev/null | grep -q '"name":"main"'; then
    echo "root service keyring: already present"
  else
    if [[ ! -f "$CFG_DIR/wallet-backup.json" ]]; then
      echo "warning: $CFG_DIR/wallet-backup.json not found" >&2
      echo "  run 'dvpnctl init' to create the wallet, then re-run:" >&2
      echo "    sudo $0 $TARGET_USER" >&2
      return 1
    fi
    local mn
    mn="$(python3 -c \
      "import json;print(json.load(open('$CFG_DIR/wallet-backup.json'))['mnemonic'])")"
    if [[ -z "$mn" ]] || ! printf '%s\n\n' "$mn" | "$BINDIR/sentinel-dvpncli" \
          --home "$ROOT_HOME" --keyring.backend test keys add main >/dev/null; then
      echo "error: could not seed the root service keyring" >&2
      return 1
    fi
    echo "root service keyring: created"
  fi
  : > "$KEYRING_MARKER"
  chown "$TARGET_USER" "$KEYRING_MARKER"
  chmod 644 "$KEYRING_MARKER"
  return 0
}

if [[ $SEED_ONLY -eq 1 ]]; then
  seed_root_keyring
  exit
fi

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
#
# Build with Go <= 1.26: the SDK's bytedance/sonic dependency only supports
# go1.17~1.26 on amd64 (1.20~1.26 on arm64) and otherwise prints an unconditional
# stderr warning at startup ("sonic/ast only supports ... fallback to
# encoding/json"). GOTOOLCHAIN lets a newer Go fetch a compatible toolchain.
build_engine() {
  command -v go >/dev/null || return 1
  local tmp
  tmp="$(mktemp -d)"
  echo "building sentinel-dvpncli from source (static, GOTOOLCHAIN=go1.26.0) ..."
  if git clone --depth 1 https://github.com/sentinel-official/cli-client "$tmp/src" \
     && ( cd "$tmp/src" && CGO_ENABLED=0 GOTOOLCHAIN=go1.26.0 \
          go build -ldflags="-s -w" -o "$tmp/engine" . ) \
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
# If the wallet does not exist yet, skip it; `dvpnctl init` calls back into
# `install.sh --seed-keyring` once the wallet (and its backup) exists.
seed_root_keyring || true

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
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start $UNIT, /usr/bin/systemctl stop $UNIT, /usr/bin/systemctl restart $UNIT, /usr/bin/systemctl reset-failed $UNIT, /usr/bin/wg show *
EOF
chmod 440 /etc/sudoers.d/dvpnctl
visudo -cf /etc/sudoers.d/dvpnctl >/dev/null

systemctl daemon-reload
systemctl reset-failed "$UNIT" 2>/dev/null || true

echo "installed."
if [[ -f "$KEYRING_MARKER" ]]; then
  echo "ready.  Next, as $TARGET_USER:  dvpnctl fund   then   dvpnctl up best"
else
  echo "Almost done. As $TARGET_USER run:" >&2
  echo "    dvpnctl init     # creates the wallet and seeds the service keyring for you" >&2
fi
echo "check readiness any time with:  dvpnctl doctor"
echo "optional auto-failover watchdog:  sudo systemctl enable --now dvpnctl-watch.timer"
