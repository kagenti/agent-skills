#!/bin/sh
# A minimal "agent": makes N LiteLLM chat-completions calls through whatever proxy
# the environment points at. `rossoctl authbridge exec` injects HTTPS_PROXY and the
# TLS-bridge CA trust vars (SSL_CERT_FILE / REQUESTS_CA_BUNDLE / NODE_EXTRA_CA_CERTS),
# so this reaches the LLM via the cortex pipeline and its plugins observe every call.
#
# Uses the /v1/chat/completions (OpenAI) endpoint because that response carries the
# bare `x-litellm-response-cost` header that litellm-budget-track reads.
#
# Env:
#   ANTHROPIC_BASE_URL   LiteLLM base URL (e.g. https://litellm.example.com)
#   ANTHROPIC_AUTH_TOKEN LiteLLM key
#   AGENT_MODEL          model the key can access (default claude-haiku-4-5-20251001)
#   AGENT_CALLS          number of calls (default 3)
#   SSL_CERT_FILE        injected by exec; used as curl --cacert
#
# set -u so a missing ANTHROPIC_AUTH_TOKEN / ANTHROPIC_BASE_URL fails with a clear
# "unbound variable" instead of a confusing empty-URL / 401 from curl. The optional
# vars above are read with ${VAR:-default} / ${VAR:+word}, which are set -u-safe.
set -eu
N="${AGENT_CALLS:-3}"
MODEL="${AGENT_MODEL:-claude-haiku-4-5-20251001}"
i=1
while [ "$i" -le "$N" ]; do
  curl -sS ${SSL_CERT_FILE:+--cacert "$SSL_CERT_FILE"} -o /dev/null \
    -w "call $i -> HTTP %{http_code}\n" \
    -H "authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
    -H "content-type: application/json" \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"say OK\"}]}" \
    "$ANTHROPIC_BASE_URL/v1/chat/completions"
  i=$((i+1))
done
