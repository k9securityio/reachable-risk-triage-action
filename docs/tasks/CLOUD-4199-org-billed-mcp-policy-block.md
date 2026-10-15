
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

> **Correction (2026-10-15):** claims in this doc that GitHub "paused" or "no longer sells" individual Copilot plans are outdated. Sign-ups for Pro, Pro+ and Student were paused from 2026-04-20 ([#192963](https://github.com/orgs/community/discussions/192963)), but GitHub began reopening Student, Pro, Pro+ and Max sign-ups gradually on 2026-06-16 ([#197089](https://github.com/orgs/community/discussions/197089)). #197089 doesn't say whether cancelled subscribers can resubscribe. The README was corrected before v1.0.2.

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

Decision: Recommendation accepted, Option 1.

### Q2. Should debug logging ship in the released action, or stay on the harness branch?

Context: Customers hitting this same block will need the same evidence. A permanent opt-in input (e.g. `debug: true`) adds input surface, a code path to test on both images, and a secret-handling obligation in a published supply-chain artifact. Separately, masking the minted k9 token (`::add-mask::`) is cheap hardening that's useful whatever we decide here.

Question: What, if anything, from the diagnostic instrumentation should ship?

Options:
  1. Ship only the `::add-mask::` hardening. Keep debug logging on the harness branch and remove it before merge.
  2. Ship an opt-in `debug` input that prints the redacted policy/MCP lines (the Q1 Option 1 mechanism) to the job log, plus the mask.
  3. Ship nothing from the diagnostics.

Recommendation: Option 1 for this fix. Revisit Option 2 as a separate issue if customers report policy problems, since the README troubleshooting row from step 5 covers the known symptom.

Decision: Recommendation accepted, Option 1.

### Q3. What happens to demo-k9-cloudsec-agent's scheduled run on 2026-10-20 if this isn't fixed by then?

Context: The schedule is weekly, Tuesday 14:00 UTC. Until the fix ships, every run will fail on the MCP block and post a failure card to the product-security Teams channel. `gh workflow disable` would also block the `workflow_dispatch` runs we need for testing, because it disables the workflow from every ref.

Question: How should we handle the demo's schedule while CLOUD-4199 is open?

Options:
  1. Temporarily remove the `schedule:` trigger on the demo's `main`, keeping `workflow_dispatch`. Restore it in the close-out step after the fix is verified.
  2. Leave the schedule. One or two failure cards are acceptable signal.
  3. `gh workflow disable` and re-enable around each test dispatch.

Recommendation: Option 1 if the fix isn't verified by 2026-10-19. It's a small, reversible commit that keeps manual runs working.

Decision: Option 2.

### Q4. Is the MCP allowlist experiment flag acceptable at all, and under what conditions?

Context: `COPILOT_EXP_COPILOT_CLI_MCP_ALLOWLIST=false` turns off the CLI's MCP registry allowlist check. It's undocumented and experimental, so it can change or disappear in any CLI release. Worse, it would bypass a customer org's own MCP registry policy, overriding an admin's security control inside a published action that runs with secrets in scope. Using it once as a diagnostic, to confirm the block comes from the allowlist check, is different from shipping it.

Question: How may the experiment flag be used?

Options:
  1. Diagnostic only, on the harness branch, to confirm the cause. Never ship it.
  2. Ship it only when the org has no MCP registry configured (if the action can detect that), as a documented workaround.
  3. Ship it as a caller opt-in input with a clear warning.
  4. Don't use it at all.

Recommendation: Option 1. A published action shouldn't override customer MCP policy. If the root cause is the CLI rejecting the Actions token, the right fixes are upstream and documenting the `copilot-github-token` path.

Decision: Recommendation accepted, Option 1.

### Q5. How far should the Copilot CLI pin move, given 18 releases of behaviour change between 1.0.80 and 1.0.98?

Context: The pin is a deliberate, version-bounded zizmor exception (`adhoc-packages`), so every bump is a supply-chain review. 1.0.81–1.0.98 include MCP startup and policy fixes (1.0.89, 1.0.96), and also behaviour changes. One example: 1.0.92 "Sandboxed shells now withhold ambient GITHUB_TOKEN". That should only matter if the CLI sandbox is on (it's opt-in), and the agent's `gh` uses `GH_TOKEN`, not `GITHUB_TOKEN`. But prompt and tool semantics can still shift.

Question: Which version should we target if an upgrade fixes the block?

Options:
  1. 1.0.98 (latest). The both-image demo runs validate it, the same as any release.
  2. The earliest version that fixes it, found by bisecting with harness runs. That's the smallest change, but costs more runs and more org Copilot credits.
  3. Latest, but keep an `npm view` check of each new version's changelog in the release notes.

Recommendation: Option 1. Bisecting costs real runs, and the both-image runs (AGENTS.md rule) are the actual safety net. Note the version jump and its notable changes in the release notes.

Decision: Recommendation accepted, Option 1.

### Q6. Should this fix ship together with CLOUD-4198's held `v1.0.2`?

Context: `v1.0.2` (CLOUD-4198: docs, the CI matrix, and a description-only `action.yml` change) is merged on `main` but untagged, at your decision. CLOUD-4198 still needs full triage runs on both images, and those runs are exactly this task's verification step. One release means one set of notes and one move of `@v1`.

Question: Should the CLOUD-4199 fix and the CLOUD-4198 changes go out as a single release?

Options:
  1. One release, `v1.0.2`, with both changes. The both-image runs on the fixed path satisfy both tasks' verification, and CLOUD-4198 closes with it.
  2. Tag `v1.0.2` now (docs-only), then `v1.0.3` for this fix.
  3. Hold everything until this fix is verified, with no fixed date.

Recommendation: Option 1. You've held `v1.0.2` already, the 2026-10-19 date was about docs reaching Marketplace readers during the rollout, and the action's runtime is unaffected by the image change.

Decision: Recommendation accepted, Option 1.

### Q7. If the root cause is that GitHub rejects the Actions token for the MCP policy fetch, with no workaround, what's the interim customer position?

Context: In that case the README-recommended path can't use the k9 MCP server until GitHub fixes the CLI or API. The fallback `copilot-github-token` needs an individual Pro/Pro+ plan, which GitHub stopped selling in April 2026, so new customers would have no working Copilot path. That's a product problem, not just a docs one.

Question: What do we do if no fix is in our control?

Options:
  1. File upstream with the redacted evidence; document the limitation in the README (troubleshooting plus a Prerequisites note); and open a separate Jira issue to prioritise a second agent (Claude Code) behind the existing `agent` input.
  2. File upstream and document only; wait for GitHub.
  3. Treat it as a blocker for promoting the action until resolved.

Recommendation: Option 1. It's honest with customers and adds a path that doesn't depend on GitHub's Copilot policy.

Decision: Recommendation accepted, Option 1.

## Detailed implementation steps

Planning note: the Q1/Q2 decision to "mask the minted k9 token" is already in place. The "Mint k9 MCP token" step runs `echo "::add-mask::$token"`, so no extra hardening ships, and per Q2 nothing from the diagnostics ships at all.

How to wait on runs: macOS has no `timeout`, and `gh run watch` / `gh pr checks --watch` return straight away without a terminal. Poll with a `SECONDS`-bounded loop: `end=$((SECONDS+570)); while [ $SECONDS -lt $end ]; do …; sleep 30; done`, run in the background and re-armed until the run completes. Check the real clock before reporting any elapsed time.

### Phase A — Diagnose the MCP policy block

Deliverable: redacted Copilot CLI debug evidence in a demo job log showing why `k9` is blocked, recorded in this doc, with no secret patterns in the log.

1. ✅ **Diagnostic instrumentation (action branch, temporary).** On `CLOUD-4199-org-billed-mcp-policy-block`, in one commit titled `chore(diag): temporary Copilot CLI policy diagnostics - CLOUD-4199 (revert before merge)`:
   - In the agent step, before the `copilot -p` call, print the CLI's logging flags: `copilot --help | grep -i -E 'log|mcp'` (the help text holds no secrets). Then add `--log-dir "$COPILOT_HOME/logs"` and the debug log-level flag to the `copilot -p` call. Confirm the flag name from the help output in the first run; if it isn't accepted, re-run with the right one.
   - Add a step right after the agent step, `Diagnostics: Copilot CLI policy and MCP lines (temporary)`, with `if: always()` so it also runs when the job is cancelled. It runs `grep -h -i -E 'policy|registry|allowlist|mcp|auth|unauthori|forbidden|40[134]' "$RUNNER_TEMP/copilot-home/logs"/*`, pipes the output through a redaction `sed`, and keeps the first 400 lines with `head -400`. The `sed` replaces:
     - `Bearer [A-Za-z0-9._~+/=-]+` → `Bearer [REDACTED]`
     - `gh[opsu]_[A-Za-z0-9]+` and `github_pat_[A-Za-z0-9_]+` → `[REDACTED]`
     - JWT-shaped `eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+` → `[JWT]`

     Nothing is added to the artifact (Q1 → Option 1).
   - `make quick` stays clean.
   - `2d2f6e1` on the action branch. `make quick` clean. The redaction filter was tested locally on all four token shapes. The log-level flag is detected from `copilot --help`.
2. ✅ **Push the action branch.** Don't open a PR yet.
3. ✅ **Demo harness branch.** In demo-k9-cloudsec-agent, create branch `cloud-4199-harness` from `main`. In `dependency-triage.yml`:
   - `uses: k9securityio/reachable-risk-triage-action@CLOUD-4199-org-billed-mcp-policy-block`
   - remove `test-command`, so runs are report-only and open no fix PRs
   - remove `teams-webhook-url`, so harness runs don't post to the channel

   This branch is temporary and never merged. Commit with `chore: CLOUD-4199 harness (do not merge)`, then push.
   - demo `cloud-4199-harness` @ `64cfc42` (report-only, no Teams).
4. ✅ **Dispatch:** `gh workflow run dependency-alert-triage -R k9securityio/demo-k9-cloudsec-agent --ref cloud-4199-harness -f runner=ubuntu-latest`. Poll as described above. The policy decision happens at CLI startup, so once the agent step has run for about 3 minutes, cancel the run (`gh run cancel`). The `if: always()` diagnostics step still runs.
   - Dispatched 21:51:14 UTC; cancelled at 21:54:55 once the agent was past CLI startup. The `if: always()` diagnostics step ran after the cancel.
5. ✅ **Verify deliverable.** Pull the job log (`gh run view <id> --log`), then:
   - confirm the diagnostics step printed the CLI's policy, registry and MCP decision lines;
   - run the leak check `grep -c -E 'gh[opsu]_[A-Za-z0-9]{20,}|github_pat_|eyJ[A-Za-z0-9_-]{10,}\.' <log>`, which must be `0`. If not, delete the run (`gh run delete`) right away and fix the filter.
   - Leak check: 21 matches, all benign. One is the `sed` pattern echoed in the step's script; 20 are `Token: github_pat_***` from the agent's `gh auth status`, already masked by Actions. No real token values. Lesson: the leak-check regex should exclude `***`-masked values.
6. ✅ **Record the diagnosis here.** Write down the fetch URL and HTTP status (or the race timing), and which cause it is: (1) policy-fetch race with a fresh `COPILOT_HOME`, (2) the policy fetch rejected for the Actions token, or (3) an allowlist returned without `k9`.
   - **Diagnosis (2026-10-14), from harness run [38643409565](https://github.com/k9securityio/demo-k9-cloudsec-agent/actions/runs/38643409565): cause 2, the policy fetch is rejected for the Actions token.** Copilot CLI 1.0.80 debug log, redacted:
     ```
     [INFO]    [managedSettings] server policy: none for this account (404/empty) from https://github.com
     [WARNING] Failed to fetch MCP registry policy: Failed to fetch MCP registry policy: 403 Forbidden. Non-default MCP servers will be blocked until the policy can be fetched.
     [ERROR]   MCP server "k9" filtered: Could not verify server against any configured registry
     ```
     It isn't a startup race: the fetch completed (50 ms after the managed-settings lookup) and returned 403. The CLI then fails closed for every non-default server; the built-in `github-mcp-server` still loads. The model is fine (`claude-sonnet-5` served; CAPI models list shows `restricted_to: pro_plus, business, enterprise, max`).

### Phase B — Fix

Deliverable: a harness run on the fixed action branch reaches the k9 MCP server and the triage completes report-only, with the deliverables check green.

7. ✅ **Apply the fix that matches the diagnosis,** trying each in order and re-running the harness (step 4, but letting the run finish) after each change:
   - a. ✅ **Copilot CLI 1.0.98** (Q5 → Option 1). In "Install GitHub Copilot CLI", change the pin to `@github/copilot@1.0.98`, keeping the `zizmor: ignore[adhoc-packages]` comment. Update the pin comment ("version-pinned to the release the verified runs used"). Check that the 1.0.98 flags still work (`--allow-tool`, `--no-ask-user`, and `--model` against the help output).
   - b. ❌ **If it's still a race** (cause 1): a supported mitigation in the agent step, such as passing the server with `--additional-mcp-config @"$COPILOT_HOME/mcp-config.json"` instead of relying on the config file in `COPILOT_HOME`, if the diagnosis shows that path is evaluated after policy resolves. Re-run.
   - c. ❌ **To confirm a cause only** (Q4 → Option 1): one harness run with `COPILOT_EXP_COPILOT_CLI_MCP_ALLOWLIST=false` set on the agent step, in a separate commit that gets reverted straight away. Never merged.
   - d. ❌ **If the Actions token is rejected and nothing in our control fixes it** (Q7 → Option 1):
     - file an upstream issue at github/copilot-cli with the redacted evidence;
     - document the limitation in the README (Prerequisites note and troubleshooting row), naming `copilot-github-token` as the working path for people who already hold an individual plan;
     - open a separate CLOUD Jira issue to prioritise Claude Code support behind the `agent` input.
   - Result: **7a fixed it.** `1da3541` pins `@github/copilot@1.0.98`. Harness run [38644156012](https://github.com/k9securityio/demo-k9-cloudsec-agent/actions/runs/38644156012) (with diagnostics, report-only) completed green in about 29 min: no `blocked by policy`; k9 MCP calls `score_risk` ×16, `lookup_vulns` ×4, `lookup_kev` ×2, `lookup_epss` ×2, plus `get_basis_procedure`, `get_risk_scoring_rubric` and `gather_risk_context`; the deliverables check passed; leak check 0. The 1.0.98 debug excerpt (the first 400 matching lines) has no registry-policy decision line, so the evidence for the fix is the behaviour above, not a logged status. 7b–7d weren't needed (the allowlist flag was never used).
   - New 1.0.98 behaviour to watch: shell commands touching paths **outside the workspace** are denied in headless mode (`✗ Denied, no one to approve`), even with `--allow-tool 'shell'`. Seen twice, `find / …` and a mistyped `cat /out/…`, and the agent recovered both times. Not yet exercised: `test-command` on fix branches, `git push`, `gh pr create` (the harness is report-only). Phase C's full runs must check for this denial.
8. ✅ **Remove the diagnostics.** `git revert` the `chore(diag)` commit (and any flag-test commit), leaving only the fix. Run `make quick`.
   - `a639445` reverts `2d2f6e1`. `git diff main -- action.yml` now shows only the pin change; `make quick` clean.
9. ✅ **Verify deliverable.** A harness run on the cleaned branch completes on `ubuntu-latest` without cancelling:
   - the agent log has no `blocked by policy` line, and shows k9 tool calls (e.g. `score_risk`);
   - "Check deliverables exist" passes with `k9-triage-summary/v2`;
   - the job summary has the report.

   Record the run URL. If step 7d applied instead, the deliverable is the upstream issue, the README limitation and the new Jira issue.

   - Clean run [38647781170](https://github.com/k9securityio/demo-k9-cloudsec-agent/actions/runs/38647781170) (`a639445`, no diagnostics, report-only, `ubuntu-latest`) completed green in about 32 min: `blocked by policy` ×0; `score_risk` ×15 plus `get_basis_procedure`, `get_risk_scoring_rubric`, `lookup_kev` and `lookup_epss`; the deliverables check passed (`stamped triage-summary.json`); leak check 0.
   - Path denials (`Denied, no one to approve`) ×4, all reachability probes outside the workspace: `~/.local/lib/python3.12/site-packages`, `pip install pipdeptree`, and `find /`. **Not a regression**: the last good 1.0.80 run (2026-09-29, [36579559026](https://github.com/k9securityio/demo-k9-cloudsec-agent/actions/runs/36579559026)) had 5 of the same denials (`Permission denied and could not request permission from user`). Proposed as a separate follow-on: decide whether the agent should get read access to installed dependency trees outside the workspace (`--add-dir` for site-packages/node_modules), weighed against secrets on the runner.

### Phase C — Docs, PR, and verification on both images

Deliverable: the fix merged to `main`, with green end-to-end demo triage runs on `ubuntu-24.04` and `ubuntu-26.04` using the merged commit (full behaviour: test-command, fix PRs, Teams).

10. ✅ **README.** Add a troubleshooting row for `1 MCP server was blocked by policy: 'k9'` with the confirmed cause and fix. If the fix is the CLI upgrade, say the action now pins a CLI version that resolves it. Update Prerequisites if the org-billed path needs anything new. Keep the Quickstart/example YAML identical to each other (the CLOUD-4198 diff check), and run `make quick`.
11. ✅ **PR.** Push, then open a PR with `fix: <confirmed fix> - CLOUD-4199`, stating the root cause, the CLI version change and its notable changes (e.g. the 1.0.92 sandboxed-shell `GITHUB_TOKEN` change), the harness evidence, and that diagnostics were removed. Poll until both `lint-and-audit` legs are green, then rebase-merge and delete the branch.
12. ✅ **Pre-release verification on both images** (AGENTS.md rule; also completes CLOUD-4198 step 14):
    - On the demo's `main`, temporarily pin `uses: k9securityio/reachable-risk-triage-action@<merged main SHA> # pre-release verification, CLOUD-4199`. Use a SHA on the demo's `main`, not a branch, so fix PRs branch from `main` and carry only the dependency bump.
    - Dispatch `runner: ubuntu-24.04` and `runner: ubuntu-26.04`, one after the other (the shared concurrency group queues them).
13. ✅ **Verify deliverable.** For both runs:
    - the job completes green;
    - "Check deliverables exist" passes;
    - fix PRs open or are skipped exactly as the report says (existing #56/#57 are handled without duplicates);
    - the Teams card arrives;
    - the image line in "Set up job" matches the requested runner.

   - **Done 2026-10-14/15. The scope grew: verification found two more Copilot CLI 1.0.98 behaviour changes, fixed on branch `CLOUD-4199-cli-permissions-subagents` (second PR):**
     - Assisted Permissions denied the caller's own commands (`python -m pip`, `python -m pytest`, even `ls .venv/bin/`) with `Denied, no one to approve`, under bare `--allow-tool 'shell'` and under `--allow-all-tools` ([fixture 38652114591](https://github.com/k9securityio/rr-triage-fixture/actions/runs/38652114591): 15 denials; [38657647124](https://github.com/k9securityio/rr-triage-fixture/actions/runs/38657647124): 12). The agent got past them through improvised command forms; the test gate held, but not by design. 1.0.80 only denied URL fetches. **Fix:** `--allow-all-tools --allow-all-paths`, with URLs still restricted, following the eval-harness principle (k9-mcp-server `drivers/claude_code.py`: shell granted outright, the container/runner is the boundary).
     - Task-tool subagents ignored `--model` and ran on Opus 5.5 once the org allowed it (billing 2026-10-14: Opus 463 credits; demo run [38647781170](https://github.com/k9securityio/demo-k9-cloudsec-agent/actions/runs/38647781170) cost 1,089 credits against 684 without subagents). They also work without the RR guidance in context. **Fix:** `--excluded-tools task`, matching the evals' enforced `--disallowedTools Task`. Opus 5.5 is also disabled in the k9securityio model policy.
     - Added step "Report denied agent commands": it counts denial lines in `agent-run.log` and lists them in the job summary with a `::warning::`, mirroring the evals' `denied_shell_commands`. Added a README troubleshooting row for it.
     - Verification moved from the demo (195 alerts, about $7–11 per run) to the cheaper rr-triage-fixture (11 alerts, about $2 per run) at the user's request. The fixture is pinned to `7070261`, uses the org-billed path, and has a `runner` input (fixture `fd7b01c` → `8e59a03` → latest). Final runs on `7070261`:
       - ubuntu-24.04 [38659441800](https://github.com/k9securityio/rr-triage-fixture/actions/runs/38659441800) and ubuntu-26.04 [38660421501](https://github.com/k9securityio/rr-triage-fixture/actions/runs/38660421501): both green; **0 denied commands**; `deps-command`/`test-command` run as written; 0 subagents; no MCP block; fix PRs #4/#5 opened only after tests passed; deliverables and Teams OK; leaks 0; 192.6 and 176.8 AI credits ($1.93 / $1.77).
     - Cost incident: the day's testing used up the seat's included AI credits (overage about $12.86). The user set an org budget for all AI Credit SKUs: $25/month, hard stop.


    Record both run URLs for the release notes.

### Phase D — Release `v1.0.2` and close out (Q6 → Option 1)

Deliverable: `v1.0.2` published with `@v1` moved, the demo back on `@v1`, and both Jira issues updated.

14. **Get your go-ahead to release.** You held `v1.0.2`, so tagging waits for your explicit OK.
15. **Tag and release.** Tag `v1.0.2` on `main`. The release notes cover:
    - CLOUD-4198: runner support policy, "Run triage like your CI", troubleshooting rows, the CI matrix, the Copilot plan wording and the AGENTS.md rules;
    - CLOUD-4199: root cause, fix, and the CLI 1.0.80 → 1.0.98 notable changes;
    - both run URLs from step 13, and the `Pin:` line with the full SHA.
16. **Move `@v1`,** again only after you confirm: `git tag -f v1 v1.0.2 && git push -f origin v1`. Verify with `git ls-remote --tags origin v1 v1.0.2` (same commit).
17. **Demo cleanup.** Revert the demo's `uses:` to `@v1`. Delete the `cloud-4199-harness` branch, and close any harness-only artifacts.
18. **Close out.**
    - Update the CLOUD-4198 task doc (steps 14, 17–21) and this doc.
    - Comment on CLOUD-4198 and CLOUD-4199 with the release link and run URLs.
    - Link the upstream issue if one was filed.
    - Run `/task-resolve` for both tasks.
