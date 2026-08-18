#!/usr/bin/env bash
# Post the triage-run outcome to Microsoft Teams via a *Workflows* webhook
# (Power Automate; classic Office 365 incoming webhooks were retired 2026-05).
# Payload is an Adaptive Card. Reads out/triage-summary.json written by the
# agent; a missing or unparsable summary produces a run-failed card so a wedged
# run is loud, never silent.
#
# Env: TEAMS_WEBHOOK_URL, RUN_URL, JOB_STATUS (from the workflow)
set -euo pipefail

: "${TEAMS_WEBHOOK_URL:?set TEAMS_WEBHOOK_URL}"
RUN_URL="${RUN_URL:-}"
JOB_STATUS="${JOB_STATUS:-unknown}"
SUMMARY_FILE="${SUMMARY_FILE:-out/triage-summary.json}"

if jq -e '.schema == "k9-triage-summary/v2"' "$SUMMARY_FILE" >/dev/null 2>&1; then
  card=$(jq --arg run_url "$RUN_URL" '
    {
      type: "message",
      attachments: [{
        contentType: "application/vnd.microsoft.card.adaptive",
        content: {
          "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          type: "AdaptiveCard",
          version: "1.4",
          body: [
            { type: "TextBlock", size: "Large", weight: "Bolder",
              text: "Dependency alert triage: \(.repo)" },
            { type: "TextBlock", isSubtle: true, wrap: true,
              text: "\(.date) - status: \(.status) - rubric \(.rubric_version)" },
            { type: "FactSet", facts: [
                { title: "Alerts scored", value: (.alerts_total | tostring) },
                { title: "FIX_TODAY",  value: (.verdicts.FIX_TODAY // 0 | tostring) },
                { title: "REVIEW",     value: (.verdicts.REVIEW // 0 | tostring) },
                { title: "SCHEDULE",   value: (.verdicts.SCHEDULE // 0 | tostring) },
                { title: "DEFER",      value: (.verdicts.DEFER // 0 | tostring) },
                { title: "Fix PRs opened", value: (.prs_opened | length | tostring) },
                { title: "Dependabot PRs ready", value: (.prs_ready | length | tostring) }
            ]},
            { type: "TextBlock", wrap: true, text: .detail }
          ],
          actions: [
            { type: "Action.OpenUrl", title: "Open report (run page)", url: $run_url }
          ]
        }
      }]
    }' "$SUMMARY_FILE")
else
  card=$(jq -n --arg run_url "$RUN_URL" --arg status "$JOB_STATUS" '
    {
      type: "message",
      attachments: [{
        contentType: "application/vnd.microsoft.card.adaptive",
        content: {
          "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          type: "AdaptiveCard",
          version: "1.4",
          body: [
            { type: "TextBlock", size: "Large", weight: "Bolder", color: "Attention",
              text: "Dependency alert triage run FAILED" },
            { type: "TextBlock", wrap: true,
              text: "Job status: \($status). The run produced no readable triage summary; inspect the run log." }
          ],
          actions: [
            { type: "Action.OpenUrl", title: "Open failed run", url: $run_url }
          ]
        }
      }]
    }')
fi

http_code=$(curl -sS -o /tmp/teams-resp.txt -w '%{http_code}' -X POST "$TEAMS_WEBHOOK_URL" \
  -H 'Content-Type: application/json' -d "$card")
echo "Teams webhook HTTP $http_code"
case "$http_code" in
  2*) ;;
  *) echo "Teams notification failed: $(cat /tmp/teams-resp.txt)" >&2; exit 1 ;;
esac
