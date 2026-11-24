#!/usr/bin/env bash
# The pack runner pool in this bundle (tetrix-collectors#1637; pack sandbox runtime spec §3.3, §5.1,
# §11.2, §16.2). The chart's Compose twin runs the same checks (tetrix-ee-helm-chart
# scripts/assert-pack-runner.sh).
#
# An outside data-source pack's code runs in collectors-pack-runner, so each check below keeps that
# code away from core or keeps the pool from failing an upgrade:
#   B1  the runner has no env_file, no anchor merge and no volume, and no healthcheck: Docker runs
#       every healthcheck as a process inside the container, which the runner's supervisor kills at
#       the next recycle and counts as a failed postcondition (the runner then exits 3).
#   B2  its environment is PACK_RUNNER_CORE_SERVICES=collectors-api,collectors-worker,
#       collectors-healthcheck and nothing else, and each name is a service of this file. Without
#       it, or with PACK_RUNNER_PEER_POLICY beside it, every runner refuses every lease.
#   B3  it is on pack-sandbox only, and pack-sandbox is internal: no route out, no DNS forwarding.
#   B4  its /scratch tmpfs is mounted exec, or native wheels cannot load from the lease's venv.
#   B5  its image line is ${TETRIX_IMAGE_ORIGIN-}deskree/tetrix-pack-runner:${PACK_RUNNER_IMAGE_TAG:-tag},
#       the form the chart's release generator reads pins from, and .env.example pins the same tag.
#   B6  the egress proxy's environment is the API URL (collectors-api on its PORT) and the denial
#       list of bare service names, nothing else, with no env_file and no anchor merge.
#   B7  api, worker and healthcheck are on default and pack-sandbox, nothing else is on
#       pack-sandbox, and the shared anchor names the runner service.
#   B8  the shared anchor's TETRIX_PACK_EGRESS_SERVICE is a bare name the proxy carries as an
#       alias on pack-sandbox alone, not a service name (tetrix-collectors#1645). Core resolves it
#       and appends 3128 itself. The service name answers with the proxy's default-network
#       address, which a runner cannot reach, so every lease with egress is refused.
#
# Usage:
#   scripts/assert-pack-runner-compose.sh              # check docker-compose.yml and .env.example
#   scripts/assert-pack-runner-compose.sh --self-test  # prove each check fails on its drift
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 2; }

python3 - "$ROOT" "$@" <<'PY'
import pathlib
import re
import sys

import yaml

root = pathlib.Path(sys.argv[1])
self_test = "--self-test" in sys.argv[2:]
CORE_SERVICES = "collectors-api,collectors-worker,collectors-healthcheck"
EGRESS_ENV = {"PACK_EGRESS_API_URL", "PACK_EGRESS_DENY_HOSTS"}


def block(text, service):
    m = re.search(rf"^  {re.escape(service)}:\n((?:    .*\n|\s*\n)+)", text, re.M)
    return m.group(1) if m else ""


