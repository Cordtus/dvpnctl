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


def test_cancel_wait_polls_until_deleted(m):
    real_sleep = m.time.sleep
    m.time.sleep = lambda s: None
    calls = {"n": 0}

    def status(sid):
        calls["n"] += 1
        return "inactive_pending" if calls["n"] <= 2 else None

    m.session_status = status
    real_tx = m.tx_with_retry
    m.tx_with_retry = lambda *a, **k: (_ for _ in ()).throw(
        AssertionError("must not re-broadcast cancel for inactive_pending"))
    try:
        m.cancel_session(1, wait=True)
    finally:
        m.time.sleep = real_sleep
        m.tx_with_retry = real_tx
    assert calls["n"] >= 3, "wait must poll past inactive_pending to deletion"


def test_bring_up_retries_stale_session(m):
    saved = {k: getattr(m, k) for k in (
        "unit_installed", "unit_name", "systemctl", "write_session_file",
        "start_session", "wait_for_iface", "connect_failed_already_exists",
        "unit_logs", "cancel_session")}
    m.unit_installed = lambda: True
    m.unit_name = lambda: "u.service"
    m.systemctl = lambda *a, **k: 0
    m.write_session_file = lambda sid: None
    starts = {"n": 0}
    poison_seen = []

    def start_session(cfg, node, reconcile=True, exclude=None):
        starts["n"] += 1
        if starts["n"] == 2:
            poison_seen.append(set(exclude or set()))
        return 100 if starts["n"] == 1 else 200

    m.start_session = start_session
    m.wait_for_iface = lambda timeout=15: False
    m.connect_failed_already_exists = lambda sid: sid == 100
    m.unit_logs = lambda n=20: "Error: session 100 already exists in database\n"
    cleared = []
    m.cancel_session = lambda sid, wait=False: cleared.append(sid)
    try:
        assert m.bring_up({"moniker": "M", "address": "a"}, {}, ) is False
    finally:
        for k, v in saved.items():
            setattr(m, k, v)
    assert starts["n"] == 2, "must start a fresh session after the stale-session error"
    assert cleared == [100], "must cancel the stale session"
    assert poison_seen == [{100}], "rejected id must be excluded from re-selection"


def test_connect_error_detection(m):
    real_logs = m.unit_logs
    m.unit_name = lambda: "u.service"
    m.unit_logs = lambda n=20: (
        "Started Sentinel dVPN\n"
        "Error: ... handshake request for session 63348179: ... "
        "session 63348179 already exists in database\n")
    assert m.connect_failed_already_exists(63348179)
    assert not m.connect_failed_already_exists(999)
    m.unit_logs = lambda n=20: "resolvconf: signature mismatch\n"
    assert not m.connect_failed_already_exists(1)
    m.unit_logs = real_logs

    m.unit_installed = lambda: True
    m.load_cfg = lambda: {"unit_name": "u.service"}
    slow = {"address": "slow", "moniker": "S", "country": "DE"}
    fast = {"address": "fast", "moniker": "F", "country": "DE"}
    m.probe_candidates = lambda cfg, nodes: [slow, fast]
    m.cached_speed = lambda addr, ttl: None
    sid_by_addr = {"slow": 11, "fast": 22}
    cur = {}

    def fake_bring(n, cfg):
        cur["addr"] = n["address"]
        return True

    m.bring_up = fake_bring
    m.measure_speed = lambda cfg: 1_000_000.0 if cur["addr"] == "slow" else 2_000_000.0
    m.read_session_file = lambda: sid_by_addr[cur["addr"]]
    m.record_speed = lambda addr, bps: None
    m.tear_down_iface = lambda cancel=True: None
    cleared = []
    m.cancel_session = lambda sid, wait=False: cleared.append((sid, wait))

    winner, bps = m.probe_and_select(
        {"speed_cache_ttl": 1, "speed_probe_count": 2}, [slow, fast])
    assert winner is fast and bps == 2_000_000.0
    assert (22, True) in cleared, "winner's handshaken probe session must be cleared"


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
    got, bps = m.probe_and_select({"speed_cache_ttl": 1}, [node])
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


def test_find_active_session_requires_corroboration(m):
    # one stale endpoint lists a deleted session as active; the other two do not.
    # Without corroboration the phantom gets reused and the node rejects connect.
    saved = {k: getattr(m, k) for k in ("run", "load_cfg", "cli_path", "cli_home")}
    m.load_cfg = lambda: {"rpc": "https://a", "cli_home": "/h"}
    m.cli_path = lambda: "/bin/cli"
    m.cli_home = lambda: "/h"
    stale = (
        "items:\n"
        "- base_session:\n"
        "    id: 6.3348021e+07\n"
        "    node_address: sentnode1target\n"
        "    status: 1\n")
    empty = "items: []\n"

    class P:
        def __init__(self, out):
            self.returncode = 0
            self.stdout = out

    calls = {"n": 0}

    def fake_run(cmd, **kw):
        url = cmd[cmd.index("--rpc.addrs") + 1]
        calls["n"] += 1
        return P(stale if url == "https://a" else empty)

    m.run = fake_run
    try:
        # only "https://a" reports it active; 2+ endpoints must agree -> None
        got = m.find_active_session("acct", "sentnode1target", timeout=0)
    finally:
        for k, v in saved.items():
            setattr(m, k, v)
    assert got is None, f"a single stale endpoint must not resurrect a session: {got}"

    # when a second endpoint agrees, it is usable again
    saved = {k: getattr(m, k) for k in ("run", "load_cfg", "cli_path", "cli_home")}
    m.load_cfg = lambda: {"rpc": "https://a", "cli_home": "/h"}
    m.cli_path = lambda: "/bin/cli"
    m.cli_home = lambda: "/h"
    m.run = lambda cmd, **kw: P(stale)
    try:
        assert m.find_active_session("acct", "sentnode1target", timeout=0) == 63348021
        # a poisoned id is never returned
        assert m.find_active_session("acct", "sentnode1target", timeout=0,
                                     exclude={63348021}) is None
    finally:
        for k, v in saved.items():
            setattr(m, k, v)


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
