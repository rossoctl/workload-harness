# Specification: AuthBridge Pipeline Composition for `exgentic_a2a_runner` Deploy Scripts

## 1. Background and motivation

The current `exgentic_a2a_runner` deploy scripts treat AuthBridge as two opaque toggles:

- `--authbridge` / `--no-authbridge` — turn the sidecar on/off (operator-default pipeline).
- `--ibac` / `--no-ibac` — implies `--authbridge`, then runs `ibac/apply-ibac.sh` to overlay a hardcoded patch (`ibac/ibac-patch.yaml`) onto `authbridge-config-<agent>`. The overlay is a fixed shape:
  - `inbound:  [a2a-parser, jwt-validation]`
  - `outbound: [token-exchange, inference-parser, mcp-parser, ibac]`

This was correct when IBAC was the only knob workload-harness needed. AuthBridge has since moved to a **generic plugin pipeline** (`authbridge/docs/framework-architecture.md`, `plugin-reference.md`) where every component — `jwt-validation`, `token-exchange`, `token-broker`, `a2a-parser`, `mcp-parser`, `inference-parser`, `ibac` — is independently composable, configured under its own `config:` block, and gated by an `on_error` policy (`enforce` / `observe` / `off`). The current scripts can't express:

- IBAC without token-exchange, or token-exchange without IBAC parsers.
- Token-broker (newer plugin) instead of token-exchange.
- `on_error: observe` for canary rollout of a guardrail.
- Per-plugin tuning (e.g. IBAC's `judge_model`, token-exchange routes) without editing the patch YAML.

This proposal generalizes the deploy scripts so they drive the pipeline by **enabling/disabling/configuring named plugins**, matching the AuthBridge framework's mental model. **Back-compat for the existing flags is explicitly out of scope** — the old `--ibac` / `--authbridge` flags and `IBAC_ENABLED` / `AUTHBRIDGE_ENABLED` env vars are removed.

## 2. Goals / non-goals

**Goals:**
- One deploy invocation can produce any valid pipeline shape that AuthBridge supports today, by selecting plugins and per-plugin policy.
- Each plugin is independently toggleable.
- Configuration delivery still goes through the existing operator ConfigMap + merge-overlay pattern — additive overlay, hot-reloaded by AuthBridge, no operator changes required.
- `on_error` policy is settable per plugin so canary rollouts are scriptable, and so that **plugins enabled by default in the operator base config can be turned off via the overlay** by emitting `on_error: off`.

**Non-goals:**
- Backwards compatibility with the previous `--ibac` / `--authbridge` flags or their env-var aliases. They are removed.
- Building a full YAML editor in shell. Pipeline ordering rules and slot dependency validation stay in AuthBridge (`pipeline.New`).
- Exposing every plugin config field as a CLI flag. We ship sensible defaults; advanced users override via env vars or `--plugin-config-file`.
- Changing the operator. The base config still comes from `kagenti-operator`; we only overlay.

## 3. Proposed CLI surface

### 3.1. Selectors

```
--plugin <name>[:policy]      # enable plugin; policy ∈ {enforce, observe, off}
                              # (default: enforce). Repeatable.
--no-plugin <name>            # shorthand for --plugin <name>:off. Repeatable.
--plugin-preset <preset>      # named bundle; see §3.2. Mutually exclusive
                              # only with itself; --plugin selectors after a
                              # preset override the preset's policy for that
                              # plugin (last write wins).
--plugin-config-file <path>   # YAML overlay file merged AFTER selectors;
                              # last-write-wins on per-plugin config.
                              # See §4.5 for format.
```

Supported plugin names: `jwt-validation`, `token-exchange`, `token-broker`, `a2a-parser`, `mcp-parser`, `inference-parser`, `ibac`.

Unknown plugin names fail fast at the script level with a helpful error before any kubectl call.

### 3.2. Presets

| Preset      | Inbound                       | Outbound                                              |
|-------------|-------------------------------|-------------------------------------------------------|
| `auth-only` | `jwt-validation`              | `token-exchange`                                      |
| `ibac-only` | `a2a-parser`                  | `inference-parser, mcp-parser, ibac`                  |
| `full`      | `a2a-parser, jwt-validation`  | `token-exchange, inference-parser, mcp-parser, ibac`  |

Notes:
- `ibac-only` is the "guardrail without auth" shape — useful for environments where the upstream gateway already terminates auth, but you still want intent-based blocking on outbound calls.
- `auth-only` is the bare auth/exchange shape with no protocol parsers and no IBAC.
- `full` is the everything-on shape.

Any plugin in the operator's base config that is **not** named in the resolved selection is emitted into the overlay with `on_error: off` so the framework skips dispatch for it. This is required because the operator base enables plugins by default; without an explicit `off`, removing a plugin from our selector list wouldn't actually disable it. See §4.3 for the resolution algorithm.

### 3.3. Examples

```bash
# Auth + token exchange only.
./deploy-agent.sh --benchmark tau2 --agent tool_calling \
    --plugin-preset auth-only

# IBAC guardrails without inbound auth (e.g. fronting gateway handles auth).
./deploy-agent.sh --benchmark tau2 --agent tool_calling \
    --plugin-preset ibac-only

# Everything on.
./deploy-agent.sh --benchmark tau2 --agent tool_calling \
    --plugin-preset full

# Full pipeline, but canary IBAC: collect would-have-blocked telemetry without enforcement.
./deploy-agent.sh --benchmark tau2 --agent tool_calling \
    --plugin-preset full \
    --plugin ibac:observe

# Token-broker instead of token-exchange (full preset, swap the gate).
./deploy-agent.sh --benchmark tau2 --agent tool_calling \
    --plugin-preset full \
    --no-plugin token-exchange \
    --plugin token-broker

# Custom set without a preset.
./deploy-agent.sh --benchmark tau2 --agent tool_calling \
    --plugin jwt-validation --plugin token-exchange --plugin ibac

# No AuthBridge sidecar at all.
./deploy-agent.sh --benchmark tau2 --agent tool_calling
# (omit all plugin flags; sidecar is not injected — see §4.4.)
```

## 4. Implementation

### 4.1. Directory rename and layout

Rename `exgentic_a2a_runner/ibac/` → `exgentic_a2a_runner/authbridge/`. The directory now hosts overlay tooling for the whole pipeline, not just IBAC.

```
exgentic_a2a_runner/authbridge/
├── apply-pipeline.sh           # was apply-ibac.sh; generalized
├── pipeline-merge.py           # was ibac-merge.py; works on named plugins
├── plugins/                    # per-plugin config fragments
│   ├── ibac.yaml               # was ibac-patch.yaml's ibac entry
│   ├── jwt-validation.yaml
│   ├── token-exchange.yaml
│   ├── token-broker.yaml
│   ├── a2a-parser.yaml
│   ├── mcp-parser.yaml
│   └── inference-parser.yaml
├── presets/
│   ├── auth-only.yaml
│   ├── ibac-only.yaml
│   └── full.yaml
├── intent_prompt.txt           # unchanged; consumed only when ibac is in the active set
└── wait-for-reload.sh          # unchanged
```

Each `plugins/<name>.yaml` is a single plugin entry with default config (envsubst placeholders for tunables). Example `plugins/ibac.yaml`:

```yaml
name: ibac
config:
  judge_endpoint: "${IBAC_JUDGE_ENDPOINT}"
  judge_model: "${IBAC_JUDGE_MODEL}"
  timeout_ms: ${IBAC_TIMEOUT_MS}
  judge_inference: false
  agent_llm_host: "${IBAC_AGENT_LLM_HOST}"
```

Each `presets/<name>.yaml` lists which plugins go in which chain:

```yaml
# presets/full.yaml
inbound:  [a2a-parser, jwt-validation]
outbound: [token-exchange, inference-parser, mcp-parser, ibac]
```

```yaml
# presets/ibac-only.yaml
inbound:  [a2a-parser]
outbound: [inference-parser, mcp-parser, ibac]
```

```yaml
# presets/auth-only.yaml
inbound:  [jwt-validation]
outbound: [token-exchange]
```

### 4.2. Plugin metadata table (in `pipeline-merge.py`)

A small static table mirrors the data the framework uses. The script does not read it from AuthBridge; we maintain it here.

| Plugin             | Chain    | Canonical position | Notes                                              |
|--------------------|----------|--------------------|----------------------------------------------------|
| `a2a-parser`       | inbound  | before auth        | populates `pctx.Session.LastIntent()` for IBAC     |
| `jwt-validation`   | inbound  | after parsers      | gate; deny short-circuits chain                    |
| `token-exchange`   | outbound | first              | claims `ClaimAuthorizationHeader`                  |
| `token-broker`     | outbound | first              | claims `ClaimAuthorizationHeader`; mutex w/ above  |
| `inference-parser` | outbound | after token gate   | observe-only                                       |
| `mcp-parser`       | outbound | after token gate   | observe-only                                       |
| `ibac`             | outbound | last               | reads parsers' extension slots                     |

The script enforces ordering by sorting selected plugins per chain by their canonical position, then emitting them. Operators don't pick order; they pick membership. Conflicts (e.g. both `token-exchange` and `token-broker` enabled in the same chain) are rejected with a clear error before any kubectl call.

### 4.3. Plugin resolution algorithm

Given (preset?, list of `--plugin name[:policy]`, list of `--no-plugin name`):

1. **Seed** from preset → `{name: enforce}` for each named plugin in the preset's chains. If no preset, start empty.
2. **Apply selectors in order**: each `--plugin name[:policy]` sets `name → policy` (default `enforce`); each `--no-plugin name` sets `name → off`. Last write wins.
3. **Compute the effective overlay set** = every plugin name AuthBridge knows about (the seven listed in §3.1). For each:
   - If the resolved policy is `off` and the plugin isn't in the operator base, omit it (no need to emit a no-op).
   - Otherwise emit it with the resolved policy. Plugins resolved as `enforce` get no `on_error:` field (default); `observe` and `off` get explicit `on_error:` lines.
4. **Validate**: reject `token-exchange` + `token-broker` both enabled (`enforce` or `observe`) in the same chain.
5. **Order** within each chain per the canonical-position table in §4.2.

The "operator base" enumeration is currently the same set as our seven supported plugins, so step 3 simplifies to "always emit every supported plugin, with the resolved policy." If the operator's base ever ships a plugin we don't list here, the overlay leaves it untouched (we don't read it back).

### 4.4. `deploy-agent.sh` changes

- Remove flags: `--authbridge`, `--no-authbridge`, `--ibac`, `--no-ibac`.
- Remove env-var defaults: `IBAC_ENABLED`, `AUTHBRIDGE_ENABLED`.
- Add flags: `--plugin`, `--no-plugin`, `--plugin-preset`, `--plugin-config-file`.
- AuthBridge sidecar injection (`authBridgeEnabled: true` in the API call) now triggers when **any** plugin selector is supplied (preset, `--plugin`, `--no-plugin`, or `--plugin-config-file`). Omit all selectors → no sidecar (matches today's "no `--authbridge` and no `--ibac`" behavior).
- The block that today calls `ibac/apply-ibac.sh` is replaced with a block that:
  1. Resolves the final plugin set via the algorithm in §4.3.
  2. Validates conflicts (token-exchange / token-broker mutex, unknown plugin names, unknown policies, unknown preset names).
  3. Calls `authbridge/apply-pipeline.sh` with `PIPELINE_PLUGINS` set to the resolved list (e.g. `"a2a-parser jwt-validation token-exchange:off inference-parser mcp-parser ibac:observe"`).
- The trailing summary replaces the `AuthBridge: …` / `IBAC: …` lines with one line listing the active pipeline, e.g.:
  ```
  Plugins:
    inbound:  a2a-parser, jwt-validation
    outbound: token-exchange:off, inference-parser, mcp-parser, ibac:observe
  ```

`deploy-and-evaluate.sh` mirrors the same flag additions and forwards them to `deploy-agent.sh`. `--ibac` / `--authbridge` are removed from it as well.

### 4.5. `--plugin-config-file` format

Flat map keyed by plugin name. Top-level keys are plugin names; values are the per-plugin `config:` subtree as AuthBridge expects it. Merge precedence: rendered fragment defaults < `--plugin-config-file` overrides (deep-merge per plugin).

```yaml
# my-overrides.yaml
ibac:
  judge_model: "llama3.2:8b"
  timeout_ms: 30000
token-exchange:
  default_policy: exchange
jwt-validation:
  bypass_paths:
    - /healthz
    - /metrics
```

`pipeline-merge.py` deep-merges each top-level key into the corresponding plugin's `config:` block in the overlay before emitting the merged ConfigMap. Unknown plugin names in the file are ignored with a WARN line on stderr (so the file can carry config for plugins not in the current selection without erroring).

### 4.6. `pipeline-merge.py`

Generalizes `ibac-merge.py`:

- Reads operator's current `config.yaml` from stdin.
- Takes the resolved plugin list (`PIPELINE_PLUGINS` env var, space-separated `name[:policy]` tokens) and an optional `--config-file` path.
- For each plugin in the resolved list:
  - Loads `plugins/<name>.yaml` (envsubst already expanded by `apply-pipeline.sh`).
  - Deep-merges the corresponding section from `--config-file` if present.
  - Sets `on_error:` per the resolved policy (omit on `enforce`).
  - Inserts into the appropriate chain at the canonical position (§4.2).
- Idempotent: re-running with the same selection produces byte-identical YAML; `apply-pipeline.sh`'s no-op short-circuit (existing logic) still works.
- Conflict detection: rejects mutually-exclusive plugins (`token-exchange` + `token-broker` in the same chain when neither is `off`).
- The `--prompt-file` injection for `ibac.system_prompt` stays, but only fires when `ibac` is in the resolved set with policy `enforce` or `observe`.

### 4.7. `apply-pipeline.sh`

Replaces `apply-ibac.sh`. Same overall flow:

1. Pre-flight (PyYAML, envsubst, ConfigMap exists, all plugin names in `PIPELINE_PLUGINS` are known).
2. Render each selected plugin fragment via `envsubst`.
3. Pipe operator config through `pipeline-merge.py` with the resolved set.
4. Compare hashes; short-circuit if no change.
5. `kubectl apply` the merged ConfigMap.
6. Wait for reload via `wait-for-reload.sh` (unchanged).

Inputs (env, all required unless noted):

| Env / arg                      | Meaning                                                  |
|--------------------------------|----------------------------------------------------------|
| `AGENT_NAME`, `NAMESPACE`      | Required, as today.                                      |
| `PIPELINE_PLUGINS`             | Required. Space-separated `name[:policy]` list.          |
| `PIPELINE_OVERLAY_FILE`        | Optional; path passed via `--plugin-config-file`.        |
| `IBAC_*`                       | Unchanged; consumed by `plugins/ibac.yaml` via envsubst. |
| `TOKEN_EXCHANGE_*` (new)       | Optional; consumed by `plugins/token-exchange.yaml`.     |
| `TOKEN_BROKER_*` (new)         | Optional; consumed by `plugins/token-broker.yaml`.       |
| `JWT_VALIDATION_*` (new)       | Optional; consumed by `plugins/jwt-validation.yaml`.     |

### 4.8. `example.env` changes

- Replace the IBAC-only block with a "Pipeline composition" section.
- Document `IBAC_*`, `TOKEN_EXCHANGE_*`, `TOKEN_BROKER_*`, `JWT_VALIDATION_*` env vars; mark each as "consumed when `<plugin>` is in the active plugin set."
- Remove `IBAC_ENABLED` and `AUTHBRIDGE_ENABLED` (no longer read by any script).
- Add a comment pointing to `--plugin-preset full` as the default starting point for users who used to run `--ibac`.

### 4.9. README changes

- Replace the "IBAC requires authbridge-envoy ≥ v0.6.0-alpha.4" subsection with a "Pipeline composition" subsection covering presets, individual selectors, the `on_error` policy (canary), and the `--plugin-config-file` format.
- Generalize the version-pin warning: "every plugin you select must be compiled into the running sidecar binary; the merge will validate but Configure will fail with `unknown plugin "<name>"` after reload if it isn't."
- Add a small troubleshooting subsection for:
  - `Claim` conflicts (`token-exchange` + `token-broker`).
  - `Reads ... no earlier plugin writes it` (parser ordering — should never happen given the script-side canonical ordering, but possible if a user supplies a malformed `--plugin-config-file` that adds an unknown plugin).
  - Unknown plugin / preset names (script-side error path).
  - Pointer to `framework-architecture.md` §6 for the underlying rules.

## 5. Migration

Single PR. No alias shim, no deprecation window:

1. Rename `ibac/` → `authbridge/`, split the patch into per-plugin fragments and presets, generalize `pipeline-merge.py`.
2. Replace `apply-ibac.sh` with `apply-pipeline.sh`.
3. Rewrite the plugin-related flag block in `deploy-agent.sh` and `deploy-and-evaluate.sh`.
4. Update `example.env` and README in the same PR.
5. Update any internal CI / docs that called `--ibac` or `--authbridge` to use the new flags. Anything that doesn't get updated will fail loudly with "unknown option," which is the behaviour we want — a silent default would mask a misconfiguration.

## 6. Decisions captured (was: open questions)

- **`on_error: off` is the disable mechanism.** Because the operator base enables plugins by default, omitting a plugin from our selector list would not actually disable it. Every plugin we don't want active is explicitly emitted with `on_error: off`. The active config is therefore self-documenting and lets an operator flip a plugin to `enforce` via `kubectl edit configmap` without re-running the deploy script.
- **`--plugin-config-file` is a flat map keyed by plugin name.** Simpler and more diffable than mirroring AuthBridge's full YAML list-of-entries shape; the script already knows the chain and order for each plugin.
- **`token-broker` is exposed in this PR.** Mutual exclusion with `token-exchange` is detected at script-time; the cost is a few lines in `pipeline-merge.py`.