def errors(text, env_text):
    e = []
    doc = yaml.safe_load(text)
    services, networks = doc.get("services") or {}, doc.get("networks") or {}
    run, egr = services.get("collectors-pack-runner"), services.get("collectors-pack-egress")
    if run is None or egr is None:
        return ["the bundle has no collectors-pack-runner or collectors-pack-egress service"]
    for key in ("env_file", "volumes", "healthcheck"):
        if key in run:
            e.append(f"B1 the runner has {key}")
    if "<<" in block(text, "collectors-pack-runner"):
        e.append("B1 the runner merges an anchor")
    if run.get("environment") != {"PACK_RUNNER_CORE_SERVICES": CORE_SERVICES}:
        e.append(f"B2 runner environment is {run.get('environment')!r}")
    for s in CORE_SERVICES.split(","):
        if s not in services:
            e.append(f"B2 PACK_RUNNER_CORE_SERVICES names {s}, which is not a service here")
    if run.get("networks") != ["pack-sandbox"] or (networks.get("pack-sandbox") or {}).get("internal") is not True:
        e.append(f"B3 runner networks {run.get('networks')!r}, pack-sandbox {networks.get('pack-sandbox')!r}")
    scratch = [t for t in run.get("tmpfs") or [] if t.split(":", 1)[0] == "/scratch"]
    opts = scratch[0].split(":", 1)[1].split(",") if scratch and ":" in scratch[0] else []
    if "exec" not in opts or "noexec" in opts:
        e.append(f"B4 /scratch tmpfs {scratch!r} is not mounted exec")
    m = re.fullmatch(r"\$\{TETRIX_IMAGE_ORIGIN-\}deskree/tetrix-pack-runner:\$\{PACK_RUNNER_IMAGE_TAG:-(.+)\}",
                     run.get("image", ""))
    pinned = re.search(r"^PACK_RUNNER_IMAGE_TAG=(\S+)\s*$", env_text, re.M)
    if not m or not pinned or m.group(1) != pinned.group(1):
        e.append(f"B5 runner image line {run.get('image')!r} is not the generator form, or .env.example "
                 f"pins {pinned.group(1) if pinned else None!r}")
    eenv = egr.get("environment") or {}
    env_block = re.search(r"^    environment:\n((?:      .*\n)*)", block(text, "collectors-pack-egress"), re.M)
    if set(eenv) != EGRESS_ENV or "env_file" in egr or not env_block or "<<" in env_block.group(1):
        e.append(f"B6 proxy environment is {sorted(eenv)} (env_file: {'env_file' in egr})")
    api_port = str(((services.get("collectors-api") or {}).get("environment") or {}).get("PORT", ""))
    if eenv.get("PACK_EGRESS_API_URL") != f"http://collectors-api:{api_port}":
        e.append(f"B6 PACK_EGRESS_API_URL {eenv.get('PACK_EGRESS_API_URL')!r} is not collectors-api on its PORT {api_port}")
    # A trailing `?` marks a service that may not run (a profile's): the proxy then accepts its
    # name not existing. Every other name must resolve before a private tunnel opens (collectors #1673).
    deny_names = str(eenv.get("PACK_EGRESS_DENY_HOSTS", "")).split(",")
    if not all(re.fullmatch(r"[a-z0-9-]+\??", h) for h in deny_names):
        e.append("B6 PACK_EGRESS_DENY_HOSTS is not bare service names, each optionally marked `?`")
    for h in deny_names:
        name = h.rstrip("?")
        profiled = bool((services.get(name) or {}).get("profiles"))
        if name in services and profiled != h.endswith("?"):
            e.append(f"B6 PACK_EGRESS_DENY_HOSTS marks {name} {'optional' if h.endswith('?') else 'required'}, but it {'runs only under a profile' if profiled else 'always runs'}")
    if egr.get("command") != ["pack-egress"]:
        e.append(f"B6 proxy command {egr.get('command')!r}")
    for s in CORE_SERVICES.split(","):
        if sorted((services.get(s) or {}).get("networks") or []) != ["default", "pack-sandbox"]:
            e.append(f"B7 {s} networks {(services.get(s) or {}).get('networks')!r}, not default + pack-sandbox")
    on_sandbox = {n for n, s in services.items() if "pack-sandbox" in (s.get("networks") or [])}
    if on_sandbox != set(CORE_SERVICES.split(",")) | {"collectors-pack-runner", "collectors-pack-egress"}:
        e.append(f"B7 on pack-sandbox: {sorted(on_sandbox)}")
    env = (services.get("collectors-worker") or {}).get("environment") or {}
    if env.get("TETRIX_PACK_RUNNER_SERVICE") != "collectors-pack-runner":
        e.append("B7 the shared anchor does not name the runner service")
    nets = egr.get("networks") or {}
    nets = nets if isinstance(nets, dict) else dict.fromkeys(nets)
    alias = env.get("TETRIX_PACK_EGRESS_SERVICE")
    if alias not in ((nets.get("pack-sandbox") or {}).get("aliases") or []) or alias in services or \
            alias in ((nets.get("default") or {}).get("aliases") or []):
        e.append(f"B8 TETRIX_PACK_EGRESS_SERVICE {alias!r} is not the proxy's alias on pack-sandbox alone "
                 f"(proxy networks {egr.get('networks')!r})")
    return e


compose = (root / "docker-compose.yml").read_text()
env_text = (root / ".env.example").read_text()
found = errors(compose, env_text)
if found:
    print("FAIL: the pack runner pool in docker-compose.yml / .env.example:")
    for f in found:
        print(f"  - {f}")
    sys.exit(1)
