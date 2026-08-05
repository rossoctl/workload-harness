#!/usr/bin/env python3
"""Merge a resolved AuthBridge plugin selection into the operator-rendered
authbridge config.yaml.

Reads:
  - --plugins-dir:    directory containing per-plugin <name>.yaml fragments
                      (already envsubst'd by apply-pipeline.sh)
  - --plugins:        space-separated `name[:policy]` tokens; policy ∈
                      {enforce, observe, off}; default policy is enforce
  - --config-file:    optional flat-map YAML overlay keyed by plugin name;
                      values are deep-merged into each plugin's config block
                      (see AUTHBRIDGE_PIPELINE_SPEC.md §4.5)
  - --prompt-file:    optional path to intent_prompt.txt; injected as the
                      ibac plugin's `system_prompt` when ibac is in the
                      resolved selection with policy enforce or observe
  - stdin:            the operator's current config.yaml content

Writes the merged YAML to stdout.

The script enumerates every supported plugin (the seven listed below),
not just the ones the user named. Plugins not in the resolved selection
get emitted with `on_error: off` so the framework skips dispatch for
them — required because the operator base config enables plugins by
default. See AUTHBRIDGE_PIPELINE_SPEC.md §4.3.

Idempotent: re-running with the same selection produces byte-identical
YAML (the apply-pipeline.sh sha-compare short-circuit then skips the
kubectl apply and reload-wait).
"""

import argparse
import copy
import sys
from pathlib import Path
from typing import Any

import yaml

# Plugin metadata table. Order within each list is the canonical
# ordering enforced by AuthBridge (`pipeline.New`); see
# AUTHBRIDGE_PIPELINE_SPEC.md §4.2.
INBOUND_ORDER: list[str] = [
    "a2a-parser",       # before auth: populates Session.LastIntent()
    "jwt-validation",   # gate
]

OUTBOUND_ORDER: list[str] = [
    "token-exchange",   # gate (mutex with token-broker)
    "token-broker",     # gate (mutex with token-exchange)
    "inference-parser", # observe-only, after token gate
    "mcp-parser",       # observe-only, after token gate
    "sparc",            # semantic pre-execution guardrail; reads parser slots
    "ibac",             # intent-based access control; reads parser extension slots
]

CHAIN_FOR: dict[str, str] = {p: "inbound" for p in INBOUND_ORDER}
CHAIN_FOR.update({p: "outbound" for p in OUTBOUND_ORDER})

VALID_POLICIES = ("enforce", "observe", "off")

# token-exchange and token-broker both claim ClaimAuthorizationHeader,
# so they cannot both be active in the same chain.
MUTEX_PAIRS: list[tuple[str, str]] = [
    ("token-exchange", "token-broker"),
]


def parse_plugins(spec: str) -> dict[str, str]:
    """Parse a `PIPELINE_PLUGINS` string into {name: policy}."""
    resolved: dict[str, str] = {}
    for tok in spec.split():
        if ":" in tok:
            name, policy = tok.split(":", 1)
        else:
            name, policy = tok, "enforce"
        if name not in CHAIN_FOR:
            print(f"ERROR: unknown plugin '{name}'", file=sys.stderr)
            sys.exit(2)
        if policy not in VALID_POLICIES:
            print(
                f"ERROR: unknown policy '{policy}' for plugin '{name}' "
                f"(want one of: {', '.join(VALID_POLICIES)})",
                file=sys.stderr,
            )
            sys.exit(2)
        resolved[name] = policy
    return resolved


def deep_merge(dst: dict[str, Any], src: dict[str, Any]) -> dict[str, Any]:
    """Recursively merge src into dst (in place); src wins on leaf conflicts."""
    for key, val in src.items():
        if key in dst and isinstance(dst[key], dict) and isinstance(val, dict):
            deep_merge(dst[key], val)
        else:
            dst[key] = val
    return dst


def load_fragment(plugins_dir: Path, name: str) -> dict[str, Any]:
    """Load plugins/<name>.yaml. Returns {} for the bare-name case if the
    file is just a single key/value (PyYAML still returns a dict)."""
    path = plugins_dir / f"{name}.yaml"
    if not path.is_file():
        print(f"ERROR: plugin fragment not found: {path}", file=sys.stderr)
        sys.exit(2)
    with path.open() as f:
        data = yaml.safe_load(f) or {}
    if not isinstance(data, dict) or data.get("name") != name:
        print(
            f"ERROR: {path} must be a YAML mapping with `name: {name}`",
            file=sys.stderr,
        )
        sys.exit(2)
    return data


def build_entry(
    name: str,
    policy: str,
    fragment: dict[str, Any],
    overrides: dict[str, Any] | None,
    operator_config: dict[str, Any] | None,
) -> dict[str, Any]:
    """Build the final plugin entry.

    Config precedence (later wins on leaf conflicts):
        operator base config  <  fragment defaults  <  --config-file overrides

    The operator base is the config block the operator already rendered for
    this plugin in the ConfigMap we read from stdin. Preserving it is the
    whole point: several plugins (jwt-validation's issuer, token-exchange's
    token_url/identity/routes) are configured ONLY by the operator, and a
    prior version of this script replaced the plugin list wholesale — which
    dropped that config and made the sidecar reject the reload
    ("issuer is required", "token_url is required"). We now start from the
    operator's block and layer our fragment + overrides on top, matching how
    authbridge's own `abctl edit` splices rather than rebuilds.
    """
    entry: dict[str, Any] = {"name": name}
    config: dict[str, Any] = {}
    if isinstance(operator_config, dict) and operator_config:
        config = copy.deepcopy(operator_config)
    frag_cfg = fragment.get("config")
    if isinstance(frag_cfg, dict) and frag_cfg:
        deep_merge(config, copy.deepcopy(frag_cfg))
    if overrides:
        deep_merge(config, overrides)
    if config:
        entry["config"] = config
    # `enforce` is the framework default — omit on_error to keep diffs
    # minimal. observe/off are explicit.
    if policy != "enforce":
        entry["on_error"] = policy
    return entry


