# Project map — dvpnctl

Sentinel dVPN full-tunnel + kill-switch controller (Linux, systemd, WireGuard).

| Area | Where | Notes |
|---|---|---|
| Controller CLI | `dvpnctl` | wallet, node picking, up/down/switch, reconciliation |
| Root install | `install.sh`, `systemd/dvpnctl.service` | unit owns the tunnel as root |
| Docs | `dev-docs/` | runbook is the operational source of truth |
| Runtime state | `~/.config/dvpnctl/` | config, session.env, node cache, wallet backup |
| Root state | `/var/lib/dvpnctl/` | root-only engine keyring (unit keyring) |
| Engine | `sentinel-dvpncli` (v5) | official Sentinel CLI; installed by `install.sh` |

Read `dev-docs/runbook.md` before changing connection, kill-switch, or session
behaviour. Update it in the same change; add a dated entry under `dev-docs/logs/`.

No dependency on MathNodes/meile — the name/mention in the log is historical
rationale only.
