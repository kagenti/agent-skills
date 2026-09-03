---
name: byo-rossoctl-cortex
description: >
  Bring up a local "rossoctl cortex" — an AuthBridge plugin pipeline that hosts a
  command (e.g. Claude Code) via `rossoctl authbridge exec`. Guides the user
  through choosing plugins, generates the authbridge YAML config, and runs the
  agent behind it. Specializes in per-agent LiteLLM usage/budget tracking where
  each agent's spend is isolated by an environment variable. Use /byo-rossoctl-cortex.
license: Complete terms in the repository-root LICENSE (../../LICENSE)
user-invokable: true
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - AskUserQuestion
---

# BYO rossoctl cortex (local AuthBridge pipeline with plugins)

Stand up a **local rossoctl cortex** and run a command (typically `claude`) behind
an AuthBridge plugin pipeline, so every LLM/tool/agent request the command makes
flows through plugins you choose — for cost tracking, budget enforcement, policy,
token exchange, context compaction, and more.

## What "rossoctl cortex" is

A *cortex* is a local rossoctl backend. Two entry points matter:

- **`rossoctl authbridge exec --config CONFIG -- COMMAND [ARGS...]`** — the one this
  skill drives. It hosts `COMMAND` behind the config's plugin pipelines. It starts:
  - a **forward proxy** (egress): the command's own outbound HTTP(S) runs the
    **outbound** pipeline. This is where LLM traffic to a LiteLLM/Anthropic/OpenAI
    endpoint is intercepted.
  - a **reverse proxy** (ingress): callers reach the command through it, running the
    **inbound** pipeline. Only started when `listener.roles` includes `reverse`.
  - a **TLS bridge**: terminates the command's outbound HTTPS so plugins see
    decrypted requests/responses instead of an opaque CONNECT tunnel. Required for
    any plugin that must read HTTPS request/response bodies or headers.
  - a **session API** (`:9094` by default) exposing recorded traffic for debugging.
  - It injects `HTTP_PROXY`/`HTTPS_PROXY` (and CA-trust vars `NODE_EXTRA_CA_CERTS`,
    `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE` when the TLS bridge runs) into the command's
    environment automatically. Claude Code (Node) honors `HTTPS_PROXY` +
    `NODE_EXTRA_CA_CERTS`, so no app changes are needed.

- **`rossoctl cortex serve`** — serves the rossoctl backend *API* on a local port for
  a web UI. It does **not** run a plugin pipeline; it is unrelated to hosting an
  agent behind plugins. Use `authbridge exec` for the plugin pipeline.

Config is YAML with `${ENV_VAR}` expansion (undefined `${VARS}` are left literal).
See `templates/litellm-budget-track.yaml` for the canonical shape.

## Available plugins

Full details, per-plugin config fields, and direction are in
[`reference/plugins.md`](reference/plugins.md). Summary:

| Plugin | Direction | What it does |
|---|---|---|
| `litellm-budget-track` | response-reading | Reads the `x-litellm-response-cost` response header, accumulates daily spend in a JSON ledger file, and returns **429** once a daily budget is exceeded. |
| `jwt-validation` | inbound | Validate inbound JWT signature / issuer / audience against JWKS. |
| `token-exchange` | outbound | RFC 8693 token exchange per host route (Keycloak/Entra/Okta). |
| `static-inject` | outbound | Swap a placeholder credential for a real static secret on egress. |
| `ibac` | outbound | LLM-judge intent-based access control on outbound tool calls. |
| `opa` | both | OPA policy bundles on inbound + outbound requests. |
| `sparc` | outbound | Pre-tool reflection; blocks ungrounded/hallucinated tool calls. |
| `session-budget` | outbound | Per-session token/call/duration budgets via Redis. |
| `token-broker` | outbound | Exchange tokens via an external broker per route. |
| `a2a-parser` / `mcp-parser` / `inference-parser` | parsers | Parse A2A / MCP / OpenAI-inference traffic into `pctx.Extensions.*` for downstream guardrails. |
| `context-guru` | outbound | Compact the outbound LLM request context (opt-in build tag). |
| `cpex` | outbound | APL DSL + named CPEX policy plugins (separate `authbridge-cpex` binary). |

To place a plugin in the pipeline, add it under `pipeline.outbound.plugins` (for
egress) or `pipeline.inbound.plugins` (for ingress), each with an optional
`config:` block. In `authbridge exec` the **forward proxy runs the outbound
pipeline**, so plugins acting on the command's own LLM/tool egress — including
`litellm-budget-track` — go under `pipeline.outbound`.

## Procedure

### Step 1 — Get the `rossoctl` binary

This skill does **not** assume any repo is already checked out. If `rossoctl` is not
already on `PATH`, clone and build it. It is pure Go (build with `CGO_ENABLED=0`).

```sh
# Already installed? Use it.
command -v rossoctl && rossoctl version
```

