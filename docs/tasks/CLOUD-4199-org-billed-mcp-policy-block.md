
# Task CLOUD-4199 - reachable-risk-triage-action: k9 MCP server "blocked by policy" on the org-billed Copilot path

The objective of this task is to make the action's default, README-recommended Copilot auth path work end to end. On that path, Copilot CLI authenticates with the caller's Actions token plus `copilot-requests: write`, billed to the org's Copilot Business/Enterprise plan. Today Copilot CLI 1.0.80 blocks the k9 MCP server there:

```
! 1 MCP server was blocked by policy: 'k9'
```

Without the k9 MCP server the agent can't score anything. In demo run [38639343630](https://github.com/k9securityio/demo-k9-cloudsec-agent/actions/runs/38639343630) (cancelled) it searched the filesystem for MCP config and tried `curl`, which the CLI's tool permissions denied. Any customer on the recommended path can hit this. The fix ships as a `fix:` release, which also unblocks the full end-to-end runs CLOUD-4198 still needs on `ubuntu-24.04` and `ubuntu-26.04`.

What's known (found during CLOUD-4198):

- The org-billed path was never exercised with MCP before 2026-10-14. demo-k9-cloudsec-agent always used a personal token (`copilot-github-token`) until that plan ended on 2026-10-06, then moved to the org path (demo `dcb6a12`).
- The k9securityio Copilot Business setup: 1 seat (`skuenzli`). Enabled policies: MCP servers in Copilot, Copilot CLI, Copilot CLI billed to the organization, and the models Claude Sonnet 5, Sonnet 5.5 and Opus 5.5. The MCP registry URL is empty.
- The MCP message changed once MCP was enabled, from `Third-party MCP servers are disabled by your organization's Copilot policy` to `1 MCP server was blocked by policy: 'k9'`. The model error (`claude-sonnet-5 … is not available`) cleared after about 15 minutes of propagation; the MCP block didn't.
- How the action runs the CLI (`action.yml`, "Run triage agent"): a fresh `COPILOT_HOME=$RUNNER_TEMP/copilot-home` every run, the k9 server written to `$COPILOT_HOME/mcp-config.json` as an HTTP server with a bearer header, `copilot -p … --allow-tool 'k9' --allow-tool 'shell' --allow-tool 'write' --no-ask-user`, and output tee'd to `out/agent-run.log`. CLI pinned at 1.0.80 (2026-08-14); latest is 1.0.98 (2026-10-14).

Likely causes, from known Copilot CLI issues:

1. **Policy-fetch race with a fresh config directory.** MCP initialization finishes before the org policy fetch resolves, so the CLI fails closed ([copilot-cli#2567](https://github.com/github/copilot-cli/issues/2567); auth-timing variant [#4957](https://github.com/github/copilot-cli/issues/4957)). The changelog shows this area still changing: 1.0.89 and 1.0.96 fix behaviour "while managed MCP policy is still being applied" / "while enterprise policy is still resolving".
2. **The policy fetch fails with the Actions token.** The CLI blocks non-default MCP servers when `api.github.com/copilot/mcp_registry` returns 401/403/404 ([#4378](https://github.com/github/copilot-cli/issues/4378), [#2486](https://github.com/github/copilot-cli/issues/2486), [#2479](https://github.com/github/copilot-cli/issues/2479)). An Actions installation token may not be accepted by that endpoint, even though the org-billed path itself is authorized.

Constraints:

- **Debug logs may contain secrets.** The k9 MCP bearer token is in the MCP config headers, and the Actions token and `GH_TOKEN` PAT are in the environment. Anything uploaded to the run artifact is readable by everyone with read access to the repo. Diagnostic logs need to be scrubbed or kept off the artifact (see Questions).
- **`uses:` refs can't be parameterized**, so testing an action branch from the demo needs a temporary demo branch whose workflow points at `k9securityio/reachable-risk-triage-action@<branch>`. Test runs from that branch should run with `test-command` empty (report-only), so no fix PRs carry the temporary workflow edit (the same concern as CLOUD-4198 Q1).
- **Don't loosen the action's scope guarantees.** An experiment flag that disables the CLI's MCP allowlist (`COPILOT_EXP_COPILOT_CLI_MCP_ALLOWLIST=false`) bypasses a customer org's own MCP registry policy, so it's a last resort that needs an explicit decision.
- The demo's next scheduled run (2026-10-20 14:00 UTC) will hit this block and post a failure card to the product-security Teams channel unless it's fixed or paused first.

Out of scope: the runner-image work (CLOUD-4198); changing the `copilot-github-token` path, beyond keeping it working; supporting other agents through the `agent` input.

## High-level implementation steps

1. **Diagnostic instrumentation (action branch).** On `CLOUD-4199-org-billed-mcp-policy-block`, give the agent step Copilot CLI debug logging: `--log-dir "$COPILOT_HOME/logs"` plus the debug log-level flag (confirm the exact flag from `copilot --help` on the runner). Make the policy and MCP startup lines visible to us without exposing secrets, either by grepping only the policy, registry and MCP lines into the job log or by uploading a scrubbed log (Q-to-decide).
2. **Demo test harness.** In demo-k9-cloudsec-agent, create a temporary branch whose workflow uses `@CLOUD-4199-org-billed-mcp-policy-block`, with `test-command` empty (report-only). Dispatch it on `ubuntu-latest` with `gh workflow run --ref <demo-branch>`. Poll the run with a real wait loop; `timeout` isn't available on macOS, which caused the bogus elapsed-time reports during CLOUD-4198.
3. **Diagnose.** From the debug log, determine whether the MCP registry/policy fetch fails (and with what HTTP status), succeeds but returns an allowlist that excludes `k9`, or races MCP startup. Record the evidence here.
4. **Fix, in order of preference, matched to the diagnosis:**
   - a. Upgrade the pinned Copilot CLI to 1.0.98, or the earliest version that fixes it. Re-run the harness.
   - b. Race: add a supported mitigation in `action.yml`, such as warming the policy cache in `COPILOT_HOME` before the prompt run, or passing the server via `--additional-mcp-config` if that path is evaluated after policy resolves. Re-run.
   - c. Policy fetch rejected for the Actions token: file upstream with the scrubbed evidence, and document `copilot-github-token` as the working path until GitHub fixes it.
   - d. Last resort, only with explicit user approval: the MCP allowlist experiment flag, scoped to when no org registry is configured.
5. **README.** Add a troubleshooting row for `1 MCP server was blocked by policy: 'k9'` with the root cause and fix. Update Prerequisites if the org-billed path needs anything new.
6. **Verify on both images (AGENTS.md release rule).** Dispatch the real demo workflow (`main`, `@v1` after release, or the harness branch before release) with `runner: ubuntu-24.04` and `runner: ubuntu-26.04`. The deliverables check must pass on both, and fix PRs must behave correctly. Also confirm `make quick` stays clean.
7. **Release and close out.** Merge, then cut a `fix:` release (this can be combined with CLOUD-4198's held `v1.0.2`; the user decides when to tag and move `@v1`). Put the both-image run URLs in the release notes, delete the temporary demo branch, update CLOUD-4198/CLOUD-4199, and file an upstream issue if the cause is a CLI bug.

## Questions

TODO: Ask clarifying questions for this task and replace this todo with those questions.

## Detailed implementation steps

TODO: Make a detailed list of implementation steps to complete this task and replace this todo those steps.
