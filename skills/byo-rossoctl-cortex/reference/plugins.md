# AuthBridge plugin reference

Plugins go under `pipeline.inbound.plugins` or `pipeline.outbound.plugins`, each as
`{ name: <plugin>, on_error: enforce|observe|off, config: {…} }`. In
`rossoctl authbridge exec` the **forward proxy runs the outbound pipeline** (the
command's own egress) and the **reverse proxy runs the inbound pipeline** (callers
reaching the command). Config values support `${ENV_VAR}` expansion.

Source of truth: `cortex/authbridge/docs/plugin-catalog.md`. This is a working
summary of names + key config fields.

## litellm-budget-track (response-reading)
Reads `x-litellm-response-cost` (falling back to `-original`), accumulates daily
spend in a JSON ledger, returns **429** when the daily budget is exceeded. Ledger
`{date,total_spend,total_calls}` resets at midnight UTC.
- `spend_file` (string, required) — JSON ledger path. Parameterize with an env var
  (`${CORTEX_SPEND_FILE}`) to get **per-agent** isolation.
- `max_budget` (float, required, >0) — daily budget in USD.
- `input_cost_per_token` / `output_cost_per_token` (float, USD/token, optional) —
  price **streamed** responses (whose header cost is `0`) from parsed SSE token
  usage; `input_cost_per_token` is the **uncached** input rate. Requires the
  streaming-enhanced plugin (`aslom/cortex@fix_streaming_litellm_plugin`). Leave unset
  for non-streaming traffic, which is priced from the response header.
- `cache_write_cost_per_token` / `cache_read_cost_per_token` (float, USD/token,
  optional) — price the prompt-cache tiers separately. A cache **write** costs a
  premium and a cache **read** a steep discount, so pricing them at the flat input
  rate overstates cache-heavy traffic (Claude Code) up to ~10× and trips the 429 too
  early. Each defaults to `input_cost_per_token` when unset (flat); set to your
  provider's real cache prices for accurate budgets.

## jwt-validation (inbound)
Validate inbound JWT signature (JWKS) / issuer / audience.
- `issuer` (required); `jwks_url` (derived from issuer/keycloak when omitted);
  `keycloak_url` / `keycloak_realm`; `audience` / `audience_file` (default
  `/shared/client-id.txt`) / `audience_mode` (`static`|`per-host`);
  `allowed_audiences[]`; `bypass_paths[]`; `placeholder_mode`; `placeholder_ttl`.

## token-exchange (outbound)
RFC 8693 outbound token exchange per host route (Keycloak/Entra/Okta/generic).
- `token_url` (or derive via `provider`+`provider_url`(+`provider_realm`));
  `default_policy` (`passthrough`|`exchange`); `no_token_policy`
  (`client-credentials`|`allow`|`deny`); `identity.type` (`spiffe`|`client-secret`,
  required) + `identity.client_id[_file]` / `client_secret[_file]` /
  `jwt_audience` / `assertion_type`; `routes.file` / `routes.rules[]`;
  `audience_from_host`; `resolve_placeholders`.

## static-inject (outbound)
Swap a placeholder credential for a real static secret on egress.
- `source` (`secret_dir`|`mappings`); `secret_dir`; `mappings{}`; `key_by`
  (`host`|`static`); `key`; `placeholder`; `inject_header` (default `Authorization`).

## ibac (outbound)
LLM-judge intent-based access control on outbound tool calls (catches
prompt-injection / exfiltration).
- `judge_endpoint`, `judge_model`, `judge_bearer`, `system_prompt`, `timeout_ms`,
  `judge_max_tokens`, `judge_json_mode`, `judge_inference`, `agent_llm_host`,
  `bypass_hosts[]`/`bypass_paths[]`, `no_intent_policy` (`allow`|`deny`),
  `unclassified_policy` (`passthrough`|`judge`).

## opa (both)
Evaluate OPA policy bundles on inbound + outbound requests.
- `bundle_url` (required); `agent_id_file` (default `/shared/client-id.txt`) /
  `agent_id`; `polling_min_delay`/`polling_max_delay`; `include[]`.

## sparc (outbound)
Pre-tool reflection; blocks ungrounded/hallucinated tool calls.
- `reflector_endpoint` (required); `reflector_bearer`; `enforcement`
  (`mcp`|`inference`); `track`; `timeout_ms`; `on_reject_action`
  (`observe`|`reflect`|`deny`); `deny_score_threshold`; `fail_policy`
  (`open`|`closed`); `skip_tools[]`/`reflect_tools[]`; `bypass_hosts[]`/`bypass_paths[]`.

## session-budget (outbound, opt-in build tag)
Per-session token/call/duration budgets via Redis.
- `redis_url` (required); `max_tokens`; `max_calls`; `max_duration_seconds`;
  `on_exceed` (`deny`|`observe`|`pause`); `pause_webhook`/`pause_timeout`/…;
  `session_ttl_seconds`; `refresh_interval`; `redis_unavailable` (`fail_open`).

## token-broker (outbound)
Exchange incoming tokens via an external broker per host route.
- `broker_url` (required); `default_policy` (`passthrough`|`broker`);
  `routes.file` / `routes.rules[]` (`host`, `action`, `authorization_endpoint`,
  `token_endpoint`).

## Parsers — a2a-parser / mcp-parser / inference-parser
Populate `pctx.Extensions.{A2A,MCP,Inference}` for downstream guardrails.
- `a2a-parser`, `inference-parser`: no config.
- `mcp-parser`: `paths[]` (default `["/mcp"]`).

## context-guru (outbound, opt-in `-tags include_plugin_contextguru`)
Compact the outbound LLM request context.
- `paths[]`; `model{base_url,model,api_key,max_tokens,timeout_ms}`; `engine{…}`
  (native context-guru pipeline/components). See
  `rossoctl-cli/examples/context-guru-tls-bridge.yaml` for a full example.

## cpex (outbound, separate `authbridge-cpex` binary, `-tags cpex`, cgo)
APL DSL + named CPEX policy plugins (Cedar, PII, audit, …).
- `hooks.on_request[]`/`hooks.on_response[]`; `config` or `config_file`;
  `fail_open`; `worker_threads`; `bypass_hosts[]`/`bypass_paths[]`.
