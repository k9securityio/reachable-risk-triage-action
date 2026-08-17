#!/usr/bin/env bash
# Fetch the k9 Reachable Risk workflow guidance from the k9 MCP server as files.
#
# The k9 server publishes its triage procedure as versioned MCP resources
# (k9://workflow/*). Agent CLIs that cannot read MCP resources (e.g. GitHub
# Copilot CLI exposes MCP tools only) still get the current server-published
# procedure: this script reads the resources over plain MCP JSON-RPC and writes
# them to files for the agent to read. The server stays the source of truth —
# nothing here restates procedure text.
#
# Env:
#   K9_MCP_URL    e.g. https://mcp.k9security.io/mcp
#   K9_MCP_TOKEN  bearer JWT (mint via client_credentials; see the workflow)
#   OUT_DIR       destination directory (default: out/k9-guidance)
set -euo pipefail

: "${K9_MCP_URL:?set K9_MCP_URL}"
: "${K9_MCP_TOKEN:?set K9_MCP_TOKEN}"
OUT_DIR="${OUT_DIR:-out/k9-guidance}"
mkdir -p "$OUT_DIR"

auth=(-H "Authorization: Bearer $K9_MCP_TOKEN"
      -H "Content-Type: application/json"
      -H "Accept: application/json, text/event-stream")

hdrs=$(mktemp)
init_resp=$(curl -sS --fail-with-body -D "$hdrs" -X POST "$K9_MCP_URL" "${auth[@]}" -d '{
  "jsonrpc":"2.0","id":1,"method":"initialize",
  "params":{"protocolVersion":"2025-06-18","capabilities":{},
            "clientInfo":{"name":"fetch-k9-guidance","version":"1"}}}')
session_id=$(grep -i '^mcp-session-id:' "$hdrs" | tr -d '\r' | awk '{print $2}')
rm -f "$hdrs"
if [ -z "$session_id" ]; then
  echo "ERROR: initialize returned no Mcp-Session-Id. Response: $init_resp" >&2
  exit 1
fi

curl -sS -o /dev/null -X POST "$K9_MCP_URL" "${auth[@]}" -H "Mcp-Session-Id: $session_id" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

fetch_resource() {
  local uri="$1" dest="$2"
  local resp text
  resp=$(curl -sS --fail-with-body -X POST "$K9_MCP_URL" "${auth[@]}" -H "Mcp-Session-Id: $session_id" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/read\",\"params\":{\"uri\":\"$uri\"}}")
  text=$(jq -er '.result.contents[0].text' <<<"$resp") || {
    echo "ERROR: $uri returned no text. Response: $resp" >&2
    exit 1
  }
  printf '%s\n' "$text" > "$dest"
  echo "fetched $uri -> $dest ($(wc -c < "$dest") bytes)"
}

fetch_resource "k9://workflow/fetch-dependency-alerts"     "$OUT_DIR/fetch-dependency-alerts.md"
fetch_resource "k9://workflow/score-dependency-alerts"     "$OUT_DIR/score-dependency-alerts.md"
fetch_resource "k9://workflow/summarize-dependency-alerts" "$OUT_DIR/summarize-dependency-alerts.md"