def index_operator_config(operator: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Map plugin name -> its `config` block as rendered by the operator in
    the ConfigMap read from stdin. Scans both chains; missing/blank config
    yields no entry."""
    by_name: dict[str, dict[str, Any]] = {}
    pipeline = operator.get("pipeline")
    if not isinstance(pipeline, dict):
        return by_name
    for chain in ("inbound", "outbound"):
        section = pipeline.get(chain)
        if not isinstance(section, dict):
            continue
        for entry in section.get("plugins", []) or []:
            if not isinstance(entry, dict):
                continue
            n = entry.get("name")
            cfg = entry.get("config")
            if isinstance(n, str) and isinstance(cfg, dict) and cfg:
                by_name[n] = cfg
    return by_name


def validate_mutex(resolved: dict[str, str]) -> None:
    """Reject mutually-exclusive plugin pairs both active (not off) in the
    same chain."""
    for a, b in MUTEX_PAIRS:
        pa = resolved.get(a, "off")
        pb = resolved.get(b, "off")
        if pa != "off" and pb != "off" and CHAIN_FOR[a] == CHAIN_FOR[b]:
            print(
                f"ERROR: '{a}' and '{b}' are mutually exclusive on the "
                f"{CHAIN_FOR[a]} chain (both claim the same context slot). "
                f"Disable one with --no-plugin {a} or --no-plugin {b}.",
                file=sys.stderr,
            )
            sys.exit(2)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plugins-dir", required=True, type=Path,
                    help="directory containing <plugin>.yaml fragments")
    ap.add_argument("--plugins", default="",
                    help="space-separated name[:policy] tokens")
    ap.add_argument("--config-file",
                    help="optional flat-map per-plugin config override file")
    ap.add_argument("--prompt-file",
                    help="optional ibac system_prompt source file")
    args = ap.parse_args()

    operator = yaml.safe_load(sys.stdin) or {}

    requested = parse_plugins(args.plugins)

    # Resolve every supported plugin: requested → its policy, otherwise off.
    resolved: dict[str, str] = {}
    for name in CHAIN_FOR:
        resolved[name] = requested.get(name, "off")

    validate_mutex(resolved)

    # Load --plugin-config-file overrides (flat map keyed by plugin name).
    overrides: dict[str, dict[str, Any]] = {}
    if args.config_file:
        with open(args.config_file) as f:
            raw = yaml.safe_load(f) or {}
        if not isinstance(raw, dict):
            print(
                f"ERROR: --config-file {args.config_file} must be a top-level mapping",
                file=sys.stderr,
            )
            return 2
        for name, val in raw.items():
            if name not in CHAIN_FOR:
                print(
                    f"WARN: --config-file: unknown plugin '{name}' — ignoring",
                    file=sys.stderr,
                )
                continue
            if not isinstance(val, dict):
                print(
                    f"ERROR: --config-file: '{name}' value must be a mapping",
                    file=sys.stderr,
                )
                return 2
            overrides[name] = val

    # Load the optional ibac system prompt.
    ibac_prompt: str | None = None
    if args.prompt_file:
        with open(args.prompt_file) as f:
            text = f.read()
        if text.strip():
            ibac_prompt = text

    # Index the config blocks the operator already rendered, so build_entry
    # can preserve them (issuer, token_url/identity, …) instead of dropping
    # them. Done before we overwrite the plugin lists below.
    operator_config = index_operator_config(operator)

    # Build inbound and outbound chains in canonical order. We're
    # authoritative for the chain composition (which plugins, in what order,
    # with what on_error) by design (see §4.3), but each plugin's config is
    # seeded from the operator's rendered block so operator-supplied settings
    # survive.
    inbound_entries: list[dict[str, Any]] = []
    for name in INBOUND_ORDER:
        fragment = load_fragment(args.plugins_dir, name)
        entry = build_entry(name, resolved[name], fragment,
                            overrides.get(name), operator_config.get(name))
        inbound_entries.append(entry)

    outbound_entries: list[dict[str, Any]] = []
    for name in OUTBOUND_ORDER:
        fragment = load_fragment(args.plugins_dir, name)
        entry = build_entry(name, resolved[name], fragment,
                            overrides.get(name), operator_config.get(name))
        if name == "ibac" and ibac_prompt is not None and resolved[name] != "off":
            cfg = entry.setdefault("config", {})
            cfg["system_prompt"] = ibac_prompt
        outbound_entries.append(entry)

    # Replace operator's plugin lists with our resolved ones (composition is
    # ours; per-plugin config was preserved via operator_config above).
    pipeline = operator.setdefault("pipeline", {})
    pipeline.setdefault("inbound", {})["plugins"] = inbound_entries
    pipeline.setdefault("outbound", {})["plugins"] = outbound_entries

    sys.stdout.write(
        yaml.safe_dump(operator, default_flow_style=False, sort_keys=False)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
