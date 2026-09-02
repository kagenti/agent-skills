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
| `session-budget` | outbound | Per-session token/call/duration budgets via Redis. Opt-in build tag; try it via the `authbridge-proxy-sessionbudget` release binary (see Step 1 alternative). |
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

### Step 1 — Get an `authbridge-proxy` binary (primary path)

The fastest way is to download a prebuilt `authbridge-proxy` binary from the
cortex GitHub Release. This is the standalone pipeline runner — no `rossoctl`
required for the pipeline itself (rossoctl only adds the `authbridge exec`
convenience wrapper; see Step 4 for the manual equivalent).

Pick the variant for the plugin set you want:

| Variant | Tarball | Includes |
|---|---|---|
| default | `authbridge-proxy_<ver>_<os>_<arch>.tar.gz` | full plugin set (litellm-budget-track, jwt-validation, token-exchange, parsers, ibac, opa, sparc, token-broker) |
| `-lite` | `authbridge-proxy-lite_<ver>_<os>_<arch>.tar.gz` | jwt-validation + token-exchange only |
| `-sessionbudget` | `authbridge-proxy-sessionbudget_<ver>_<os>_<arch>.tar.gz` | default + opt-in `session-budget` plugin (needs Redis) |

```sh
# Detect host, download, verify, install. Replace <VER> with a v* tag from
# https://github.com/rossoctl/cortex/releases (or use "latest" via the API).
OS=$(uname -s | tr '[:upper:]' '[:lower:]')          # linux | darwin
ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH=amd64
VER=<VER>                                             # e.g. v0.4.0
VARIANT=""                                            # "" | "-lite" | "-sessionbudget"

curl -fsSLO "https://github.com/rossoctl/cortex/releases/download/${VER}/authbridge-proxy${VARIANT}_${VER}_${OS}_${ARCH}.tar.gz"
curl -fsSLO "https://github.com/rossoctl/cortex/releases/download/${VER}/checksums.txt"
grep "authbridge-proxy${VARIANT}_${VER}_${OS}_${ARCH}.tar.gz" checksums.txt | sha256sum -c -
tar -xzf "authbridge-proxy${VARIANT}_${VER}_${OS}_${ARCH}.tar.gz"

# macOS only: clear Gatekeeper quarantine so the binary can execute.
[ "$OS" = "darwin" ] && xattr -dr com.apple.quarantine ./authbridge-proxy

./authbridge-proxy -version
```

### Step 1 (alternative) — Build `rossoctl` from source

If you want the `rossoctl authbridge exec` wrapper (auto-injects `HTTPS_PROXY`
and CA-trust env vars into the child process), build rossoctl. Plain Go build
pulls the current cortex authlib from the module proxy — no fork clone or
replace directive needed since the litellm-budget-track streaming fix landed
on `rossoctl/cortex` main.

```sh
# Already installed? Use it.
command -v rossoctl && rossoctl version

git clone https://github.com/rossoctl/rossoctl-cli.git && cd rossoctl-cli
CGO_ENABLED=0 go build -o bin/rossoctl . && export PATH="$PWD/bin:$PATH"
```

Or install a rossoctl prebuilt release: `curl -fsSL
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
      # Prompt-cache tiers — set to your provider's real prices (see caveat 5);
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

**Without rossoctl** (using the standalone binary from Step 1): run
`authbridge-proxy` in one shell and export the proxy + CA env vars in the
shell that runs `claude`. The forward proxy binds to a kernel-picked port
(from `forward_proxy_addr: "localhost:0"` in the config); grep the log for
the port. This is what `rossoctl authbridge exec` does automatically.

```sh
export CORTEX_CA_DIR="$PWD/.cortex/tls-bridge-ca"
export CORTEX_SPEND_FILE="$PWD/.cortex/spend-alpha.json"
export CORTEX_MAX_BUDGET=5.00

# Shell 1: run the pipeline
./authbridge-proxy --config ./.cortex/CONFIG.yaml 2>&1 | tee /tmp/authbridge.log

# Shell 2: point claude at the proxy
PORT=$(awk '/forward-proxy.*addr=127.0.0.1:/{ sub(/.*addr=127.0.0.1:/,""); sub(/[^0-9].*/,""); print; exit }' /tmp/authbridge.log)
export HTTPS_PROXY="http://127.0.0.1:${PORT}"
export HTTP_PROXY="${HTTPS_PROXY}"
export SSL_CERT_FILE="$CORTEX_CA_DIR/ca.crt"
export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
export NODE_EXTRA_CA_CERTS="$SSL_CERT_FILE"
claude -p "…"
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
   `stream:true` call) report cost `0` in the header — the total is not known
   when the headers are sent. To track those, set `input_cost_per_token` /
   `output_cost_per_token` in the config (see the template) so cost is computed
   from the parsed token usage. The response-header fix and streaming pricing
   both landed on `rossoctl/cortex` main (PRs #815 and #816); older builds that
   predate them silently record `$0`.

2. **TLS bridge is mandatory for HTTPS cost tracking** — without it, egress is an
   opaque CONNECT tunnel and the plugin can't read response headers.

3. **`ca_dir` must persist** across runs and be writable; regenerating the CA each run
   breaks client trust.

4. **Sandbox paths** — write configs, ledgers, CA dir, and logs under the project
   tree, not `/tmp`, if the environment restricts `/tmp`.

5. **Prompt caching (streaming pricing only).** Claude Code caches heavily, and a
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
