# dvpnctl

A small controller for the [Sentinel](https://sentinel.co/) dVPN network. It
wraps the official `sentinel-dvpncli` to give you:

- **Full-tunnel WireGuard** — all traffic goes through the node (`0.0.0.0/0`).
- **Kill switch** — if the tunnel drops, host traffic is dropped, not leaked.
- **Stays up until you turn it off** — the tunnel is owned by a systemd unit
  with restart-on-failure.
- **One-command endpoint switching** — list cheapest/fastest nodes and jump
  between them.
- **Speed-probed selection** — `up best` measures real throughput through the
  top candidates before committing, and keeps the fastest.
- **Automatic session cleanup** — stale/duplicate on-chain sessions are
  cancelled and a healthy one reused on each connect.
- **Optional auto-failover** — a systemd timer probes the tunnel and moves to a
  new node after repeated failures.

No dependency on [MathNodes/meile](https://github.com/MathNodes/meile); the
third-party components are the official Sentinel CLI and PyYAML.

## Requirements

- Linux with **systemd** and **WireGuard** (`wg`, `wg-quick`).
- **Python 3** with **PyYAML** (the CLI's query output is YAML).
- `iptables`/`ip6tables` (kill switch), `openresolv` (`resolvconf`), and
  `curl` (used by the installer).
- **sentinel-dvpncli v5** — the installer obtains it (preinstalled → release
  download → source build). Building from source needs any **Go** and `git`;
  the build pins `GOTOOLCHAIN=go1.26.0` because the SDK's JSON dependency warns
  on newer Go.

## Setup

Two commands, in this order. `install.sh` installs the engine, unit, and
sudoers; `init` then creates the wallet and finishes setup by seeding the root
service keyring for you (one `sudo` prompt), so you never re-run the installer
by hand.

```bash
git clone https://github.com/<you>/dvpnctl && cd dvpnctl   # (or your checkout)
sudo ./install.sh "$USER"   # 1. engine, unit, sudoers, DNS, symlink
dvpnctl init                # 2. wallet + service keyring (one sudo prompt)
dvpnctl doctor              # verify readiness; safe to run any time
dvpnctl fund                # send DVPN to the printed address
dvpnctl up best             # connect
```

`dvpnctl doctor` is read-only and reports every prerequisite as `ok`, `warn`,
or `FAIL`, with the exact command to fix it. Run it whenever something seems
off; it is the quickest way to see what setup is missing.

If you already had a wallet before installing, `install.sh` seeds the keyring
itself and `init` simply re-checks it.

### What `install.sh` does

- obtains the engine (an existing `sentinel-dvpncli` is reused, else the latest
  release is downloaded, else a static binary is built from source);
- symlinks `/usr/local/bin/dvpnctl` into this repo (keep the repo in place);
- installs `systemd/dvpnctl.service`, which owns the tunnel as root;
- copies your wallet key into a root-only keyring under `/var/lib/dvpnctl` so
  the unit can sign the session handshake (when a wallet already exists);
- points NetworkManager at `openresolv` (see [DNS](#dns-and-wg-quick));
- adds `/etc/sudoers.d/dvpnctl`, letting your user start/stop/restart/reset the
  unit and run `wg show` without a password.

## Usage

```bash
dvpnctl fund          # show the address to send DVPN to
dvpnctl nodes         # list usable WireGuard endpoints by price/speed
dvpnctl up best       # start a session + full tunnel + kill switch
dvpnctl switch kfmg   # jump to a better endpoint
dvpnctl status        # tunnel, session, balance
dvpnctl verify        # prove traffic is tunneled (routing, firewall, exit IP)
dvpnctl down          # deactivate (cancels the session, refunds unused deposit)
```

Node selectors accepted anywhere: a list index (`3`), a moniker substring
(`kfmg`), a full `sentnode1…` address, or `best`. A moniker substring that
matches several nodes is rejected with the list of matches.

### Command reference

| Command | What it does |
|---|---|
| `init` | Create the wallet, write `wallet-backup.json` (mode 600), and seed the root service keyring (one `sudo` prompt). If the wallet already exists but the backup is gone, prompts for the mnemonic, verifies it against the address, and recreates the backup. |
| `doctor` | Read-only setup check: Python/PyYAML, engine, required commands, wallet, backup, service keyring, unit, sudoers, DNS config. Prints a fix for anything missing and exits non-zero if not ready. |
| `address` | Print the wallet address (exits non-zero if no wallet exists). |
| `balance` | Print the DVPN balance from the public LCD endpoints (`unknown (no LCD reachable)` if none answer). |
| `fund` | Print the address to fund, plus the cheapest node's price and a suggested starting amount. |
| `nodes [-r] [-c CC] [-a]` | List active WireGuard nodes, cheapest first. `-r/--refresh` ignores the on-disk cache, `-c/--country` filters by 2-letter code, `-a/--all` ignores the price cap. Also writes `nodes.order`, which backs numeric selectors. |
| `best` | Print the auto-selected node (the advertised pick, ignoring exclusions) as JSON. |
| `up [node] [--no-probe] [-g N] [-H N]` | Start/reuse a session, point the unit at it, and bring the tunnel up. With no node it reuses the last node (`node` config key) or probes for `best`. `-g`/`-H` override the session size for this and future runs. |
| `down [--keep-session]` | Stop the tunnel, print a usage/cost report for the session, and cancel it (refunding unused deposit) unless `--keep-session` is given. |
| `switch [node] [-g N] [-H N]` | `down` (cancelling the session) followed by `up` **without** speed probing. |
| `status` | Show unit state, interface, WireGuard peers, session id/node, balance, and address. |
| `verify` | Check interface state, default-route `ip rule`s, the kill-switch iptables DROP rules, and the exit IP; exits non-zero if not fully verified. |
| `watch` | One health-probe tick for the failover timer (see [Automatic failover](#automatic-failover)). No-op when the tunnel is down. |
| `selftest` | Offline check of the node-parsing/selection and tx-parsing logic. |

The installed sudoers rule grants passwordless `systemctl
start|stop|restart|reset-failed` on the unit and `wg show`; `up`, `down`,
`switch`, and `watch` use these to control the tunnel.

> ⚠️ `dvpnctl init` writes your mnemonic to
> `~/.config/dvpnctl/wallet-backup.json` (mode 600). Keep it in place until
> `dvpnctl doctor` reports ready, then move it somewhere safe — it is the only
> way to recover funds. If you move it away later, `dvpnctl init` prompts for
> the mnemonic and recreates it (verified against the wallet address), and
> re-runs the keyring seed for you.

## Node selection

**Source.** Active nodes are pulled from the chain (`query nodes --status
active`), filtered to `service_type == wireguard` and to nodes that quote a
`udvpn` price. Self-reported fields read: advertised `downlink`, `uplink`,
`peers`, location, and gigabyte/hourly pricing. (v2ray/xray nodes are SOCKS
proxies, not full tunnels, and are excluded.) The result is cached in
`nodes.yaml` for 1 hour; `nodes -r` forces a refresh.

**Shortlist.** Nodes are ranked cheapest-first, then by advertised downlink.
The advertised pick (`best_node`) considers a node eligible only if it is at or
below `max_price_per_gb` (15 DVPN/GB), has at most `max_peers` (60) peers, and
is not in the temporary watchdog exclusion list. Fallbacks, in order: ignore the
price/peer limits; if nothing has GB pricing, fall back to time-priced nodes;
last resort, ignore exclusions. `best_node` backs the `best` command, the
fallback when a probe can't connect, and the watchdog's failover choice.

**Measured pick.** `up best` (the default) takes the top `speed_probe_count` (3)
candidates from the shortlist, connects to each for real, downloads a
known-size payload through the tunnel, and keeps the fastest measured. The
probe shortlist applies the price cap and exclusions but **not** `max_peers`;
advertised `downlink` is only a hint. Losers are cancelled and their deposits
refunded. Measurements are cached in `speeds.json` for `speed_cache_ttl` (24h),
and a fresh cache entry is reused rather than re-probed.

- `--no-probe` takes the first advertised-best node without measuring.
- Each probe costs a session start + cancel (a couple of transactions), so keep
  `speed_probe_count` small.

**Persistent signals.** `nodes.yaml` (node cache), `nodes.order` (the ranking
written by `nodes`, backing numeric selectors), `speeds.json` (measured
throughput), and `excluded.json` (watchdog exclusions).

## Automatic failover

`dvpnctl watch` fetches `watch_url` through the tunnel and, after
`watch_fail_threshold` consecutive failures, excludes the current node
(`excluded.json`, for `watch_exclude_ttl` seconds) and reconnects to the best
remaining one. It is a no-op when the tunnel is down, and exits non-zero only on
an unexpected internal error. Enable it as a timer (opt-in):

```bash
sudo systemctl enable --now dvpnctl-watch.timer   # probes every 30s
```

The timer starts 2 minutes after boot and runs the `dvpnctl-watch.service`
oneshot as your user (the unit still controls the tunnel via the sudoers rule).
Tune `watch_url`, `watch_timeout`, `watch_fail_threshold`, and
`watch_exclude_ttl` in the config.

## Kill switch

The Sentinel client writes a `wg-quick` config with `AllowedIPs = 0.0.0.0/0,
::/0`. Because that includes a default route, the SDK emits `PostUp`/`PreDown`
iptables rules that **DROP all output not leaving the WireGuard interface** (and
ACCEPT the excluded subnets); `wg-quick down` removes them. Nothing is
hand-rolled. With `exclude_lan: true` (default) loopback and RFC1918 stay
reachable; set it `false` for a strict full tunnel (loopback only).

`dvpnctl verify` inspects these rules and the routing table to prove the tunnel
is actually in force.

## DNS and wg-quick

`wg-quick` updates DNS via `resolvconf` (openresolv). If NetworkManager manages
`/etc/resolv.conf` itself, openresolv refuses to overwrite it and wg-quick aborts
with `signature mismatch`; the installer sets `rc-manager=resolvconf` in
`/etc/NetworkManager/conf.d/90-dvpnctl-resolvconf.conf` to prevent that. To
revert: delete that file and run `nmcli general reload dns-rc`.

## Configuration

Tunables live in `~/.config/dvpnctl/config.json` (created on first use; override
the directory with the `DVPNCTL_CONFIG_DIR` environment variable). Defaults:

```json
{
  "rpc": "https://sentinel-rpc.polkachu.com:443",
  "keyring_backend": "os",
  "key_name": "main",
  "cli_home": "/home/<you>/.sentinel-dvpncli",
  "session_gigabytes": 5,
  "session_hours": 0,
  "max_price_per_gb": 15.0,
  "max_peers": 60,
  "unit_name": "dvpnctl.service",
  "root_home": "/var/lib/dvpnctl",
  "iface": "wg0",
  "exclude_lan": true,
  "watch_url": "https://api.ipify.org",
  "watch_timeout": 8,
  "watch_fail_threshold": 3,
  "watch_exclude_ttl": 3600,
  "speed_probe_count": 3,
  "speed_test_url": "https://speed.cloudflare.com/__down?bytes=25000000",
  "speed_test_timeout": 20,
  "speed_cache_ttl": 86400
}
```

| Key | Meaning |
|---|---|
| `rpc` | Primary RPC (cometbft) endpoint used for writes and queries. Public fallbacks are tried automatically if it fails or rate-limits. |
| `keyring_backend` | User-side keyring backend (`os`, `test`, `file`, …). Default `os`. |
| `key_name` | Key name in the keyring. Default `main`. |
| `cli_home` | Engine data directory (`~/.sentinel-dvpncli`). |
| `session_gigabytes` | Data-based session size. Set `0` to switch to time-based via `session_hours`. |
| `session_hours` | Time-based session length, used only when `session_gigabytes` is `0`. |
| `max_price_per_gb` | DVPN/GB ceiling for the shortlist and the advertised pick. |
| `max_peers` | Peer ceiling for the advertised pick (`best_node`). |
| `unit_name` | systemd unit that owns the tunnel. |
| `root_home` | Root-side engine home holding the unit keyring (`/var/lib/dvpnctl`). |
| `iface` | WireGuard interface name. Changing it after install requires re-running `install.sh`. |
| `exclude_lan` | Keep loopback + RFC1918 out of the tunnel (`true`), or only loopback (`false`). |
| `node` | Last selected node address (written by `up`, reused when `up` is given no node). Internal. |
| `watch_url` | URL fetched through the tunnel to prove liveness. |
| `watch_timeout` | Seconds per health probe. |
| `watch_fail_threshold` | Consecutive failures before failing over. |
| `watch_exclude_ttl` | Seconds a failed node stays excluded. |
| `speed_probe_count` | Top-N candidates to test before committing. |
| `speed_test_url` | Payload downloaded to measure throughput. |
| `speed_test_timeout` | Seconds allowed for the download. |
| `speed_cache_ttl` | Seconds a measured speed stays usable. |

## Files

| Path | Purpose |
|---|---|
| `dvpnctl` | the controller (Python 3) |
| `install.sh` | one-time root install |
| `systemd/dvpnctl.service` | unit that owns the tunnel |
| `systemd/dvpnctl-watch.{service,timer}` | optional failover watchdog |
| `~/.config/dvpnctl/config.json` | tunables |
| `~/.config/dvpnctl/session.env` | session id + unit parameters (written on `up`, removed on `down`) |
| `~/.config/dvpnctl/wallet-backup.json` | mnemonic — keep safe |
| `~/.config/dvpnctl/nodes.yaml`, `nodes.order` | node cache and ranking |
| `~/.config/dvpnctl/speeds.json`, `excluded.json` | measured speeds and watchdog exclusions |
| `~/.config/dvpnctl/watch.fails` | watchdog consecutive-failure counter |
| `~/.config/dvpnctl/root-keyring-ok` | marker written once the service keyring is seeded |
| `/var/lib/dvpnctl` | root-only engine keyring used by the unit |

## Costs and safety

- Starting a session **escrows** `price × gigabytes` DVPN on-chain (cheapest
  WireGuard nodes are currently ~12.5 DVPN/GB). The rest of the wallet is
  untouched — funds are never sent to the node up front.
- On `down` (or session timeout) the node is paid only for measured usage and
  **`deposit − usage` is refunded**. `dvpnctl down` prints a one-line report for
  the session it cancels: data used (down/up), cost, and the expected refund.
- The most a misbehaving node can take is one session's deposit. Keep
  `session_gigabytes` small to cap that, and cycle sessions rather than opening
  one huge one.

## Development and testing

The wallet/config live outside the repo, so the repo is safe to edit in place
(the installer only symlinks `dvpnctl` into `/usr/local/bin`).

```bash
python3 test_dvpnctl.py     # I/O-stubbed checks of cancel/consensus/probe logic
python3 dvpnctl selftest    # offline parse/selection check
```

`test_dvpnctl.py` needs no framework and stubs the module's I/O so nothing
touches the chain. Both suites are runnable without a wallet.

## License

MIT. See [LICENSE](LICENSE).
