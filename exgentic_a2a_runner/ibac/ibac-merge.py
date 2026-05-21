#!/usr/bin/env python3
"""Merge IBAC pipeline additions into the operator-rendered authbridge
config.yaml.

Reads:
  - argv[1]:        path to ibac-patch.yaml (the additions doc)
  - --prompt-file:  optional path to intent_prompt.txt; if present and
                    non-empty, its contents are injected as the ibac
                    plugin's system_prompt field
  - stdin:          the operator's current config.yaml content

Writes the merged YAML to stdout.

Idempotent: re-running with already-merged input is a no-op for plugin
list membership (entries matched by `name` aren't duplicated). The
system_prompt is always overwritten with the prompt-file contents on
re-run, so editing intent_prompt.txt and re-merging picks up the new
prompt.
"""

import argparse
import sys
import yaml


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("patch", help="path to ibac-patch.yaml")
    ap.add_argument(
        "--prompt-file",
        help="optional path to a system-prompt file; injected as the ibac plugin's system_prompt",
    )
    args = ap.parse_args()

    operator = yaml.safe_load(sys.stdin) or {}
    with open(args.patch) as f:
        patch = yaml.safe_load(f) or {}

    pipeline = operator.setdefault("pipeline", {})
    inbound = pipeline.setdefault("inbound", {})
    outbound = pipeline.setdefault("outbound", {})
    in_plugins = inbound.setdefault("plugins", [])
    out_plugins = outbound.setdefault("plugins", [])

    in_names = {p.get("name") for p in in_plugins}
    out_names = {p.get("name") for p in out_plugins}

    # Reverse-then-prepend preserves the patch's natural order at the
    # front of the chain.
    for entry in reversed(patch.get("inbound_prepend", []) or []):
        if entry.get("name") not in in_names:
            in_plugins.insert(0, entry)
            in_names.add(entry["name"])

    for entry in patch.get("outbound_append", []) or []:
        if entry.get("name") not in out_names:
            out_plugins.append(entry)
            out_names.add(entry["name"])

    # Inject system_prompt from intent_prompt.txt onto the ibac plugin
    # entry if provided. Done after the merge so it works whether the
    # plugin entry was just appended or already present from a prior run.
    if args.prompt_file:
        with open(args.prompt_file) as f:
            prompt = f.read()
        if prompt.strip():
            for entry in out_plugins:
                if entry.get("name") == "ibac":
                    cfg = entry.setdefault("config", {})
                    cfg["system_prompt"] = prompt
                    break

    sys.stdout.write(yaml.safe_dump(operator, default_flow_style=False, sort_keys=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
