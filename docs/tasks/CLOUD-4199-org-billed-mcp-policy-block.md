
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

### Q1. How do we get the Copilot CLI debug log out of the runner without exposing secrets?

Context: The policy and MCP startup decision is only visible in the CLI's debug log, written under `--log-dir`. That log can contain the k9 MCP bearer token (MCP config headers), and possibly the Actions token or the `GH_TOKEN` PAT. CLI 1.0.86+ stops writing secrets exported in the launching shell to debug logs, but the MCP header token isn't a shell export. Actions masks registered secrets (`***`) in the job log, but not in uploaded artifact files, and the k9 token is minted at runtime, so it isn't masked unless we `::add-mask::` it. The demo repo is private, but artifacts are readable by everyone with repo read access and are kept for the retention period.

Question: How should the diagnostic run surface the debug log?

Options:
  1. Job log only: after the agent step, `grep` only policy, registry, MCP and auth lines from the debug log, pipe them through a redaction filter (`Bearer …`, `ghs_…`, `github_pat_…`, `gh[opsu]_…`, and JWT-shaped strings), and print them to the job log. Also `::add-mask::` the k9 token when it's minted. Nothing goes in the artifact.
  2. Upload the full debug log through the same redaction filter as a separate artifact with `retention-days: 1`.
  3. Upload the raw log to an artifact. The quickest option, but it risks leaking a live token.

Recommendation: Option 1, on the harness branch only. It gives the evidence we need (fetch status and policy decision), keeps tokens out of files, and the `::add-mask::` for the minted k9 token is a good hardening change to keep regardless (see Q2).

Decision: TBD

### Q2. Should debug logging ship in the released action, or stay on the harness branch?

Context: Customers hitting this same block will need the same evidence. A permanent opt-in input (e.g. `debug: true`) adds input surface, a code path to test on both images, and a secret-handling obligation in a published supply-chain artifact. Separately, masking the minted k9 token (`::add-mask::`) is cheap hardening that's useful whatever we decide here.

Question: What, if anything, from the diagnostic instrumentation should ship?

Options:
  1. Ship only the `::add-mask::` hardening. Keep debug logging on the harness branch and remove it before merge.
  2. Ship an opt-in `debug` input that prints the redacted policy/MCP lines (the Q1 Option 1 mechanism) to the job log, plus the mask.
  3. Ship nothing from the diagnostics.

Recommendation: Option 1 for this fix. Revisit Option 2 as a separate issue if customers report policy problems, since the README troubleshooting row from step 5 covers the known symptom.

Decision: TBD

### Q3. What happens to demo-k9-cloudsec-agent's scheduled run on 2026-10-20 if this isn't fixed by then?

Context: The schedule is weekly, Tuesday 14:00 UTC. Until the fix ships, every run will fail on the MCP block and post a failure card to the product-security Teams channel. `gh workflow disable` would also block the `workflow_dispatch` runs we need for testing, because it disables the workflow from every ref.

Question: How should we handle the demo's schedule while CLOUD-4199 is open?

Options:
  1. Temporarily remove the `schedule:` trigger on the demo's `main`, keeping `workflow_dispatch`. Restore it in the close-out step after the fix is verified.
  2. Leave the schedule. One or two failure cards are acceptable signal.
  3. `gh workflow disable` and re-enable around each test dispatch.

Recommendation: Option 1 if the fix isn't verified by 2026-10-19. It's a small, reversible commit that keeps manual runs working.

Decision: TBD

### Q4. Is the MCP allowlist experiment flag acceptable at all, and under what conditions?

Context: `COPILOT_EXP_COPILOT_CLI_MCP_ALLOWLIST=false` turns off the CLI's MCP registry allowlist check. It's undocumented and experimental, so it can change or disappear in any CLI release. Worse, it would bypass a customer org's own MCP registry policy, overriding an admin's security control inside a published action that runs with secrets in scope. Using it once as a diagnostic, to confirm the block comes from the allowlist check, is different from shipping it.

Question: How may the experiment flag be used?

Options:
  1. Diagnostic only, on the harness branch, to confirm the cause. Never ship it.
  2. Ship it only when the org has no MCP registry configured (if the action can detect that), as a documented workaround.
  3. Ship it as a caller opt-in input with a clear warning.
  4. Don't use it at all.

Recommendation: Option 1. A published action shouldn't override customer MCP policy. If the root cause is the CLI rejecting the Actions token, the right fixes are upstream and documenting the `copilot-github-token` path.

Decision: TBD

### Q5. How far should the Copilot CLI pin move, given 18 releases of behaviour change between 1.0.80 and 1.0.98?

Context: The pin is a deliberate, version-bounded zizmor exception (`adhoc-packages`), so every bump is a supply-chain review. 1.0.81–1.0.98 include MCP startup and policy fixes (1.0.89, 1.0.96), and also behaviour changes. One example: 1.0.92 "Sandboxed shells now withhold ambient GITHUB_TOKEN". That should only matter if the CLI sandbox is on (it's opt-in), and the agent's `gh` uses `GH_TOKEN`, not `GITHUB_TOKEN`. But prompt and tool semantics can still shift.

Question: Which version should we target if an upgrade fixes the block?

Options:
  1. 1.0.98 (latest). The both-image demo runs validate it, the same as any release.
  2. The earliest version that fixes it, found by bisecting with harness runs. That's the smallest change, but costs more runs and more org Copilot credits.
  3. Latest, but keep an `npm view` check of each new version's changelog in the release notes.

Recommendation: Option 1. Bisecting costs real runs, and the both-image runs (AGENTS.md rule) are the actual safety net. Note the version jump and its notable changes in the release notes.

Decision: TBD

### Q6. Should this fix ship together with CLOUD-4198's held `v1.0.2`?

Context: `v1.0.2` (CLOUD-4198: docs, the CI matrix, and a description-only `action.yml` change) is merged on `main` but untagged, at your decision. CLOUD-4198 still needs full triage runs on both images, and those runs are exactly this task's verification step. One release means one set of notes and one move of `@v1`.

Question: Should the CLOUD-4199 fix and the CLOUD-4198 changes go out as a single release?

Options:
  1. One release, `v1.0.2`, with both changes. The both-image runs on the fixed path satisfy both tasks' verification, and CLOUD-4198 closes with it.
  2. Tag `v1.0.2` now (docs-only), then `v1.0.3` for this fix.
  3. Hold everything until this fix is verified, with no fixed date.

Recommendation: Option 1. You've held `v1.0.2` already, the 2026-10-19 date was about docs reaching Marketplace readers during the rollout, and the action's runtime is unaffected by the image change.

Decision: TBD

### Q7. If the root cause is that GitHub rejects the Actions token for the MCP policy fetch, with no workaround, what's the interim customer position?

Context: In that case the README-recommended path can't use the k9 MCP server until GitHub fixes the CLI or API. The fallback `copilot-github-token` needs an individual Pro/Pro+ plan, which GitHub stopped selling in April 2026, so new customers would have no working Copilot path. That's a product problem, not just a docs one.

Question: What do we do if no fix is in our control?

Options:
  1. File upstream with the redacted evidence; document the limitation in the README (troubleshooting plus a Prerequisites note); and open a separate Jira issue to prioritise a second agent (Claude Code) behind the existing `agent` input.
  2. File upstream and document only; wait for GitHub.
  3. Treat it as a blocker for promoting the action until resolved.

Recommendation: Option 1. It's honest with customers and adds a path that doesn't depend on GitHub's Copilot policy.

Decision: TBD

## Detailed implementation steps

TODO: Make a detailed list of implementation steps to complete this task and replace this todo those steps.
