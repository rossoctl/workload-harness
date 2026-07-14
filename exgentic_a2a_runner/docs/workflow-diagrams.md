# Exgentic A2A Runner — Workflow Diagrams

This document describes the evaluation flow across the three orchestration
scripts and the Python harness they ultimately launch:

| Script | Role |
|---|---|
| `deploy-and-evaluate.sh` | Top-level orchestrator — runs the three steps below in sequence |
| `deploy-benchmark.sh` | Deploys the benchmark as an **MCP tool** (the session/eval backend) via the Kagenti API |
| `deploy-agent.sh` | Deploys the **A2A agent**  via the Kagenti API, optionally with an AuthBridge sidecar  |
| `evaluate-benchmark.sh` | Wires up endpoints + telemetry, then runs the Python harness `exgentic-a2a-runner` |
| `exgentic_a2a_runner/*.py` | The harness itself — drives MCP sessions + A2A calls per task, emits OTEL traces |

Every script shares `libsh/urls.sh`, which resolves service URLs from
`CLUSTER_MODE` (`--kind` / `--openshift DOMAIN` / `--in-cluster`).

Diagrams are in [Mermaid](https://mermaid.js.org/) and render on GitHub, VS Code,
and most Markdown viewers. Each of the four flows below has **(1)** a UML-style
sequence (interaction) diagram and the section ends with **(2)** an overall
architecture diagram.

---

## 1. `deploy-and-evaluate.sh` — end-to-end orchestration

The orchestrator parses flags then calls the three
sub-scripts in order. Any non-zero exit aborts via `fail`. `--dry` prints the
commands instead of running them.

### 1.1 Interaction diagram

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Orchestrator as deploy-and-evaluate.sh
    participant Bench as deploy-benchmark.sh
    participant Agent as deploy-agent.sh
    participant Eval as evaluate-benchmark.sh

    User->>Orchestrator: --benchmark --agent [--model --experiment<br/>--kind/--openshift/--in-cluster<br/>--use-mcp-gateway --plugin* --dry ...]
    Orchestrator->>Orchestrator: load .env (shell wins), parse args, validate<br/>build CLUSTER_FLAG / MCP_GATEWAY_FLAG /<br/>LOCAL_IMAGE_FLAG / PLUGIN_FLAGS

    alt DRY_RUN=true
        Orchestrator-->>User: print the 3 commands, exit 0
    else normal run
        rect rgb(235,245,255)
            note over Orchestrator,Bench: Step 1/3 — Deploy benchmark (MCP tool)
            Orchestrator->>Bench: deploy-benchmark.sh --benchmark --model<br/>--keycloak-* CLUSTER_FLAG [gateway] [local-image]
            Bench-->>Orchestrator: exit 0 (or fail "deploy benchmark failed")
        end
        rect rgb(235,255,235)
            note over Orchestrator,Agent: Step 2/3 — Deploy A2A agent
            Orchestrator->>Agent: deploy-agent.sh --benchmark --agent --model<br/>--keycloak-* CLUSTER_FLAG [gateway] [local-image] [PLUGIN_FLAGS]
            Agent-->>Orchestrator: exit 0 (or fail "deploy agent failed")
        end
        rect rgb(255,245,235)
            note over Orchestrator,Eval: Step 3/3 — Run evaluation
            Orchestrator->>Eval: evaluate-benchmark.sh --benchmark --agent --experiment<br/>--max-tasks --max-parallel-sessions CLUSTER_FLAG<br/>[--disable-mlflow] [--use-mcp-gateway]
            Eval-->>Orchestrator: exit 0 (or fail "evaluate failed")
        end
        Orchestrator-->>User: ✓ All steps completed
    end
```

### 1.2 Component view

```mermaid
flowchart TD
    User([User / CI]) -->|flags + .env| ORCH[deploy-and-evaluate.sh]

    subgraph flags[Normalized passthrough]
        CF[CLUSTER_FLAG<br/>kind / openshift DOMAIN / in-cluster]
        GW[MCP_GATEWAY_FLAG]
        LI[LOCAL_IMAGE_FLAG]
        PF[PLUGIN_FLAGS<br/>preset / selectors / overlay]
    end

    ORCH --> flags
    ORCH -->|Step 1| B[deploy-benchmark.sh]
    ORCH -->|Step 2| A[deploy-agent.sh]
    ORCH -->|Step 3| E[evaluate-benchmark.sh]

    B -.->|MCP tool live| K[(Kagenti cluster)]
    A -.->|A2A agent live| K
    E -->|runs harness| H[exgentic-a2a-runner]
    H -.->|MCP + A2A traffic| K
```

---

## 2. `deploy-benchmark.sh` — deploy the benchmark MCP tool

Authenticates to Keycloak (auto-fetching / enabling Direct Access Grants),
deletes any existing tool (waiting for async cleanup), fetches + parses the
benchmark `.env` through the Kagenti `parse-env` API, augments it with runtime
vars, then `POST`s a tool spec to the Kagenti API. Polls the MCP `initialize`
endpoint until ready. Optionally registers the tool with the MCP Gateway.

### 2.1 Interaction diagram

```mermaid
sequenceDiagram
    autonumber
    participant Bench as deploy-benchmark.sh
    participant KC as Keycloak
    participant KAG as Kagenti API
    participant GH as GitHub (raw .env)
    participant K8s as kubectl / cluster
    participant MCP as MCP tool pod

    note over Bench: source libsh/urls.sh → resolve URLs from CLUSTER_MODE
    Bench->>KC: GET /health (retry ≤10s)
    opt password == "unknown" (kind)
        Bench->>K8s: get secret kagenti-test-user
        K8s-->>Bench: benchmark password
    end
    Bench->>KC: POST realms/master token (admin-cli)
    KC-->>Bench: admin token
    Bench->>KC: PUT clients/kagenti {directAccessGrantsEnabled:true}
    Bench->>KC: POST realms/kagenti token (password grant)
    KC-->>Bench: ACCESS_TOKEN
    Bench->>KAG: GET /api/v1/namespaces (reachability, retry ≤10s)

    Bench->>KAG: DELETE /api/v1/tools/team1/{tool}
    alt was 200 (existed)
        loop until 404 (≤30s)
            Bench->>KAG: GET tool → poll gone
        end
    end

    Bench->>GH: GET .env.<benchmark>
    GH-->>Bench: env content (abort if 404)
    Bench->>KAG: POST /api/v1/agents/parse-env {content}
    KAG-->>Bench: envVars JSON
    Bench->>Bench: jq-append OPENAI_API_BASE, tau user-sim model,<br/>gsm8k runner=direct

    Bench->>KAG: POST /api/v1/tools {image, ports, envVars,<br/>createHttpRoute, authBridgeEnabled:false}
    KAG-->>Bench: HTTP 2xx (409 = abort)
    opt --local-image
        Bench->>K8s: patch imagePullPolicy=IfNotPresent
    end

    loop until HTTP 200 (≤180s)
        Bench->>MCP: POST /mcp initialize (JSON-RPC)
    end
    opt not in-cluster
        Bench->>K8s: set resources + rollout status
    end
    opt --use-mcp-gateway
        Bench->>K8s: apply HTTPRoute + MCPServerRegistration
        loop until Ready (≤120s)
            Bench->>K8s: get mcpserverregistration status
        end
    end
    Bench-->>Bench: ✓ benchmark deployed
```

### 2.2 Component view

```mermaid
flowchart LR
    B[deploy-benchmark.sh] -->|auth| KC[(Keycloak)]
    B -->|deploy/delete tool<br/>parse-env| KAG[(Kagenti API)]
    B -->|fetch .env.benchmark| GH[(GitHub raw)]
    B -->|patch / resources / gateway CRs| KUBE[(kubectl → cluster)]
    KAG -->|creates Deployment + Service + HTTPRoute| MCP["exgentic-mcp-&lt;bench&gt; pod<br/>team1 ns"]
    B -->|health: POST /mcp initialize| MCP
    B -.->|optional: register| GWY[MCP Gateway<br/>HTTPRoute + MCPServerRegistration]
    GWY --> MCP
```

---

## 3. `deploy-agent.sh` — deploy the A2A agent

Same auth pattern as the benchmark. Pulls a prebuilt image for the named
agent. Injects MCP URL (direct or gateway), LLM config, OTEL, and runner env;
resolves the AuthBridge plugin pipeline (Python helper) and, if any selector
was supplied, injects the sidecar + applies the pipeline overlay. Waits on
the agent-card endpoint for readiness.

### 3.1 Interaction diagram

```mermaid
sequenceDiagram
    autonumber
    participant Agent as deploy-agent.sh
    participant KC as Keycloak
    participant KAG as Kagenti API
    participant GH as GitHub (raw .env)
    participant PY as authbridge resolver (python3)
    participant K8s as kubectl / cluster
    participant AG as Agent pod
    participant AP as apply-pipeline.sh

    note over Agent: image (exgentic-a2a-{agent}-{bench})
    opt --local-image
        Agent->>K8s: sync-image-to-cluster.sh
    end
    Agent->>KC: health + admin token + enable DAG + password grant
    KC-->>Agent: ACCESS_TOKEN
    Agent->>KAG: GET /api/v1/namespaces (reachability)
    Agent->>KAG: DELETE /api/v1/agents/team1/{agent}
    opt was 200
        loop until 404 (≤30s)
            Agent->>KAG: GET agent → poll gone
        end
    end

    Agent->>GH: GET .env (generic vs exgentic URL)
    GH-->>Agent: env content
    Agent->>KAG: POST /api/v1/agents/parse-env
    KAG-->>Agent: envVars JSON
    Agent->>Agent: jq-append MCP_URL(S), LLM_API_BASE/MODEL,<br/>EXGENTIC_OTEL_*, DEFAULT_RUNNER=thread,<br/>tool-shortlisting (tool_calling), LITELLM_LOCAL...

    opt any --plugin* selector
        Agent->>PY: resolve preset+selectors → PIPELINE_PLUGINS<br/>(validate, mutex check, last-write-wins)
        PY-->>Agent: resolved plugin list (AUTHBRIDGE_ENABLED=true)
    end

    Agent->>KAG: POST /api/v1/agents {source|image spec,<br/>envVars, createHttpRoute, authBridgeEnabled}
    KAG-->>Agent: HTTP 2xx (409 = abort)

    opt --local-image
        Agent->>K8s: patch imagePullPolicy=IfNotPresent
    end
    opt openshift
        Agent->>K8s: patch route targetPort → "http"
    end

    loop until HTTP 200 + valid JSON (≤180s)
        Agent->>AG: GET /.well-known/agent-card.json
    end
    opt kind
        Agent->>K8s: update-secrets.sh
    end
    opt not in-cluster
        Agent->>K8s: set resources + rollout status
    end
    opt AUTHBRIDGE_ENABLED
        Agent->>AP: apply-pipeline.sh (PIPELINE_PLUGINS, IBAC_*, broker vars)
        AP->>K8s: patch AuthBridge sidecar config
    end
    Agent-->>Agent: ✓ agent ready (re-fetch card)
```

### 3.2 Component view

```mermaid
flowchart LR
    A[deploy-agent.sh] -->|auth| KC[(Keycloak)]
    A -->|deploy/delete agent<br/>parse-env| KAG[(Kagenti API)]
    A -->|fetch .env| GH[(GitHub raw)]
    A -->|resolve pipeline| PY[authbridge resolver.py]
    A -->|build/patch/secrets/resources| KUBE[(kubectl → cluster)]
    A -->|overlay| AP[authbridge/apply-pipeline.sh]

    KAG -->|image: Deployment| AG[exgentic-a2a-agent-bench pod]
    AP -.->|configures| SC[AuthBridge sidecar]
    SC --- AG
    A -->|health: /.well-known/agent-card.json| AG
    AG -->|MCP_URL / MCP_URLS| MCP[MCP tool or Gateway]
```

---

## 4. `evaluate-benchmark.sh` + Python harness — run the evaluation

The shell script resolves MCP + A2A URLs, waits for both to be ready, sets up
telemetry (port-forwards for OTEL/Prometheus on a laptop; cluster DNS
in-cluster), exports config as env vars, and launches `uv run
exgentic-a2a-runner`. The Python harness then processes tasks concurrently.

### 4.1 Interaction diagram — shell setup

```mermaid
sequenceDiagram
    autonumber
    participant Eval as evaluate-benchmark.sh
    participant K8s as kubectl (port-forward)
    participant MCP as MCP server / Gateway
    participant AG as A2A agent
    participant OTEL as OTEL collector
    participant Runner as uv run exgentic-a2a-runner

    Eval->>Eval: source urls.sh → resolve MCP_BASE_URL,<br/>AGENT_BASE_URL from CLUSTER_MODE
    Eval->>MCP: wait_for_url /health (≤60s, 2xx/404)
    Eval->>AG: wait_for_url_strict /.well-known/agent-card.json (≤60s, 2xx)
    alt not in-cluster
        Eval->>K8s: port-forward OTEL (4327→4317) + Prometheus (9191→9090)
    else in-cluster
        note over Eval: use cluster DNS directly
    end
    opt MLflow enabled
        Eval->>OTEL: connectivity check
    end
    Eval->>Eval: export EXGENTIC_MCP_SERVER_URL, A2A_BASE_URL,<br/>BENCHMARK/AGENT/EXPERIMENT_NAME, MAX_TASKS,<br/>MAX_PARALLEL_SESSIONS, PROMETHEUS_URL,<br/>INFRA_*, OTEL_EXPORTER_* (grpc laptop / http-protobuf in-cluster)
    Eval->>Runner: uv run exgentic-a2a-runner [--log-level]
    Runner-->>Eval: exit code (0 if ≥1 session succeeded)
    Eval->>K8s: trap cleanup — kill port-forwards
```

### 4.2 Interaction diagram — Python harness (per run)

`Runner.run()` fetches all task IDs (`list_tasks` MCP tool), truncates to
`MAX_TASKS`, and dispatches them across a `ThreadPoolExecutor` of
`MAX_PARALLEL_SESSIONS` workers. Each worker runs `process_task`, wrapped in a
root OTEL span with child spans per stage.

```mermaid
sequenceDiagram
    autonumber
    participant Runner
    participant Pool as ThreadPoolExecutor<br/>(MAX_PARALLEL_SESSIONS)
    participant Adapter as ExgenticAdapter
    participant MCP as MCP server (tools)
    participant A2A as A2AProxyClient (a2a-sdk)
    participant AG as A2A agent
    participant Prom as Prometheus
    participant OTEL as OTEL collector → MLflow

    Runner->>Adapter: initialize() (MCP connect) + OTEL init
    Runner->>MCP: list_tasks → task_ids
    Runner->>Runner: task_ids = task_ids[:MAX_TASKS]
    Runner->>Pool: submit process_task(task_id) for each

    par per worker (concurrent)
        Pool->>Runner: process_task(task_id)  [root span: session]
        Runner->>MCP: create_session(task_id)  [span MCP.CreateSession]
        MCP-->>Runner: session_id, task, context
        Runner->>Runner: build_prompt()  [span Prompt.Build]
        Runner->>A2A: send_prompt(prompt, session_id)  [span Agent.Call]
        A2A->>AG: GET agent-card → send_message (streaming)
        AG-->>A2A: streamed artifact text
        A2A-->>Runner: response text
        Runner->>MCP: evaluate_session(session_id)  [span Evaluator.Evaluate]
        MCP-->>Runner: {success: bool}
        opt Prometheus enabled
            Runner->>Prom: collect_session_metrics(window)  [span Infra.Metrics]
            Prom-->>Runner: CPU / mem / net per pod
        end
        Runner->>MCP: delete_session(session_id)  [span MCP.DeleteSession]
        Runner-->>Pool: SessionResult
    end

    Runner->>Runner: as_completed → aggregate,<br/>abort_on_failure cancels remaining
    Runner->>OTEL: export spans (batched)
    Runner->>Runner: print RunSummary (rates, latency p50/p95, timings)
    note over Runner: exit 0 if ≥1 session succeeded, else 1
```

> **Note on session creation:** despite the fetch-all-task-ids step, sessions
> are **created on-demand inside each worker** (`process_task` calls
> `create_session`), not pre-created. `list_tasks` only supplies the work list.

### 4.3 Architecture / component view

```mermaid
flowchart TB
    subgraph host[Runner host — laptop or in-cluster Job]
        Eval[evaluate-benchmark.sh]
        subgraph py[exgentic-a2a-runner Python harness]
            R[Runner<br/>ThreadPoolExecutor]
            AD[ExgenticAdapter → MCPClient]
            AC[A2AProxyClient<br/>a2a-sdk]
            OT[OTELInstrumentation]
            PC[PrometheusMetricsCollector]
        end
        Eval -->|env vars + uv run| R
        R --> AD
        R --> AC
        R --> OT
        R --> PC
    end

    subgraph cluster[Kagenti cluster · namespace team1]
        MCP["MCP tool<br/>exgentic-mcp-BENCH"]
        AG["A2A agent<br/>exgentic-a2a-AGENT-BENCH"]
        GWY[MCP Gateway<br/>optional]
        COL[OTEL collector<br/>kagenti-system]
        PROM[Prometheus<br/>istio-system]
        MLF[(MLflow)]
        LLM[[LLM endpoint<br/>OPENAI_API_BASE]]
    end

    AD -->|create/evaluate/delete_session,<br/>list_tasks JSON-RPC| MCP
    AD -. --use-mcp-gateway .-> GWY --> MCP
    AC -->|send_message streaming| AG
    AG -->|tool calls| MCP
    AG -->|inference| LLM
    OT -->|OTLP spans| COL --> MLF
    PC -->|PromQL infra metrics| PROM

    %% port-forward vs cluster-DNS is chosen by CLUSTER_MODE in urls.sh
```

---

## Appendix — how `CLUSTER_MODE` reshapes URLs (`libsh/urls.sh`)

| Helper | `kind` | `openshift` (needs `INGRESS_DOMAIN`) | `in-cluster` |
|---|---|---|---|
| `kagenti_api_url` | `kagenti-api.localtest.me:8080` | `kagenti-api-kagenti-system.<domain>` | `kagenti-backend.kagenti-system.svc:8000` |
| `keycloak_api_url` | `keycloak.localtest.me:8080` | `keycloak-keycloak.<domain>` | `keycloak-service.keycloak.svc:8080` |
| `tool_http_url` | `<tool>.<ns>.localtest.me:8080` | `<tool>-<ns>.<domain>` | `<tool>-mcp.<ns>.svc:8000` |
| `agent_http_url` | `<agent>.<ns>.localtest.me:8080` | `<agent>-<ns>.<domain>` | `<agent>.<ns>.svc:8080` |
| `otel_collector_url` | `localhost:4327` (port-fwd) | `localhost:4327` (port-fwd) | `otel-collector.kagenti-system.svc:8335` |
| `prometheus_url` | `localhost:9191` (port-fwd) | `localhost:9191` (port-fwd) | `prometheus.istio-system.svc:9090` |

If `CLUSTER_MODE` is unset, `urls.sh` infers it: `KUBERNETES_SERVICE_HOST` ⇒
`in-cluster`, else `INGRESS_DOMAIN` ⇒ `openshift`, else `kind`.
