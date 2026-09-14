# dvpnctl runbook

Operational source of truth.

## Components

- **Engine**: `sentinel-dvpncli` v5 (official Sentinel CLI, Go). Installed at
  `/usr/local/bin/sentinel-dvpncli` by `install.sh`.
- **Controller**: `dvpnctl` (Python 3) at `/usr/local/bin/dvpnctl` (a symlink
  into the repo, so edits take effect without reinstalling).
- **Tunnel owner**: `dvpnctl.service` (systemd **system** unit, runs as root).
- **State**: `~/.config/dvpnctl/` — `config.json`, `session.env`, `nodes.yaml`,
  `wallet-backup.json`.
- **CLI data / keyring**: `~/.sentinel-dvpncli/` (user `os` keyring).
- **Root keyring**: `/var/lib/dvpnctl` (unit `test` keyring).
- **WG runtime**: `/var/lib/dvpnctl/wireguard/<iface>.conf`, default `wg0`.

## Why not MathNodes/meile

The `MathNodes/meile` repo is a 2022 TUI (v0.5.1) that shells out to the removed
`sentinelcli` binary and cannot talk to the current chain. The maintained clients
are `sentinel-dvpncli` (used here) and `meile-gui`. Neither ships an Arch package
for the current version, and the Go CLI is the only zero-dependency option that
also exposes the kill-switch and scripting surface. dvpnctl is independent: it
imports/execs nothing from Meile and shares no license obligations with it.

## Connection model

1. `dvpnctl up <node>` picks an active **wireguard** node with a `udvpn` price
   and starts a pay-as-you-go session:
   `tx session-start <node> --gigabytes N --max-price udvpn:<base>,<quote>`.
   The chain escrows a deposit of `quote × gigabytes`.
2. The session id is written to `session.env` as `DVPNCTL_SESSION_ID`, along with
   `DVPNCTL_RPC`, `DVPNCTL_CLI`, `DVPNCTL_ROOT_HOME`, `DVPNCTL_IFACE`, and
   `DVPNCTL_EXCLUDE`.
3. `systemctl restart dvpnctl.service` runs
   `sentinel-dvpncli --home /var/lib/dvpnctl --keyring.backend test connect <id>`
   with the WireGuard flags from the env file.
4. The SDK writes a wg-quick config with `AllowedIPs = 0.0.0.0/0, ::/0` and runs
   `wg-quick up`, giving a full tunnel plus the kill switch.
5. `dvpnctl down` stops the unit and cancels the session, refunding the unused
   deposit.

`connect` signs the session handshake, so it needs the wallet key. Root has no
unlocked secret service, so the unit uses a `test` keyring
(`/var/lib/dvpnctl/keyring-test`, 0700 root) that `install.sh` populates.
Transactions run as the user via the `os` keyring.

## Kill switch

`AllowedIPs` contains `0.0.0.0/0`, so the SDK's `ClientConfig.PostUp()` emits,
via wg-quick:

```
iptables  -I OUTPUT ! -o <iface> -m mark ! --mark $(wg show <iface> fwmark) -j DROP
ip6tables -I OUTPUT ! -o <iface> -m mark ! --mark $(wg show <iface> fwmark) -j DROP
# then ACCEPT rules for each excluded subnet
```

and `PreDown()` deletes them. Consequences:

- All host output must leave via the interface (or be the tunnel's own marked
  traffic), otherwise it is dropped. A dead node fails **closed**, no clearnet
  leak.
- `Restart=on-failure` keeps the process alive, so the rules stay until
  `dvpnctl down`.
- A reboot deactivates: the interface and rules are gone and the unit is not
  enabled (intentional).
- `ExecStopPost` runs `wg-quick down` as a safety net for unclean exits.

`exclude_lan` (default true) keeps loopback + RFC1918 out of the tunnel by
passing `--wireguard.exclude-addrs`; false narrows that to loopback only.

## Session reconciliation

`dvpnctl up` calls `reconcile_sessions()` first: it lists every session on the
account across all RPCs and (a) cancels inactive/inactive-pending ones, and
(b) for the chosen node keeps exactly one active session, cancelling duplicates.
It then reuses the survivor or starts a new one. This prevents the
duplicate-session and `already exists in database` problems seen during bring-up.

Cancelling only sets `inactive_pending`; the chain deletes the session at
`inactive_at` (`status_timeout`, 2 h) and refunds the unused deposit, so a cancel
does not free the session id immediately.

## RPC endpoints

The CLI uses only the first `--rpc.addrs` value and requires an explicit port.
`rpc.sentinel.co:443` rate-limits aggressively (HTTP 429). The wrapper passes an
RPC explicitly and, for **reads only**, fails over across `RPC_FALLBACKS`
(polkachu → publicnode → sentinel.co). Transactions do not fail over, to avoid
double-submit; they use `config.json`'s `rpc`. `up` writes the `DVPNCTL_RPC` it
verified the session on into `session.env`; the unit connects against that.

## Toggle / switching

- `dvpnctl up [node]` — start (or reuse) a session and bring the tunnel up.
- `dvpnctl down` — stop, cancel session, remove kill switch.
- `dvpnctl switch <node>` — `down` then `up` on a new endpoint.
- `dvpnctl nodes` — endpoints sorted by price then downlink; `dvpnctl best` picks
  the fastest node under `max_price_per_gb`.

## AmneziaWG pool — dropped

A multi-peer AmneziaWG failover pool was built and then removed. Reasons: stock
WireGuard cannot fail over across peers sharing `/0` AllowedIPs (the kernel picks
the first match), there is no AWG kernel module on the test host (userspace
`amneziawg-go` is slow), only a handful of AWG nodes exist (and cost far more per
GB), and real failover needs a watchdog not worth its complexity.
`up`/`switch` cover endpoint changes. See the log for details.

## Operations

```bash
dvpnctl status                     # service, wg peer, session, balance
journalctl -u dvpnctl.service -n 50
wg show wg0
sudo iptables -S OUTPUT | grep -i wg0   # inspect kill switch
dvpnctl nodes -r -c DE             # refresh cache, filter Germany
```

## Troubleshooting

- **`up` says insufficient balance** — send DVPN to the printed address.
- **tunnel did not come up** — `journalctl -u dvpnctl.service`. `exit status 1`
  means `wg-quick` failed; the SDK discards its stderr, so reproduce with
  `sudo wg-quick up /var/lib/dvpnctl/wireguard/wg0.conf`. Common causes:
  `resolvconf: signature mismatch` (NetworkManager owns `/etc/resolv.conf`;
  `install.sh` fixes this) or a missing WireGuard module.
- **`session <id> already exists in database`** — the node already registered
  that session's peer (handshake succeeded, then wg-quick failed). The same
  session cannot handshake twice; `dvpnctl down` then `up` starts a fresh one.
- **interface exists after a crash** —
  `sudo wg-quick down /var/lib/dvpnctl/wireguard/wg0.conf` then `up`.
- **`sudo -n systemctl` denied** — rerun `sudo ./install.sh <user>`.

## Funding

Wallet address and mnemonic backup are printed by `dvpnctl fund`/`init`. A 5 GB
session is ~62 DVPN at the cheapest nodes; fund enough for a few sessions plus
gas.
