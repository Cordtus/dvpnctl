#!/usr/bin/env python3
"""Self-checks for dvpnctl's selection/cancel/tx-error logic.

Run: python3 test_dvpnctl.py
No framework; each check stubs the module's I/O so nothing touches the chain.
"""
import importlib.util
from importlib.machinery import SourceFileLoader


def load():
    loader = SourceFileLoader("dvpnctl", "dvpnctl")
    spec = importlib.util.spec_from_loader("dvpnctl", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def test_clean_stderr(m):
    assert m.clean_stderr("sonic/ast only supports x\nreal error\n") == "real error\n"
    assert m.clean_stderr("real error\n") == "real error\n"


def test_cancel_skips_when_inactive(m):
    sent = []
    m.tx_with_retry = lambda *a, **k: sent.append(a)
    m.session_status = lambda sid: "inactive_pending"
    m.cancel_session(1)
    assert sent == [], "must not broadcast cancel for an inactive session"
    m.session_status = lambda sid: None
    m.cancel_session(1)
    assert sent == [], "must not broadcast cancel for a gone session"


def test_cancel_broadcasts_when_active(m):
    sent = []
    m.tx_with_retry = lambda *a, **k: sent.append(a)
    m.session_status = lambda sid: 1
    m.cancel_session(1)
    assert len(sent) == 1 and sent[0][0] == ["session-cancel", "1"], sent


def test_probe_missing_unit_falls_back(m):
    m.unit_installed = lambda: False
    m.load_cfg = lambda: {"unit_name": "u.service"}
    m.best_node = lambda cfg, nodes, exclude=None: nodes[0]
    nodes = [{"address": "a", "moniker": "M", "downlink": 1}]
    assert m.probe_and_select({"speed_cache_ttl": 1}, nodes) == (nodes[0], None)


def test_probe_uses_cached_speed(m):
    m.unit_installed = lambda: True
    m.load_cfg = lambda: {"unit_name": "u.service"}
    node = {"address": "a", "moniker": "M", "country": "GB"}
    m.probe_candidates = lambda cfg, nodes: [node]
    m.cached_speed = lambda addr, ttl: 1_000_000.0
    m.bring_up = lambda n, cfg: (_ for _ in ()).throw(AssertionError("re-probed a cached node"))
    got, bps = m.probe_and_select({"speed_cache_ttl": 1}, [node], verbose=False)
    assert got is node and bps == 1_000_000.0


def test_recover_backup_writes_on_match(m, tmp):
    import json, os
    m.CFG_DIR = tmp
    m.WALLET_BACKUP = os.path.join(tmp, "wallet-backup.json")
    m.my_address = lambda: "sent1abc"
    m.derive_address = lambda mn: "sent1abc"
    m.getpass = type("G", (), {"getpass": staticmethod(lambda prompt="": "word " * 12)})()
    m.load_cfg = lambda: {"key_name": "main"}
    m.recover_backup()
    saved = json.load(open(m.WALLET_BACKUP))
    assert saved["address"] == "sent1abc" and saved["mnemonic"].strip()


def test_session_file_exclude_flags(m, tmp):
    import os
    m.CFG_DIR = tmp
    m.SESSION_FILE = os.path.join(tmp, "session.env")
    m.cli_path = lambda: "/x/sentinel-dvpncli"
    m.working_rpc = lambda sid: "rpc"
    base = {"root_home": "/var/lib/dvpnctl", "iface": "wg0"}
    m.load_cfg = lambda: {**base, "exclude_lan": True}
    m.write_session_file(7)
    assert "DVPNCTL_EXCLUDE=\n" in open(m.SESSION_FILE).read()
    m.load_cfg = lambda: {**base, "exclude_lan": False}
    m.write_session_file(7)
    assert open(m.SESSION_FILE).read().count("--wireguard.exclude-addrs=") == 2


def test_session_report(m):
    m.cli = lambda *a, **k: (
        "base_session:\n"
        "  download_bytes: \"341079180\"\n"
        "  upload_bytes: \"591056848\"\n"
        "  id: 6.2861151e+07\n"
        "  max_bytes: \"5000000000\"\n"
        "price:\n"
        "  quote_value: \"12500000\"\n")
    m.human_bytes = lambda n: f"{n}B"
    report = m.session_report(62861151)
    assert report.startswith("session 62861151: "), report
    assert "cost ~11.6517 DVPN" in report, report
    assert "refund ~50.8483 of 62.5000 DVPN escrowed" in report, report


def test_recover_backup_rejects_mismatch(m, tmp):
    import os
    m.CFG_DIR = tmp
    m.WALLET_BACKUP = os.path.join(tmp, "wallet-backup.json")
    m.my_address = lambda: "sent1abc"
    m.derive_address = lambda mn: "sent1other"
    m.getpass = type("G", (), {"getpass": staticmethod(lambda prompt="": "word " * 12)})()
    try:
        m.recover_backup()
    except SystemExit:
        pass
    else:
        raise AssertionError("mismatched mnemonic must abort")
    assert not os.path.exists(m.WALLET_BACKUP)


if __name__ == "__main__":
    import tempfile
    mod = load()
    for name, fn in sorted(globals().items()):
        if not name.startswith("test_"):
            continue
        if "tmp" in fn.__code__.co_varnames[:fn.__code__.co_argcount]:
            with tempfile.TemporaryDirectory() as d:
                fn(mod, d)
        else:
            fn(mod)
        print(f"ok {name}")
    print("all checks passed")