For working `litellm-budget-track` cost tracking you need the **fixed `cortex`
branch** (not yet in a tagged authlib), so clone `rossoctl-cli` and `cortex` **as
siblings** in one scratch dir and build `rossoctl` against the local `cortex` with a
replace directive — no manual patching. The `fix_streaming_litellm_plugin` branch is
stacked on `fix_litellm_plugin`, so it has the response-header fix (+ `-original`
fallback) **and** streaming (SSE) cost tracking for Claude Code's `/v1/messages`:

```sh
mkdir -p "$HOME/rossoctl-src"
cd "$HOME/rossoctl-src"   # scratch dir; anywhere writable
git clone https://github.com/rossoctl/rossoctl-cli.git
git clone -b fix_streaming_litellm_plugin https://github.com/aslom/cortex.git
#   branch: https://github.com/aslom/cortex/tree/fix_streaming_litellm_plugin
#   (header fix + -original fallback + streaming usage pricing).
#   For the header fix only (no streaming) use -b fix_litellm_plugin.

cd rossoctl-cli
# replace path is relative to rossoctl-cli's go.mod, i.e. the sibling cortex clone:
go mod edit -replace github.com/rossoctl/cortex/authbridge/authlib=../cortex/authbridge/authlib
GOFLAGS=-mod=mod go mod tidy
CGO_ENABLED=0 go build -o bin/rossoctl .
export PATH="$PWD/bin:$PATH"       # or: sudo mv bin/rossoctl /usr/local/bin/
rossoctl version
```

If you don't need cost tracking (or once the fix lands in an upstream
`rossoctl/cortex` release), a plain build pulls the authlib automatically — no cortex
clone or replace needed:

```sh
git clone https://github.com/rossoctl/rossoctl-cli.git && cd rossoctl-cli
CGO_ENABLED=0 go build -o bin/rossoctl . && export PATH="$PWD/bin:$PATH"
```

Or install a prebuilt release: `curl -fsSL
https://raw.githubusercontent.com/rossoctl/rossoctl-cli/main/downloadRossoctl | sh`
then `export PATH="$PATH:$HOME/.config/rossoctl"`.

### Step 2 — Ask the user what they want

Use `AskUserQuestion` to choose:
1. **Which plugins** to enable (multi-select from the table above; default
   `litellm-budget-track`).
2. **The command** to host (default `claude`).
3. For `litellm-budget-track`: the **daily budget** (USD) and whether they want
   **per-agent isolation** (separate ledger per agent via an env var — recommended).

Skip questions whose answers are already obvious from the request.

### Step 3 — Generate the config

Copy `templates/litellm-budget-track.yaml` into a working dir (e.g.
`./.cortex/CONFIG.yaml`) and adjust:
- `listener.roles`: `[forward]` for egress-only (LLM cost tracking); add `reverse`
  only if you are fronting an inbound service.
- `tls_bridge`: keep `mode: enabled`, `generate_ca: true`. `ca_dir` is `${CORTEX_CA_DIR}`
  in the template — export it to an **absolute, persistent, sandbox-writable** path
  (e.g. `CORTEX_CA_DIR="$PWD/.cortex/tls-bridge-ca"`); it must survive restarts, else
  clients re-trust a new CA each run, and `/tmp` may be blocked. Default
  `ports: [443, 8443]` cover HTTPS LLM endpoints.
- `pipeline.outbound.plugins`: the chosen plugins. For `litellm-budget-track`:
  ```yaml
  - name: litellm-budget-track
    config:
      spend_file: "${CORTEX_SPEND_FILE}"     # per-agent ledger, from env
      max_budget: ${CORTEX_MAX_BUDGET}        # daily budget in USD
      # REQUIRED for Claude Code and any stream:true client: streamed
      # /v1/messages responses report cost 0 in the header, so without these
      # per-token rates a streamed call records $0. Omit only for non-streaming
      # (curl / OpenAI /v1/chat/completions), which is priced from the header.
      input_cost_per_token: 0.000003          # example: $3 / 1M UNCACHED input tokens
      output_cost_per_token: 0.000015         # example: $15 / 1M output tokens
      # Prompt-cache tiers — set to your provider's real prices (see caveat 6);
      # if omitted they default to input_cost_per_token (flat), overstating
      # cache-heavy Claude Code traffic up to ~10× and tripping the 429 early.
      cache_write_cost_per_token: 0.00000375  # example: $3.75 / 1M (write premium)
      cache_read_cost_per_token: 0.0000003    # example: $0.30 / 1M (read discount)
  ```

### Step 4 — Run the agent (per-agent isolation via env var)

Each agent gets its **own** `CORTEX_SPEND_FILE`, so usage is tracked separately even
though every agent shares the **same** LiteLLM credentials
(`ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`). Because `claude` streams, the config
**must** carry `input_cost_per_token` / `output_cost_per_token` (Step 3) or the ledger
stays `$0` — see caveat 1.

