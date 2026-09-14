# dvpnctl

A small, dependency-light controller for the [Sentinel](https://sentinel.co/)
dVPN network. It wraps the official `sentinel-dvpncli` to give you:

- **Full-tunnel WireGuard** — all traffic goes through the node (`0.0.0.0/0`).
- **Kill switch** — if the tunnel drops, host traffic is dropped (fail closed)
  rather than leaking to clearnet.
- **Stays up until you turn it off** — the tunnel is owned by a systemd unit with
  restart-on-failure.
- **One-command endpoint switching** — list cheapest/fastest nodes, jump between
  them instantly.
- **Automatic session cleanup** — stale/duplicate on-chain sessions are cancelled
  and a healthy one reused on each connect.

Not affiliated with, and with no dependency on,
[MathNodes/meile](https://github.com/MathNodes/meile). The only required
third-party component is the official Sentinel CLI.

## Requirements

- Linux with **systemd** and **WireGuard** (`wg`, `wg-quick`).
- **Python 3** with **PyYAML**.
- `iptables`/`ip6tables` (the kill switch) and `openresolv` (`resolvconf`).
- The engine: **sentinel-dvpncli v5** (the installer obtains it; see below).
- Optional, to build the engine from source: **Go ≥ 1.25** and `git`.

## Install

```bash
sudo ./install.sh <your-username>
```

The installer:

1. Obtains `sentinel-dvpncli` — uses one already on `PATH`, else downloads the
   official release, else builds a static binary from source (the musl-linked
   release needs a loader some systems lack, hence the fallback).
2. Symlinks `/usr/local/bin/dvpnctl` into this repo.
3. Writes a systemd unit that owns the tunnel as root.
4. Copies your wallet key into a root-only keyring the unit can use.
5. Points NetworkManager at `openresolv` (see [DNS](#dns-and-wg-quick) below).
6. Adds a sudoers rule so `dvpnctl up|down|switch` need no password.

## Quick start

```bash
dvpnctl init          # create the wallet (once); saves a mnemonic backup
dvpnctl fund          # show the address to send DVPN to
dvpnctl nodes         # list usable WireGuard endpoints by price/speed
dvpnctl up best       # start a session + full tunnel + kill switch
dvpnctl switch kfmg   # jump to a better endpoint
dvpnctl status        # tunnel, session, balance
dvpnctl down          # deactivate (cancels the session, refunds unused deposit)
```

Node selectors accepted anywhere: a list index (`3`), a moniker substring
(`kfmg`), a full `sentnode1…` address, or `best`.

> ⚠️ `dvpnctl init` writes your mnemonic to
> `~/.config/dvpnctl/wallet-backup.json` (mode 600). Move it somewhere safe —
> it is the only way to recover funds.

## How the kill switch works

The Sentinel WireGuard client writes a `wg-quick` config with
`AllowedIPs = 0.0.0.0/0, ::/0`. Because that includes a default route, the SDK
emits `PostUp`/`PreDown` iptables rules that **DROP all output that is not
leaving the WireGuard interface** (and ACCEPT the excluded LAN subnets). We rely
on those rules instead of a hand-rolled firewall; `wg-quick down` removes them.

Set `exclude_lan` in the config to `true` (default) to keep loopback and the
RFC1918 ranges out of the tunnel, or `false` for a strict full tunnel.

## DNS and wg-quick

`wg-quick` updates DNS via `resolvconf` (openresolv). If NetworkManager manages
`/etc/resolv.conf` itself, openresolv refuses to overwrite it and wg-quick
aborts with `signature mismatch`. The installer therefore sets
`rc-manager=resolvconf` in `/etc/NetworkManager/conf.d/90-dvpnctl-resolvconf.conf`.
To revert: delete that file and run `nmcli general reload dns-rc`.

## Configuration

Everything tunable lives in `~/.config/dvpnctl/config.json` (created on first
use). Defaults:

```json
{
  "rpc": "https://sentinel-rpc.polkachu.com:443",
  "chain_id": "sentinelhub-2",
  "keyring_backend": "os",
  "key_name": "main",
  "cli_home": "~/.sentinel-dvpncli",
  "session_gigabytes": 5,
  "session_hours": 0,
  "max_price_per_gb": 15.0,
  "max_peers": 60,
  "unit_name": "dvpnctl.service",
  "root_home": "/var/lib/dvpnctl",
  "iface": "wg0",
  "exclude_lan": true
}
```

- `session_gigabytes: 0` switches to time-based sessions using `session_hours`.
- `max_price_per_gb` / `max_peers` bound the nodes considered by `nodes`/`best`.
- `iface` changes the WireGuard interface name (rebuild the unit if you change it
  after install).

Override the config location with `DVPNCTL_CONFIG_DIR=/some/dir`.

## Costs and safety

- Starting a session **escrows** `price × gigabytes` DVPN on-chain (cheapest
  WireGuard nodes are currently ~12.5 DVPN/GB). The rest of your wallet is
  untouched — funds are never sent to the node up front.
- When you `down` (or the session times out), the node is paid only for measured
  usage and **`deposit − usage` is refunded**.
- The most a misbehaving node can take is one session's deposit. Keep
  `session_gigabytes` small to cap that; cycle sessions rather than opening one
  huge one.

## Files

| Path | Purpose |
|---|---|
| `dvpnctl` | the controller (Python 3) |
| `install.sh` | one-time root install |
| `systemd/dvpnctl.service` | unit that owns the tunnel |
| `dev-docs/` | runbook, rationale, and work log |
| `~/.config/dvpnctl/config.json` | tunables |
| `~/.config/dvpnctl/wallet-backup.json` | mnemonic — keep safe |

## License

MIT. See [LICENSE](LICENSE).
