#!/usr/bin/env bash
# This compose file must carry the SAME collectors platform-health and identity
# settings as the Helm chart's own Compose twin (tetrix-ee-helm-chart
# deploy/docker/docker-compose.yml) — for the keys below, on the same services,
# with the same values.
#
# WHY: this repository's docker-compose.yml is hand-maintained; it does not take
# deploy/docker from the chart bundle. tetrix-install#51: chart 1.0.6/1.0.7/1.0.8
# added four collectors settings to the chart's compose and none reached this
# file, so a public compose install silently ran with
#   TETRIX_MCP_API_BASE_URL          unset -> MCP `platform_versions` answers "not configured"
#   TETRIX_API_SERVICE_READYZ_URLS   unset -> /health/services lists only DB + daemon rows
#   TETRIX_MCP_API_TIMEOUT_S         3 s   -> one hung probe blanks the whole answer
#   TETRIX_IDENTITY_SALT             not wired at all; a per-service value would silently
#                                    break admin-mapped email same_as (collectors#971)
# Nothing failed; the settings were simply absent. This gate makes the next such
# gap a red CI check instead of a reviewer's catch.
#
# HOW: the chart repository is private and this public repository's CI has no
# secret for it, so the chart's values are recorded in
# scripts/chart-compose-collectors-env.lock.json (chart ref + commit + version +
# the raw per-service values + the .env.example documented values). Every run
#   1. checks this compose + .env.example against the lock (always — offline);
#   2. checks the invariants the values exist for, independently of the lock
#      (one shared salt in the x-collectors-env anchor, the four-entry readyz map
#      points at real services of THIS file on a port they listen on, the MCP
#      base URL is the api service, the timeout is >= 6 s while the map is set);
#   3. when the chart is reachable (--chart-dir, or `gh api` with a token that
#      can read the chart repo), re-derives the values from the chart at the
#      lock's ref and fails if the LOCK is stale — i.e. the chart moved on and
#      this repo has not followed. `--update-lock` rewrites the lock from it.
# Service names are compared through the lock's `service_map` (chart name ->
# name in this file; null = this bundle does not ship that service), so a
# rename here is an explicit allowlist entry, not a silent mismatch.
#
# Usage:
#   scripts/assert-chart-compose-collectors-env.sh                 # lock + live chart if reachable
#   scripts/assert-chart-compose-collectors-env.sh --require-chart # fail if the chart is unreachable
#   scripts/assert-chart-compose-collectors-env.sh --chart-dir ../tetrix-ee-helm-chart [--chart-ref REF]
#   scripts/assert-chart-compose-collectors-env.sh --chart-ref v1.0.8 --update-lock
#   scripts/assert-chart-compose-collectors-env.sh --self-test     # proves the gate fails on drift
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 2; }

python3 - "$ROOT" "$@" <<'PY'
import argparse
import copy
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.parse

import yaml

ROOT = pathlib.Path(sys.argv[1])
LOCK_PATH = ROOT / "scripts" / "chart-compose-collectors-env.lock.json"
KEYS = (
    "TETRIX_MCP_API_BASE_URL",
    "TETRIX_API_SERVICE_READYZ_URLS",
    "TETRIX_MCP_API_TIMEOUT_S",
    "TETRIX_IDENTITY_SALT",
)
# The services that must share one salt (chart#397): api, worker, dispatcher, mcp.
SALT_COMMANDS = ("api", "worker", "dispatcher", "mcp")
READYZ_ENTRIES = {"api", "dispatcher", "mcp", "worker"}
MIN_TIMEOUT_WITH_MAP = 6
IN_GHA = os.environ.get("GITHUB_ACTIONS") == "true"
INTERP = re.compile(r"^\$\{([A-Z0-9_]+):-(.*)\}$", re.S)


def note(msg):
    print(f"::notice::{msg}" if IN_GHA else f"NOTE: {msg}")


def warn(msg):
    print(f"::warning::{msg}" if IN_GHA else f"WARN: {msg}")