```sh
export CORTEX_CA_DIR="$PWD/.cortex/tls-bridge-ca"   # persistent TLS-bridge CA (shared)

# Agent "alpha"
CORTEX_SPEND_FILE="$PWD/.cortex/spend-alpha.json" CORTEX_MAX_BUDGET=5.00 \
  rossoctl authbridge exec --config ./.cortex/CONFIG.yaml \
    --instanceName alpha --sessionServer "" -- claude -p "…"

# Agent "beta" — same credentials, separate ledger
CORTEX_SPEND_FILE="$PWD/.cortex/spend-beta.json" CORTEX_MAX_BUDGET=2.00 \
  rossoctl authbridge exec --config ./.cortex/CONFIG.yaml \
    --instanceName beta --sessionServer "" -- claude -p "…"
```

The ledger (`spend-<agent>.json`) accumulates `{date,total_spend,total_calls}` and
resets at midnight UTC. When `total_spend >= max_budget`, further requests get
**HTTP 429** (`budget.exceeded`).

### Step 5 — Verify

- Watch the pipeline log: `tail -f /tmp/authbridge.log` (or the `--logfile` you set;
  `LOG_LEVEL=debug rossoctl -v authbridge exec …` shows per-plugin invocations).
- After a run, inspect each ledger: `cat ./.cortex/spend-*.json`.
- Confirm the numbers differ per agent and match `calls × per-call cost`.

## Critical caveats (learned by testing this end-to-end)

1. **Endpoint header naming.** `litellm-budget-track` reads the bare
   `x-litellm-response-cost` header. On LiteLLM ≥ ~1.85, the **OpenAI**
   `/v1/chat/completions` responses carry it, but the **Anthropic** `/v1/messages`
   endpoint (what Claude Code uses) may only emit `x-litellm-response-cost-original`
   (plus `-discount-amount` / `-margin-*`). If Claude Code traffic records `$0`,
   check the actual response headers with a direct curl:
   ```sh
   curl -sS -D - -o /dev/null -H "authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
     -H "content-type: application/json" \
     -d '{"model":"<a-model-the-key-can-access>","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' \
     "$ANTHROPIC_BASE_URL/v1/chat/completions" | grep -i litellm
   ```
   Verify per-agent tracking against an endpoint that emits the bare header.
   Also note that **streamed** responses (Claude Code's `/v1/messages`, or any
   `stream:true` call) report cost `0` in the header — the total is not known when
   the headers are sent. To track those, use the streaming-enhanced plugin
   (`fix_streaming_litellm_plugin`) and set `input_cost_per_token` /
   `output_cost_per_token` in the config (see the template) so cost is computed from
   the parsed token usage.

2. **Plugin bug (fix lives on a branch, not yet upstream).** Older
   `litellm-budget-track` reads `pctx.Headers` (the *request* headers) in
   `OnResponse` instead of `pctx.ResponseHeaders`, so it **never** records cost. If
   your build shows `$0` despite the cost header being present, you built against an
   unfixed `cortex`. Use the ready-made branch
   [`aslom/cortex@fix_streaming_litellm_plugin`](https://github.com/aslom/cortex/tree/fix_streaming_litellm_plugin)
   as shown in Step 1 (`git clone -b fix_streaming_litellm_plugin …`). It is stacked on
   `fix_litellm_plugin`, so it has the response-header fix
   (`pctx.ResponseHeaders.Get(...)`, mirroring the `opa` plugin), the `-original`
   fallback, **and** streaming usage-based pricing — plus unit tests. No manual
   patching required. (For the header fix alone, `fix_litellm_plugin` suffices.)

3. **TLS bridge is mandatory for HTTPS cost tracking** — without it, egress is an
   opaque CONNECT tunnel and the plugin can't read response headers.

4. **`ca_dir` must persist** across runs and be writable; regenerating the CA each run
   breaks client trust.

5. **Sandbox paths** — write configs, ledgers, CA dir, and logs under the project
   tree, not `/tmp`, if the environment restricts `/tmp`.

6. **Prompt caching (streaming pricing only).** Claude Code caches heavily, and a
   provider charges a **premium** to *write* a cache entry and a steep **discount** to
   *read* one — so two turns with identical prompt-token counts can differ ~10× in
   price. The usage fallback prices the tiers separately: `input_cost_per_token`
   (uncached), `cache_write_cost_per_token`, `cache_read_cost_per_token`. If you leave
   the two cache rates unset they default to `input_cost_per_token` (flat), which
   **overstates cache-heavy traffic up to ~10× and trips the 429 that much earlier** —
   set them to your provider's real cache prices. This only affects the usage-fallback
   (streamed) path; when LiteLLM's `x-litellm-response-cost` header is present it
   already accounts for cache tiers and wins.

## Assets

- `templates/litellm-budget-track.yaml` — ready-to-edit forward-proxy + TLS-bridge +
  `litellm-budget-track` config.
- `templates/agent.sh` — a minimal "agent" that makes N LiteLLM `/v1/chat/completions`
  calls through the injected proxy; handy for validating tracking without a full app.
- `reference/plugins.md` — full plugin catalog with per-plugin config fields.
