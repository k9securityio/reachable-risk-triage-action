
# Task CLOUD-4198 - Test reachable-risk-triage-action on Ubuntu 26.04 runner before ubuntu-latest migration

The objective of this task is to make the action officially support both GitHub-hosted Ubuntu images that callers can choose, `ubuntu-24.04` and `ubuntu-26.04`, and to verify it on both before `ubuntu-latest` moves to 26.04. GitHub rolls the migration out from 2026-10-19 to 2026-11-19 ([actions/runner-images#14748](https://github.com/actions/runner-images/issues/14748)). Each repo moves once. `ubuntu-24.04` stays supported for about 2 years.

An action can't choose its runner. `runs-on` belongs to the caller's job, and the action runs on whatever image that job uses. Callers will choose the image their own CI uses, and some will pin `ubuntu-24.04` because their toolchain needs it. So the action has to work on every Ubuntu image GitHub supports. Support policy: **the action supports the GitHub-hosted Ubuntu images GitHub currently supports (today `ubuntu-24.04` and `ubuntu-26.04`, which is what `ubuntu-latest` resolves to).** The policy follows GitHub's support window, so we keep no image list of our own.

The biggest variable is the caller's code, not ours. `deps-command` / `test-command` run on whatever Python and Node the job provides, and fix PRs open only when `test-command` passes. Callers won't rewrite their build for this action, and they shouldn't have to. The guidance is: **run the triage job like the CI job that already runs your tests: same `runs-on`, same toolchain setup steps.** Then `test-command` passes in triage whenever it passes in CI. An image migration that breaks the caller's toolchain breaks their CI first, and the fix they make there carries over to triage.

The action's own exposure to image differences is small:

| Tool | 24.04 | 26.04 | Used by | Exposure |
| --- | --- | --- | --- | --- |
| Node / npm (default) | 22.23 / 10.9 | 24.21 / 11.19 | `npm install -g @github/copilot@1.0.80` | Low. Copilot CLI 1.0.80 declares no Node `engines` and runs as a native binary (`@github/copilot-linux-x64`); Node only runs the `npm-loader.js` entry point. |
| Python | 3.12 | 3.14 | `pipx install zizmor` (CI only) | Callers' `deps-command` / `test-command`: their job setup, per the guidance above. |
| jq | 1.7 | 1.8.1 | token mint, deliverables check, `notify-teams.sh` | Low. Basic filters only. |
| ShellCheck | 0.9.0 | 0.11.0 | CI release gate | `make run-shellcheck` is clean locally on 0.11.0. |
| curl / bash | 8.5 / 5.2 | 8.18 / 5.3 | everywhere | Low. |
| gh / git | 2.101 / 2.55 | unchanged | `gh auth setup-git` | None. |
| envsubst (gettext-base) | not listed in either image readme | to confirm | prompt expansion | Confirm on 26.04. |

No `actions/setup-node` pin in `action.yml`. Copilot's native binary makes it unnecessary. It would also be harmful: `setup-node` changes `PATH` for the rest of the job, so the caller's `deps-command` / `test-command` would run on our Node instead of the Node from their own setup, which breaks the "mirror your CI job" guidance.

Coverage today: the scheduled demo-k9-cloudsec-agent run on `ubuntu-latest` (currently 24.04) succeeded on 2026-10-13 (CLOUD-4194). That covers 24.04 until the repo is migrated. 26.04 is untested.

Out of scope: changing the action's scope guarantees; non-Ubuntu or self-hosted runners; arm64 runners (Copilot ships `linux-arm64`, but we don't test it); fixing demo-k9-cloudsec-agent's own toolchain.

## High-level implementation steps

1. **README: runner support policy.** In Prerequisites, state the support policy above, and that the action is tested on x64 GitHub-hosted Ubuntu runners.
2. **README + example: "mirror your CI job" guidance.** Next to `deps-command` / `test-command`: "Use the same `runs-on` and toolchain setup steps (e.g. `actions/setup-python`, `actions/setup-node`) as the CI job that runs your tests." In `examples/dependency-triage.yml`, add a commented slot for those setup steps before the action, shaped by Q5. Keep `runs-on: ubuntu-latest` with a comment pointing to the guidance.
3. **README troubleshooting row (generic, not 26.04-specific).** Symptom: "Fix PRs stopped opening, or `test-command` fails in triage but passes in CI". Cause and fix: "The triage job's runner image or toolchain setup differs from your CI job's, for example after GitHub moved `ubuntu-latest` to a new Ubuntu release. Match `runs-on` and the setup steps to your CI job." Point readers to `agent-run.log` for the failing test output.
4. **CI matrix.** In `.github/workflows/ci.yml`, run `lint-and-audit` on `runs-on: ${{ matrix.os }}` with `os: [ubuntu-24.04, ubuntu-26.04]` and `fail-fast: false`. Confirm the apt `shellcheck` install, the actionlint download and `pipx install zizmor` work on both, and that `make quick` (zizmor/actionlint) stays clean on the edited workflow. `main` has no branch protection, so the renamed check needs no settings change.
5. **demo-k9-cloudsec-agent: runner dispatch input (Q1 → Option 2).** Add a `workflow_dispatch` `runner` choice input (`ubuntu-latest`, `ubuntu-24.04`, `ubuntu-26.04`) and `runs-on: ${{ inputs.runner || 'ubuntu-latest' }}`. Scheduled runs are unchanged. This is a change in the demo repo, committed there.
6. **Canary run on `ubuntu-26.04`.** Dispatch the demo triage with `runner: ubuntu-26.04`, after checking the Copilot plan's remaining quota. Verify each stage:
   - the Copilot CLI installs and runs
   - `envsubst` is present and the prompt expands
   - the k9 token mint and guidance fetch work (curl 8.18 / jq 1.8)
   - the deliverables check passes (`k9-triage-summary/v2`)
   - the job summary, artifact upload and Teams card work
   - `deps-command` / `test-command` pass, and a fix PR opens when one is warranted

   Link the run URL in CLOUD-4198. If a failure is in the action's code, fix it and release a `fix:` patch. If it's in the demo repo's toolchain, handle it per Q3.
7. **Per-release image check (Q6).** Record in `AGENTS.md` (Versioning) that a release changing `action.yml`, `scripts/` or `prompts/` gets a demo triage run on each supported image before `@v1` moves.
8. **Release (Q4).**

## Questions

### Q1. How should the canary run on `ubuntu-26.04` without disturbing demo-k9-cloudsec-agent's scheduled triage?

Context: demo-k9-cloudsec-agent's `dependency-triage.yml` hardcodes `runs-on: ubuntu-latest` and runs weekly (Tuesday 14:00 UTC; next run 2026-10-20, after the migration starts). A temporary branch that edits `runs-on` is the zero-footprint option, but the action checks out the dispatched ref. The agent would then build its `k9-triage/<package>` fix branches on top of the workflow edit, and `gh pr create` targets the default branch, so any fix PR would carry the `runs-on` change in its diff.

Question: Where should the 26.04 canary run come from?

Options:
  1. Temporary branch in demo-k9-cloudsec-agent with `runs-on: ubuntu-26.04`, dispatched via `gh workflow run --ref`. Any fix PRs it opens would include the workflow edit and need closing.
  2. Add a `workflow_dispatch` input to the existing workflow on `main`, e.g. `runner` (choice: `ubuntu-latest`, `ubuntu-24.04`, `ubuntu-26.04`), with `runs-on: ${{ inputs.runner || 'ubuntu-latest' }}` so scheduled runs are unchanged. It's a permanent, small change and can be reused for the next image migration.
  3. A separate `dependency-triage-canary.yml` on `main`, dispatch-only, pinned to `ubuntu-26.04`. It duplicates the caller config, which can drift.

Recommendation: Option 2. It avoids polluted fix PRs, leaves the scheduled run alone, and gives us a lever for the next migration.

Decision: Recommendation accepted, Option 2.

### Q2. Are the canary's real side effects acceptable?

Context: The canary is a full production-like triage run against demo-k9-cloudsec-agent's 30 open Dependabot alerts. It posts a Teams card to the product-security channel (`TEAMS_WEBHOOK_URL`). It may open `k9-triage/<package>` fix PRs: #56 (pytest) and #57 (requests) are already open from earlier runs. It also bills the personal Copilot plan behind `COPILOT_GITHUB_TOKEN`, roughly in proportion to alert count. Only a 26.04 run is needed now, because the scheduled run already covers 24.04. That makes one extra full run this week, on top of the 2026-10-20 scheduled run. The README troubleshooting table already records quota exhaustion mid-run.

Question: Should the canary run with its normal side effects, or with some of them suppressed?

Options:
  1. Accept all side effects. One extra run on a demo repo, and the Teams card and PR behaviour are part of what we're verifying.
  2. Dispatch without the Teams webhook (the input is optional) to keep the channel quiet. This drops the Teams-card check from the canary.
  3. Make the canary stand in for this week's run by dispatching it on 2026-10-19 or 2026-10-20 instead of the scheduled job. That saves quota but means a temporary cron edit.

Recommendation: Option 1. Run it once before 2026-10-19, and check the Copilot plan's remaining quota first, so a quota failure isn't misread as a 26.04 failure.

Decision: Recommendation accepted, Option 1.

### Q3. Which runner should demo-k9-cloudsec-agent's scheduled triage use, given it has no CI job to mirror?

Context: demo-k9-cloudsec-agent's only workflow is `dependency-triage.yml`. It has no CI workflow, so the "mirror your CI job" guidance has nothing to point at. Its `deps-command` builds a Python venv (`make venv-dev`) plus three `npm ci` installs, and `test-command` is `make quick`. If its toolchain breaks on Python 3.14 / Node 24, the scheduled triage stops opening fix PRs. The demo is also our showcase caller, and the example uses `ubuntu-latest`.

Question: What should the demo's scheduled run use, and what happens if the canary shows the demo's toolchain breaking on 26.04?

Options:
  1. Stay on `ubuntu-latest`. If the toolchain breaks on 26.04, pin `ubuntu-24.04` as a stopgap and fix the demo's toolchain under a separate Jira issue, then unpin.
  2. Pin `ubuntu-24.04` now, matching the image the demo's `make quick` has been passing on, and move to 26.04 deliberately later.
  3. Stay on `ubuntu-latest`, and fix forward immediately if it breaks, with no pin.

Recommendation: Option 1. The demo keeps exercising the same default as the example caller, and a stopgap pin keeps weekly triage working while the demo's toolchain is fixed outside this task.

Decision: Recommendation accepted, Option 1.

### Q4. Should the README and example changes ship in a docs-only `v1.0.2` release?

Context: Main is already 2 docs commits ahead of `v1.0.1` (`8d53e07`, `9a93da9`). The GitHub Marketplace listing shows the README from the latest release, so the support policy, the "mirror your CI job" guidance and the troubleshooting row don't reach Marketplace readers until the next release. Without a Node pin, this task changes no `action.yml` behaviour unless the canary finds a bug, so moving `@v1` is safe.

Question: After steps 1–4 land, should we cut `v1.0.2` and move `@v1`, or wait for the next code change?

Options:
  1. Cut `v1.0.2` (docs-only) right after steps 1–4, before 2026-10-19, so Marketplace readers get the guidance while the rollout is happening.
  2. Don't release. `main` README is enough, and the next code release picks it up.
  3. Release only if the canary forces a code change.

Recommendation: Option 1. The guidance matters most during the rollout window, and a docs-only release is cheap and safe.

Decision: Recommendation accepted, Option 1.

### Q5. How should the example show callers where their CI setup steps go, given that setup actions with caching need the repository checked out first?

Context: The action checks out the repository itself (`actions/checkout`, `persist-credentials: false`) after the caller's steps run. Callers copying setup steps from CI often use caching (`actions/setup-python` with `cache: pip`, `actions/setup-node` with `cache: npm`). Those steps read lockfiles, so they fail unless the repository is already checked out. A caller `actions/checkout` before the setup steps works: the action's own checkout then re-checks out the same ref, which is harmless. It also requires no `action.yml` change.

Question: What should `examples/dependency-triage.yml` and the README tell callers about checkout and setup steps?

Options:
  1. Example shows a commented block: optional `actions/checkout` (`persist-credentials: false`), then "your CI's setup steps", then the action. The README says a checkout is only needed when the setup steps use caching or read repo files.
  2. Add an action input (e.g. `checkout: false`) so callers who check out themselves can skip the action's checkout. This adds input surface and a code path to test on both images.
  3. Tell callers to drop `cache:` from copied setup steps. That's simpler but diverges from their CI and slows runs.

Recommendation: Option 1. It costs nothing in `action.yml`, keeps the copied steps identical to the caller's CI, and the double checkout is harmless. The example's caller checkout also uses `persist-credentials: false`, so zizmor stays clean.

Decision: Recommendation accepted, Option 1.

### Q6. Should supporting two images add a per-release test requirement?

Context: The CI matrix (step 4) only lints. Only a real triage run tests the runtime path (Copilot install, MCP calls, jq/envsubst, notifications). Supporting both images means a change to `action.yml`, `scripts/` or `prompts/` could break on one image but not the other. With the Q1 dispatch input, a run per image is one `gh workflow run` command each.

Question: Should a release that changes runtime files require a demo triage run on each supported image before `@v1` moves?

Options:
  1. Yes. Record it in `AGENTS.md` → Versioning: changes to `action.yml`, `scripts/` or `prompts/` need a green demo run on `ubuntu-24.04` and `ubuntu-26.04` (run URLs in the release notes) before moving `@v1`. Docs-only releases are exempt.
  2. Run only on `ubuntu-latest` per release, and rely on the low tool exposure for the other image.
  3. No formal requirement. Test ad hoc.

Recommendation: Option 1. It's the concrete cost of the two-image support policy: two dispatches per runtime release, each billed to the Copilot quota.

Decision: Recommendation accepted, Option 1.

## Detailed implementation steps

TODO: Make a detailed list of implementation steps to complete this task and replace this todo those steps.