# ── compose parsing ──────────────────────────────────────────────────────────
def services_of(compose_text):
    doc = yaml.safe_load(compose_text) or {}  # SafeLoader resolves `<<: *anchor` merges
    return doc.get("services") or {}


def env_of(svc):
    env = (svc or {}).get("environment") or {}
    if isinstance(env, list):
        out = {}
        for item in env:
            k, _, v = str(item).partition("=")
            out[k] = v
        return out
    return {k: ("" if v is None else str(v)) for k, v in env.items()}


def command_of(svc):
    cmd = (svc or {}).get("command")
    if isinstance(cmd, list) and cmd:
        return str(cmd[0])
    if isinstance(cmd, str) and cmd.strip():
        return cmd.split()[0]
    return None


def extract(compose_text):
    """{service: {KEY: raw value}} for every service carrying one of KEYS (raw = uninterpolated)."""
    out = {}
    for name, svc in services_of(compose_text).items():
        env = env_of(svc)
        got = {k: env[k] for k in KEYS if k in env}
        if got:
            out[name] = got
    return out


def default_of(raw):
    m = INTERP.match(raw or "")
    return (m.group(1), m.group(2)) if m else (None, raw)


# ── .env.example parsing ─────────────────────────────────────────────────────
def env_vars_for(expected):
    names = set()
    for vals in expected.values():
        for raw in vals.values():
            var, _ = default_of(raw)
            if var:
                names.add(var)
    return sorted(names)