if not self_test:
    print("OK: pack runner pool B1-B8 (no core settings, no healthcheck, pack-sandbox only and internal, "
          "/scratch exec, generator-form pin matching .env.example, proxy env = API URL + denial list, "
          "core resolves the proxy by its pack-sandbox alias)")
    sys.exit(0)

RUN_ENV = "      PACK_RUNNER_CORE_SERVICES: collectors-api,collectors-worker,collectors-healthcheck\n"
CASES = {
    "B1 env_file on the runner": (RUN_ENV, RUN_ENV + "    env_file: .env\n"),
    "B1 the anchor on the runner": ("    environment:\n" + RUN_ENV, "    environment:\n      <<: *collectors-env\n" + RUN_ENV),
    "B1 a volume on the runner": (RUN_ENV, RUN_ENV + "    volumes:\n      - ./runtime:/runtime:ro\n"),
    "B1 a healthcheck on the runner": (RUN_ENV, RUN_ENV + '    healthcheck:\n      test: ["CMD", "true"]\n'),
    "B2 a second runner setting": (RUN_ENV, RUN_ENV + "      PACK_RUNNER_PEER_POLICY: networkpolicy\n"),
    "B2 a core service misspelt": ("collectors-api,collectors-worker,collectors-healthcheck\n",
                                   "collectors-api,collectors-workers,collectors-healthcheck\n"),
    "B3 the runner on default": ("    networks: [pack-sandbox]\n", "    networks: [default, pack-sandbox]\n"),
    "B3 pack-sandbox not internal": ("  pack-sandbox:\n    internal: true\n", "  pack-sandbox:\n    internal: false\n"),
    "B4 /scratch noexec": ("/scratch:rw,exec,", "/scratch:rw,noexec,"),
    "B5 a hard-coded runner tag": ("${PACK_RUNNER_IMAGE_TAG:-", "${PACK_RUNNER_TAG:-"),
    "B6 the DSN on the proxy": ("      PACK_EGRESS_API_URL:", "      TETRIX_CONTROL_PLANE_DSN: x\n      PACK_EGRESS_API_URL:"),
    "B6 the anchor on the proxy": ("      PACK_EGRESS_API_URL:", "      <<: *collectors-env\n      PACK_EGRESS_API_URL:"),
    "B7 the worker off pack-sandbox": ('    command: ["worker"]\n    networks: [default, pack-sandbox]\n',
                                       '    command: ["worker"]\n'),
    "B8 the alias removed": ("        aliases: [pack-egress]\n", ""),
    "B8 the alias on default too": ("      default:\n      pack-sandbox:\n",
                                    "      default:\n        aliases: [pack-egress]\n      pack-sandbox:\n"),
    "B8 the service name in the anchor": ("  TETRIX_PACK_EGRESS_SERVICE: pack-egress\n",
                                          "  TETRIX_PACK_EGRESS_SERVICE: collectors-pack-egress\n"),
    "B8 a port in the anchor": ("  TETRIX_PACK_EGRESS_SERVICE: pack-egress\n", "  TETRIX_PACK_EGRESS_SERVICE: pack-egress:3128\n"),
}
misses = 0
for name, (old, new) in CASES.items():
    if compose.count(old) != 1:
        print(f"  FIXTURE DRIFTED: {name} ({old!r} found {compose.count(old)} times)")
        misses += 1
        continue
    errs = errors(compose.replace(old, new), env_text)
    hit = any(err.startswith(name.split()[0]) for err in errs)
    misses += not hit
    print(f"  {'caught' if hit else 'MISSED'}: {name}" + (f"  ({errs[0]})" if errs else ""))
errs = errors(compose, env_text.replace("PACK_RUNNER_IMAGE_TAG=", "PACK_RUNNER_IMAGE_TAG=sha-0000000\n# was "))
print(f"  {'caught' if errs else 'MISSED'}: .env.example pins another runner tag")
misses += not errs
if misses:
    print(f"SELF-TEST FAIL: {misses} case(s) not handled")
    sys.exit(1)
print("SELF-TEST OK: every drift case is caught")
PY
