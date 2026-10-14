
# Task CLOUD-4198 - Test reachable-risk-triage-action on Ubuntu 26.04 runner before ubuntu-latest migration

The objective of this task is to confirm the action works on the Ubuntu 26.04 runner image, and to prepare the action, its docs and our own callers for the `ubuntu-latest` → Ubuntu 26.04 migration. GitHub rolls the migration out from 2026-10-19 to 2026-11-19 ([actions/runner-images#14748](https://github.com/actions/runner-images/issues/14748)). Each repo moves once, with no way back to 24.04 except pinning `runs-on: ubuntu-24.04`, which stays supported for about 2 years.

The action runs on whatever runner the caller picks. The README quickstart, `examples/dependency-triage.yml`, the action's CI and our only in-house caller (demo-k9-cloudsec-agent) all use `ubuntu-latest`. CI lints `action.yml` but never runs it, so nothing has tested the runtime path on 26.04.

Image changes that touch the action (24.04 → 26.04):

| Tool | 24.04 | 26.04 | Used by |
| --- | --- | --- | --- |
| Node / npm (default) | 22.23 / 10.9 | 24.21 / 11.19 | `npm install -g @github/copilot@1.0.80` (no setup-node) |
| Python | 3.12 | 3.14 | `pipx install zizmor` (CI); callers' `deps-command` / `test-command` |
| jq | 1.7 | 1.8.1 | token mint, deliverables check, `notify-teams.sh` |
| ShellCheck | 0.9.0 | 0.11.0 | CI release gate. `make run-shellcheck` is clean locally on 0.11.0. |
| curl / bash | 8.5 / 5.2 | 8.18 / 5.3 | everywhere |
| gh / git | 2.101 / 2.55 | unchanged | `gh auth setup-git` |
| envsubst (gettext-base) | not listed in either image readme | to confirm | prompt expansion |

The main customer-facing risk is the callers' own code, not ours. `deps-command` / `test-command` run on the runner's default Python 3.14 and Node 24. If a caller's tests fail there, the action correctly opens no fix PRs, because PRs are gated on a passing `test-command`. To the caller it looks like "triage stopped opening PRs" sometime in late October. The README should name that symptom and give the fix.

Out of scope: changing the action's scope guarantees, or pinning the example caller to a specific image. The example stays on `ubuntu-latest`, so new users get the supported default.

## High-level implementation steps

1. **CI matrix.** In `.github/workflows/ci.yml`, run `lint-and-audit` on a `runs-on` matrix of `[ubuntu-24.04, ubuntu-26.04]` instead of `ubuntu-latest`. Confirm the apt `shellcheck` install, the actionlint download and `pipx install zizmor` on Python 3.14 all work, and that `make quick` stays green on both. Keep `make quick` (and so zizmor/actionlint) clean on the edited workflow.
2. **README troubleshooting row.** Add a row for "Fix PRs stopped opening after late Oct 2026". Cause: the runner moved to Ubuntu 26.04 (Python 3.14, Node 24) and the repo's `test-command` now fails. Fix: pin `runs-on: ubuntu-24.04`, or add `actions/setup-python` / `actions/setup-node` before the action. Point readers to `agent-run.log` to confirm the test failure.
3. **Canary end-to-end run on 26.04.** In demo-k9-cloudsec-agent, run the triage workflow on `runs-on: ubuntu-26.04` through `workflow_dispatch`. Use a temporary branch or a copy of the workflow, so the scheduled caller is untouched. Verify each stage:
   - the Copilot CLI installs and runs on Node 24
   - `envsubst` is present and the prompt expands
   - the k9 token mint and guidance fetch work (curl 8.18 / jq 1.8)
   - the deliverables check passes (`k9-triage-summary/v2`)
   - the job summary, artifact upload and Teams card work
   - `deps-command` / `test-command` pass, and a fix PR opens when one is warranted

   Link the run URL in CLOUD-4198.
4. **Act on canary findings.** If the Copilot CLI misbehaves on Node 24, add a hash-pinned `actions/setup-node` step in `action.yml` that pins Node 22 for the CLI install (a `fix:` release). Don't add it pre-emptively, because it's a new supply-chain dependency. Fix or document any other failure.
5. **Our callers.** Use the canary result to decide whether demo-k9-cloudsec-agent stays on `ubuntu-latest` or pins `ubuntu-24.04`. Record the decision in CLOUD-4198.
6. **Release.** Steps 1–2 change only CI and docs, so they need no action release. If step 4 changes `action.yml`, cut a `v1.x.y` patch and move `@v1`.

## Questions

### Q1. How should the canary run on `ubuntu-26.04` without disturbing demo-k9-cloudsec-agent's scheduled triage?

Context: demo-k9-cloudsec-agent's `dependency-triage.yml` hardcodes `runs-on: ubuntu-latest` and runs weekly (Tuesday 14:00 UTC; next run 2026-10-20, after the migration starts). A temporary branch that edits `runs-on` is the zero-footprint option, but the action checks out the dispatched ref. The agent would then build its `k9-triage/<package>` fix branches on top of the workflow edit, and `gh pr create` targets the default branch, so any fix PR would carry the `runs-on` change in its diff.

Question: Where should the 26.04 canary run come from?

Options:
  1. Temporary branch in demo-k9-cloudsec-agent with `runs-on: ubuntu-26.04`, dispatched via `gh workflow run --ref`. Any fix PRs it opens would include the workflow edit and need closing.
  2. Add a `workflow_dispatch` input to the existing workflow on `main`, e.g. `runner` (choice: `ubuntu-latest`, `ubuntu-24.04`, `ubuntu-26.04`), with `runs-on: ${{ inputs.runner || 'ubuntu-latest' }}` so scheduled runs are unchanged. It's a permanent, small change and can be reused for the next image migration.
  3. A separate `dependency-triage-canary.yml` on `main`, dispatch-only, pinned to `ubuntu-26.04`. It duplicates the caller config, which can drift.

Recommendation: Option 2. It avoids polluted fix PRs, leaves the scheduled run alone, and gives us a lever for the next migration.

Decision: TBD

### Q2. Are the canary's real side effects acceptable?

Context: A canary is a full production-like triage run against demo-k9-cloudsec-agent's 30 open Dependabot alerts. It posts a Teams card to the product-security channel (`TEAMS_WEBHOOK_URL`). It may open `k9-triage/<package>` fix PRs: #56 (pytest) and #57 (requests) are already open from earlier runs. It also bills the personal Copilot plan behind `COPILOT_GITHUB_TOKEN`, roughly in proportion to alert count. That is a second full run the same week as the 2026-10-20 scheduled run, and the README troubleshooting table already records quota exhaustion mid-run.

Question: Should the canary run with its normal side effects, or with some of them suppressed?

Options:
  1. Accept all side effects. One extra run on a demo repo, and the Teams card and PR behaviour are part of what we're verifying.
  2. Dispatch without the Teams webhook (the input is optional) to keep the channel quiet. This drops the Teams-card check from the canary.
  3. Make the canary stand in for this week's run by dispatching it on 2026-10-19 or 2026-10-20 instead of the scheduled job. That saves quota but means a temporary cron edit.

Recommendation: Option 1. Run it once this week (before 2026-10-19), and check the Copilot plan's remaining quota first, so a quota failure isn't misread as a 26.04 failure.

Decision: TBD

### Q3. If demo-k9-cloudsec-agent's own `deps-command` / `test-command` fail on Python 3.14 / Node 24, do we fix the demo repo or pin it to `ubuntu-24.04`?

Context: The demo's `deps-command` builds a Python venv (`make venv-dev`) and runs three `npm ci` installs; `test-command` is `make quick`. That is exactly the customer risk the README row describes. The demo is also our only in-house caller, so it's our early warning for the customer default.

Question: What should happen to demo-k9-cloudsec-agent's runner if the canary shows the demo's own toolchain breaking on 26.04?

Options:
  1. Fix forward in demo-k9-cloudsec-agent (e.g. add `actions/setup-python` / bump packages for 3.14) under a separate Jira issue, and keep `ubuntu-latest`.
  2. Pin `runs-on: ubuntu-24.04` permanently.
  3. Pin `ubuntu-24.04` as a stopgap now, and fix forward under a separate Jira issue, then unpin.

Recommendation: Option 3 if it breaks, so the weekly triage keeps opening PRs during the rollout. Stay on `ubuntu-latest` if the canary passes. Demo-repo fixes stay out of this task's scope.

Decision: TBD

### Q4. Should the README troubleshooting row ship in a docs-only `v1.0.2` release?

Context: Main is already 2 docs commits ahead of `v1.0.1` (`8d53e07`, `9a93da9`). The GitHub Marketplace listing shows the README from the latest release, so a README row merged to `main` doesn't reach Marketplace readers until the next release. Steps 1–2 don't touch `action.yml`, so moving `@v1` changes no runtime behaviour.

Question: After the CI matrix and README row land, should we cut `v1.0.2` and move `@v1`, or wait for the next code change?

Options:
  1. Cut `v1.0.2` (docs-only) right after steps 1–2, before 2026-10-19, so Marketplace readers see the migration row while the rollout is happening.
  2. Don't release. `main` README is enough, and the next code release picks it up.
  3. Release only if the canary forces an `action.yml` change (step 4).

Recommendation: Option 1. The row is only useful during the rollout window, and a docs-only release is cheap and safe.

Decision: TBD

## Detailed implementation steps

TODO: Make a detailed list of implementation steps to complete this task and replace this todo those steps.