def env_example_values(text, names):
    """{VAR: {"value": str, "active": bool}} for the documented (commented or active) lines."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"^\s*(#\s*)?([A-Z0-9_]+)=(.*)$", line)
        if m and m.group(2) in names and m.group(2) not in out:
            out[m.group(2)] = {"value": m.group(3).strip(), "active": m.group(1) is None}
    return out


# ── service-name mapping ─────────────────────────────────────────────────────
def map_hosts(value, service_map):
    for chart_svc, ours in service_map.items():
        if ours and ours != chart_svc:
            value = re.sub(r"(?<=//)" + re.escape(chart_svc) + r"(?=[:/\"])", ours, value)
    return value


def mapped_expected(lock_like):
    """The chart's per-service values, re-keyed and re-hosted to this file's service names."""
    smap = lock_like.get("service_map") or {}
    out, errors = {}, []
    for chart_svc, vals in (lock_like.get("expected") or {}).items():
        if chart_svc not in smap:
            errors.append(
                f"chart service {chart_svc!r} carries {sorted(vals)} but has no service_map entry in "
                f"{LOCK_PATH.name} (map it to this file's service name, or to null if this bundle "
                "does not ship it)"
            )
            continue
        ours = smap[chart_svc]
        if ours is None:
            continue
        out[ours] = {k: map_hosts(v, smap) for k, v in vals.items()}
    return out, errors


# ── the checks ───────────────────────────────────────────────────────────────
def check_against(expected, actual, what):
    errors = []
    for key in KEYS:
        want = {s for s, v in expected.items() if key in v}
        have = {s for s, v in actual.items() if key in v}
        for s in sorted(want - have):
            errors.append(f"{key} missing on service {s!r} (the {what} sets it: {expected[s][key]!r})")
        for s in sorted(have - want):
            errors.append(f"{key} set on service {s!r}, which the {what} does not set it on")
        for s in sorted(want & have):
            if expected[s][key] != actual[s][key]:
                errors.append(
                    f"{key} on {s!r} drifted from the {what}:\n"
                    f"        here:  {actual[s][key]!r}\n"
                    f"        {what}: {expected[s][key]!r}"
                )
    return errors


def check_env_example(env_text, expected, chart_env, smap):
    errors = []
    names = env_vars_for(expected)
    have = env_example_values(env_text, names)
    for var in names:
        if var not in have:
            errors.append(f".env.example does not document {var} (add the commented `# {var}=…` entry)")
            continue
        # The documented value must be the compose default, so copying the comment is a no-op.
        defaults = {default_of(raw)[1] for vals in expected.values() for raw in vals.values()
                    if default_of(raw)[0] == var}
        if have[var]["value"] and have[var]["value"] not in defaults:
            errors.append(
                f".env.example documents {var}={have[var]['value']!r}, which is not the compose "
                f"default {sorted(defaults)!r}"
            )
        if chart_env is not None and var in chart_env:
            want = map_hosts(chart_env[var], smap)
            if have[var]["value"] != want:
                errors.append(
                    f".env.example {var} drifted from the chart's .env.example: "
                    f"here {have[var]['value']!r}, chart {want!r}"
                )
    salt = have.get("TETRIX_IDENTITY_SALT")
    if salt and salt["active"] and salt["value"]:
        errors.append(
            ".env.example sets an ACTIVE non-empty TETRIX_IDENTITY_SALT. It must stay off by default: "
            "on an install that already holds identity data a salt re-keys every stored email hash "
            "(one-way; admin-mapped emails must be re-entered)."
        )
    return errors


def check_invariants(compose_text):
    """What the values are FOR, checked on this file alone (no lock, no chart)."""
    errors = []
    services = services_of(compose_text)
    actual = extract(compose_text)
    by_cmd = {}
    for name, svc in services.items():
        c = command_of(svc)
        if c:
            by_cmd.setdefault(c, []).append(name)

    # 1. One shared salt, defined once, in the x-collectors-env anchor.
    salt_lines = re.findall(r"^(\s*)TETRIX_IDENTITY_SALT:\s*(.*)$", compose_text, re.M)
    if len(salt_lines) != 1:
        errors.append(
            f"TETRIX_IDENTITY_SALT must be defined exactly ONCE (in the x-collectors-env anchor) so no "
            f"service can drift; found {len(salt_lines)} definitions"
        )
    else:
        anchor = re.search(r"^x-collectors-env:\s*&collectors-env\n((?:[ \t]+.*\n|\n)+)", compose_text, re.M)
        if not anchor or not re.search(r"^\s+TETRIX_IDENTITY_SALT:", anchor.group(1), re.M):
            errors.append("TETRIX_IDENTITY_SALT is not in the x-collectors-env anchor")
    salt_values = {v["TETRIX_IDENTITY_SALT"] for v in actual.values() if "TETRIX_IDENTITY_SALT" in v}
    if len(salt_values) > 1:
        errors.append(f"TETRIX_IDENTITY_SALT differs between services: {sorted(salt_values)!r}")
    for cmd in SALT_COMMANDS:
        for name in by_cmd.get(cmd, []) or [None]:
            if name is None:
                errors.append(f"no service runs command {cmd!r}; cannot verify it receives the shared salt")
            elif "TETRIX_IDENTITY_SALT" not in actual.get(name, {}):
                errors.append(f"service {name!r} ({cmd}) does not receive TETRIX_IDENTITY_SALT")

    # 2. The readyz map: exactly the four entries, each on a real service of THIS file, on a port it
    #    listens on, at /readyz.
    readyz_holders = [s for s, v in actual.items() if "TETRIX_API_SERVICE_READYZ_URLS" in v]
    map_set = False
    for holder in readyz_holders:
        if command_of(services[holder]) != "api":
            errors.append(f"TETRIX_API_SERVICE_READYZ_URLS is set on {holder!r}, which is not the api service")
        _, default = default_of(actual[holder]["TETRIX_API_SERVICE_READYZ_URLS"])
        try:
            rmap = json.loads(default)
        except ValueError as exc:
            errors.append(f"TETRIX_API_SERVICE_READYZ_URLS default on {holder!r} is not JSON: {exc}")
            continue
        map_set = bool(rmap)
        if set(rmap) != READYZ_ENTRIES:
            errors.append(
                f"TETRIX_API_SERVICE_READYZ_URLS must carry exactly {sorted(READYZ_ENTRIES)}; got {sorted(rmap)}"
            )
        for entry, url in sorted(rmap.items()):
            u = urllib.parse.urlparse(url)
            target = services.get(u.hostname or "")
            if target is None:
                errors.append(f"readyz[{entry!r}] -> {url}: {u.hostname!r} is not a service in this compose file")
                continue
            if command_of(target) != entry:
                errors.append(
                    f"readyz[{entry!r}] -> {url}: service {u.hostname!r} runs {command_of(target)!r}, not {entry!r}"
                )
            env = env_of(target)
            ports = {env.get(k) for k in ("PORT", "SIDECAR_PORT", "TETRIX_MCP_SIDECAR_PORT") if env.get(k)}
            if str(u.port) not in ports:
                errors.append(
                    f"readyz[{entry!r}] -> {url}: port {u.port} is not a port {u.hostname!r} serves "
                    f"(PORT/SIDECAR_PORT: {sorted(ports)})"
                )
            if u.path != "/readyz":
                errors.append(f"readyz[{entry!r}] -> {url}: path must be /readyz")
    if not readyz_holders:
        errors.append("no service sets TETRIX_API_SERVICE_READYZ_URLS")

    # 3. The MCP reads the api service's /health/services, with a timeout that survives one hung probe.
    for s, vals in actual.items():
        if "TETRIX_MCP_API_BASE_URL" in vals:
            _, base = default_of(vals["TETRIX_MCP_API_BASE_URL"])
            u = urllib.parse.urlparse(base)
            target = services.get(u.hostname or "")
            if target is None or command_of(target) != "api":
                errors.append(f"TETRIX_MCP_API_BASE_URL on {s!r} ({base}) does not point at the api service")
            elif str(u.port) != env_of(target).get("PORT"):
                errors.append(f"TETRIX_MCP_API_BASE_URL on {s!r} ({base}) is not on the api service's PORT")
        if "TETRIX_MCP_API_TIMEOUT_S" in vals and map_set:
            _, t = default_of(vals["TETRIX_MCP_API_TIMEOUT_S"])
            try:
                ok = float(t) >= MIN_TIMEOUT_WITH_MAP
            except ValueError:
                ok = False
            if not ok:
                errors.append(
                    f"TETRIX_MCP_API_TIMEOUT_S on {s!r} defaults to {t!r}; with the readyz map set it must be "
                    f">= {MIN_TIMEOUT_WITH_MAP} s (one hung service holds the aggregate ~4 s)"
                )
    for cmd in ("mcp",):
        for name in by_cmd.get(cmd, []):
            for key in ("TETRIX_MCP_API_BASE_URL", "TETRIX_MCP_API_TIMEOUT_S"):
                if key not in actual.get(name, {}):
                    errors.append(f"service {name!r} ({cmd}) does not set {key}")
    return errors


def run_checks(compose_text, env_text, lock, chart=None):
    """All errors for this compose + .env.example against the lock (and the live chart, if given)."""
    errors = []
    expected, map_errors = mapped_expected(lock)
    errors += map_errors
    actual = extract(compose_text)
    errors += check_against(expected, actual, "chart lock")
    errors += check_env_example(env_text, expected, lock.get("env_example"), lock.get("service_map") or {})
    errors += check_invariants(compose_text)
    if chart is not None:
        live = {"service_map": lock.get("service_map") or {}, "expected": chart["expected"]}
        live_expected, live_map_errors = mapped_expected(live)
        errors += live_map_errors
        # Read as: the LOCK (standing in for "here") against the live chart.
        stale = check_against(live_expected, expected, "live chart")
        if stale or lock.get("env_example") != chart["env_example"]:
            errors.append(
                f"{LOCK_PATH.name} is STALE: the chart at {chart['ref']} ({chart.get('commit') or '?'}) "
                "no longer carries the locked values. Mirror the chart's change into docker-compose.yml / "
                ".env.example, then rerun with --update-lock."
            )
            errors += ["  " + e for e in stale]
        errors += check_against(live_expected, actual, "live chart")
        errors += check_env_example(env_text, expected, chart["env_example"], lock.get("service_map") or {})
    return sorted(set(errors), key=errors.index)


# ── the chart source ─────────────────────────────────────────────────────────
def chart_from_texts(compose_text, env_text, chart_yaml_text, ref, commit):
    expected = extract(compose_text)
    names = env_vars_for(expected)
    env_vals = {k: v["value"] for k, v in env_example_values(env_text or "", names).items()}
    m = re.search(r"^version:\s*(\S+)", chart_yaml_text or "", re.M)
    return {
        "expected": expected,
        "env_example": env_vals,
        "version": m.group(1).strip("\"'") if m else None,
        "ref": ref,
        "commit": commit,
    }


def load_chart_dir(chart_dir, ref, lock):
    d = pathlib.Path(chart_dir)
    paths = (lock["chart_path"], lock["chart_env_example_path"], "Chart.yaml")
    if ref:
        def show(p):
            return subprocess.run(["git", "-C", str(d), "show", f"{ref}:{p}"], check=True,
                                  capture_output=True, text=True).stdout
        texts = [show(p) for p in paths]
        commit = subprocess.run(["git", "-C", str(d), "rev-parse", f"{ref}^{{commit}}"], check=True,
                                capture_output=True, text=True).stdout.strip()
    else:
        texts = [(d / p).read_text() for p in paths]
        commit = subprocess.run(["git", "-C", str(d), "rev-parse", "HEAD"],
                                capture_output=True, text=True).stdout.strip() or None
        ref = f"{d} (working tree)"
    return chart_from_texts(*texts, ref, commit)


def load_chart_gh(ref, lock):
    repo = lock["chart_repo"]

    def get(p):
        q = urllib.parse.quote(ref, safe="")
        return subprocess.run(
            ["gh", "api", "-H", "Accept: application/vnd.github.raw", f"repos/{repo}/contents/{p}?ref={q}"],
            check=True, capture_output=True, text=True, timeout=60,
        ).stdout
    texts = [get(p) for p in (lock["chart_path"], lock["chart_env_example_path"], "Chart.yaml")]
    commit = subprocess.run(
        ["gh", "api", f"repos/{repo}/commits/{urllib.parse.quote(ref, safe='')}", "--jq", ".sha"],
        check=True, capture_output=True, text=True, timeout=60,
    ).stdout.strip()
    return chart_from_texts(*texts, ref, commit)


# ── self-test: the gate must FAIL on each kind of drift it exists for ─────────
def self_test(compose_text, env_text, lock):
    base = run_checks(compose_text, env_text, lock)
    if base:
        print("SELF-TEST FAIL: the unmodified tree does not pass:\n  " + "\n  ".join(base))
        return 1

    def sub(text, old, new, count=1):
        assert old in text, f"self-test fixture drifted: {old!r} not found"
        return text.replace(old, new, count)

    salt_anchor = "  TETRIX_IDENTITY_SALT: ${TETRIX_IDENTITY_SALT:-}\n"
    readyz_worker = '"worker":"http://collectors-worker:9090/readyz"'
    cases = [
        ("salt dropped from the shared anchor", sub(compose_text, salt_anchor, ""), env_text, lock),
        ("salt set per service (worker only)",
         sub(sub(compose_text, salt_anchor, ""),
             "      VAULT_ADDR: http://vault:8200\n      # VAULT_TOKEN + VAULT_TENANT_TOKEN_ROLE",
             "      VAULT_ADDR: http://vault:8200\n      TETRIX_IDENTITY_SALT: ${TETRIX_IDENTITY_SALT:-}\n"
             "      # VAULT_TOKEN + VAULT_TENANT_TOKEN_ROLE"), env_text, lock),
        ("salt given a non-empty default",
         sub(compose_text, "${TETRIX_IDENTITY_SALT:-}", "${TETRIX_IDENTITY_SALT:-x}"), env_text, lock),
        ("MCP timeout back to 3 s",
         sub(compose_text, "${COLLECTORS_MCP_API_TIMEOUT_S:-6}", "${COLLECTORS_MCP_API_TIMEOUT_S:-3}"),
         env_text, lock),
        ("MCP base URL removed",
         sub(compose_text, "      TETRIX_MCP_API_BASE_URL: ${COLLECTORS_MCP_API_BASE_URL:-http://collectors-api:8080}\n", ""),
         env_text, lock),
        ("readyz map loses an entry",
         sub(compose_text, ',' + readyz_worker, ""), env_text, lock),
        ("readyz worker on the wrong port",
         sub(compose_text, readyz_worker, '"worker":"http://collectors-worker:8080/readyz"'), env_text, lock),
        ("readyz points at a service this file does not have",
         sub(compose_text, readyz_worker, '"worker":"http://collectors-workers:9090/readyz"'), env_text, lock),
        (".env.example loses the salt entry", compose_text, sub(env_text, "# TETRIX_IDENTITY_SALT=\n", ""), lock),
        (".env.example activates a salt", compose_text,
         sub(env_text, "# TETRIX_IDENTITY_SALT=\n", "TETRIX_IDENTITY_SALT=abc\n"), lock),
    ]
    # A stale lock: the chart moved the timeout to 8 s and this repo did not follow.
    live = {"expected": copy.deepcopy(lock["expected"]), "env_example": dict(lock["env_example"]),
            "ref": "self-test", "commit": None}
    for vals in live["expected"].values():
        if "TETRIX_MCP_API_TIMEOUT_S" in vals:
            vals["TETRIX_MCP_API_TIMEOUT_S"] = "${COLLECTORS_MCP_API_TIMEOUT_S:-8}"
    # Compose-shape drifts the lock-free invariants must ALSO catch on their own (so a lock refreshed
    # from a broken chart, or a lock edited by hand, still cannot wave a broken map/salt through).
    invariant_cases = {
        "salt dropped from the shared anchor", "salt set per service (worker only)",
        "MCP timeout back to 3 s", "MCP base URL removed", "readyz map loses an entry",
        "readyz worker on the wrong port", "readyz points at a service this file does not have",
    }
    fails = 0
    for name, ctext, etext, lk in cases:
        errs = run_checks(ctext, etext, lk)
        status = "caught" if errs else "MISSED"
        fails += not errs
        if name in invariant_cases:
            inv = check_invariants(ctext)
            fails += not inv
            status += " (lock + invariants)" if inv else " (lock only; invariants MISSED)"
        print(f"  {status}: {name}" + (f"  ({errs[0].splitlines()[0]})" if errs else ""))
    errs = run_checks(compose_text, env_text, lock, chart=live)
    print(f"  {'caught' if errs else 'MISSED'}: chart moved on, lock and compose did not" +
          (f"  ({errs[0].splitlines()[0]})" if errs else ""))
    fails += not errs

    # The allowlist: a service renamed HERE passes once the lock maps it — and only then.
    renamed = compose_text.replace("  collectors-worker:\n", "  collectors-bg-worker:\n").replace(
        "//collectors-worker:", "//collectors-bg-worker:")
    renamed_env = env_text.replace("//collectors-worker:", "//collectors-bg-worker:")
    unmapped = run_checks(renamed, renamed_env, lock)
    print(f"  {'caught' if unmapped else 'MISSED'}: service renamed without a service_map entry")
    fails += not unmapped
    mapped_lock = copy.deepcopy(lock)
    mapped_lock["service_map"]["collectors-worker"] = "collectors-bg-worker"
    mapped = run_checks(renamed, renamed_env, mapped_lock)
    print(f"  {'passes' if not mapped else 'WRONGLY FAILS'}: same rename with service_map "
          f"collectors-worker -> collectors-bg-worker" + (f"  ({mapped[0]})" if mapped else ""))
    fails += bool(mapped)
    if fails:
        print(f"SELF-TEST FAIL: {fails} case(s) not handled")
        return 1
    print("SELF-TEST OK: every drift case is caught and the service_map allowlist works")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="assert-chart-compose-collectors-env.sh")
    ap.add_argument("--compose", default=str(ROOT / "docker-compose.yml"))
    ap.add_argument("--env-example", default=str(ROOT / ".env.example"))
    ap.add_argument("--chart-dir", help="a tetrix-ee-helm-chart checkout (reads deploy/docker from it)")
    ap.add_argument("--chart-ref", help="chart git ref to compare (default: the lock's chart_ref)")
    ap.add_argument("--require-chart", action="store_true", help="fail if the live chart cannot be read")
    ap.add_argument("--update-lock", action="store_true", help="rewrite the lock from the live chart")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args(argv)

    lock = json.loads(LOCK_PATH.read_text())
    compose_text = pathlib.Path(a.compose).read_text()
    env_text = pathlib.Path(a.env_example).read_text()

    if a.self_test:
        return self_test(compose_text, env_text, lock)

    ref = a.chart_ref or (None if a.chart_dir else lock["chart_ref"])
    chart, why = None, None
    try:
        chart = load_chart_dir(a.chart_dir, ref, lock) if a.chart_dir else load_chart_gh(ref, lock)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError, OSError) as exc:
        detail = getattr(exc, "stderr", None) or str(exc)
        why = detail.strip().splitlines()[-1] if detail.strip() else type(exc).__name__
    if chart is None:
        msg = (f"chart {lock['chart_repo']}@{ref} is not readable here ({why}); checked against the lock "
               f"recorded from {lock['chart_ref']} @ {lock['chart_commit'][:12]} (chart {lock['chart_version']}) only")
        if a.require_chart or a.update_lock:
            print(f"ERROR: {msg}", file=sys.stderr)
            return 2
        note(msg)

    if a.update_lock:
        lock.update({
            # A local `origin/<branch>` is recorded as `<branch>` so `gh api` can resolve it later.
            "chart_ref": re.sub(r"^(refs/remotes/)?origin/", "", a.chart_ref) if a.chart_ref else lock["chart_ref"],
            "chart_commit": chart["commit"],
            "chart_version": chart["version"],
            "expected": chart["expected"],
            "env_example": chart["env_example"],
        })
        LOCK_PATH.write_text(json.dumps(lock, indent=2) + "\n")
        print(f"updated {LOCK_PATH.relative_to(ROOT)} from {chart['ref']} @ {chart['commit']} (chart {chart['version']})")

    errors = run_checks(compose_text, env_text, lock, chart)

    if not re.fullmatch(r"v\d+\.\d+\.\d+", lock["chart_ref"]):
        warn(f"the chart lock points at {lock['chart_ref']!r}, not a released chart tag; re-point it at the "
             "released tag (--chart-ref vX.Y.Z --update-lock) once the chart ships")
    version = (ROOT / "VERSION").read_text().strip()
    if lock.get("chart_version") and lock["chart_version"] != version:
        note(f"VERSION is {version}; the collectors env block is locked to chart {lock['chart_version']}")

    if errors:
        print("FAIL: docker-compose.yml / .env.example drifted from the chart's deploy/docker for "
              + ", ".join(KEYS) + ":")
        for e in errors:
            print(f"  - {e}")
        return 1
    src = f"live chart {chart['ref']} @ {(chart['commit'] or '?')[:12]} and the lock" if chart else "the lock"
    print(f"OK: {', '.join(KEYS)} match {src} on "
          f"{', '.join(sorted(mapped_expected(lock)[0]))}; invariants hold (one shared salt, four-entry "
          "readyz map on this file's services, MCP base URL + >= 6 s timeout)")
    return 0


sys.exit(main(sys.argv[2:]))
PY
