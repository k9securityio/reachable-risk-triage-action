
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

Coverage today (corrected 2026-10-14): the demo-k9-cloudsec-agent scheduled runs on 2026-10-06 and 2026-10-13 **failed**. The last success was 2026-09-29. CLOUD-4194 being Done doesn't mean its run passed. Both failures are a Copilot policy denial in the agent step, not a runner-image issue; see step 12. Neither image is currently covered end to end.

Out of scope: changing the action's scope guarantees; non-Ubuntu or self-hosted runners; arm64 runners (Copilot ships `linux-arm64`, but we don't test it); fixing demo-k9-cloudsec-agent's own toolchain.

> **Correction (2026-10-15):** claims in this doc that GitHub "paused" or "no longer sells" individual Copilot plans are outdated. Sign-ups for Pro, Pro+ and Student were paused from 2026-04-20 ([#192963](https://github.com/orgs/community/discussions/192963)), but GitHub began reopening Student, Pro, Pro+ and Max sign-ups gradually on 2026-06-16 ([#197089](https://github.com/orgs/community/discussions/197089)). #197089 doesn't say whether cancelled subscribers can resubscribe. The README was corrected before v1.0.2.

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

Deadline: Phases B and C finish before 2026-10-19, when the `ubuntu-latest` rollout starts. Phase A (action repo) and Phase B (demo repo) are independent and can run in parallel. Phase C waits for both, so `v1.0.2` ships any fix the 26.04 run turns up.

### Phase A — Action repo: support policy, caller guidance, CI matrix (one PR)

Deliverable: a merged PR where CI is green on `ubuntu-24.04` and `ubuntu-26.04`, and the README/example tell callers which images are supported and how to set up the triage job.

1. ✅ Work on branch `CLOUD-4198-ubuntu-26-runner-readiness` (already created from `main`; it carries this task doc's commits).
2. ✅ **README Prerequisites (support policy).** Add item 5: *"A GitHub-hosted Ubuntu runner. The action supports the Ubuntu images GitHub currently supports — today `ubuntu-24.04` and `ubuntu-26.04` (`ubuntu-latest` resolves to one of them) — and is tested on x64. Use the image your CI uses; see [Run triage like your CI](#run-triage-like-your-ci)."*
3. ✅ **README "mirror your CI job" guidance.** After the paragraph that starts "`deps-command` and `test-command` are your repository's own…", add a `### Run triage like your CI` subsection (anchor used by step 2). Content:
   - Give the triage job the same `runs-on` and toolchain setup steps (e.g. `actions/setup-python`, `actions/setup-node`) as the CI job that runs your tests. Then `test-command` passes in triage whenever it passes in CI.
   - When a runner image change breaks your toolchain, your CI breaks too, and the fix you make there carries over to triage.
   - Setup steps that cache (`cache: pip`, `cache: npm`) read lockfiles, so add an `actions/checkout` (with `persist-credentials: false`) before them. The action's own checkout re-checks out the same ref, which is harmless. Without caching, no caller checkout is needed.
4. ✅ **Example caller + README Quickstart YAML (kept identical).** The Quickstart embeds the same workflow as `examples/dependency-triage.yml`, so apply each edit to both:
   - On `runs-on: ubuntu-latest`, add the comment `# Use the same runner image as the CI job that runs your tests.`
   - Before the `uses: k9securityio/reachable-risk-triage-action@v1` step, add a commented block (Q5 → Option 1): a short comment ("Set up the same toolchain as your CI test job; check out first only if a setup step caches or reads repo files"), then a commented `actions/checkout` pinned to the SHA `action.yml` uses (`34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1`) with `persist-credentials: false`, then a commented `actions/setup-node` example hash-pinned to the current release (look up the v7.x tag's commit SHA with `gh api repos/actions/setup-node/git/ref/tags/<tag>`) with `node-version-file` and `cache: npm`. Real SHAs, so a caller who uncomments gets a pinned step that passes zizmor.
   - Check: `diff <(sed -n '/^name: dependency-alert-triage/,/test-command: "/p' examples/dependency-triage.yml) <(sed -n '/^```yaml/,/^```/p' README.md | sed '1d;$d')` shows no differences in the workflow body. The example's leading file comment is expected to differ.
5. ✅ **README Troubleshooting row** (generic). Symptom: "Fix PRs stopped opening, or `test-command` fails in triage but passes in CI". Cause and fix: "The triage job's runner image or toolchain setup differs from your CI job's, for example after GitHub moved `ubuntu-latest` to a new Ubuntu release. Read the failing test output in `agent-run.log`, then match `runs-on` and the setup steps to your CI job ([Run triage like your CI](#run-triage-like-your-ci))." Place it after the "Check deliverables exist" row.
6. ✅ **CI matrix.** In `.github/workflows/ci.yml` `lint-and-audit`: add `strategy: { fail-fast: false, matrix: { os: [ubuntu-24.04, ubuntu-26.04] } }` and `runs-on: ${{ matrix.os }}`. Add a comment that the matrix mirrors the support policy (README Prerequisites), and that `ubuntu-latest` isn't listed because it's an alias for one of these. Don't change the install steps.
7. ✅ **AGENTS.md updates** (Q6 → Option 1).
   - Under `## Versioning`, add: *"A release that changes `action.yml`, `scripts/` or `prompts/` needs a green end-to-end triage run on each supported image (`ubuntu-24.04`, `ubuntu-26.04`) before `@v1` moves: dispatch demo-k9-cloudsec-agent's `dependency-alert-triage` workflow with `runner: <image>` and put the run URLs in the release notes. Docs-only releases are exempt."*
   - Under Key design decisions, add: *"Supported runners follow GitHub's supported Ubuntu images (README Prerequisites; CI matrix in `ci.yml`). Callers run triage like their CI job. Don't add `actions/setup-node` or other toolchain setup to `action.yml`: it changes `PATH` for the caller's `deps-command`/`test-command`. Copilot CLI is a native binary and doesn't depend on the image's Node version."*
8. ✅ **Verify locally:** `make quick` passes (shellcheck + actionlint on the matrix workflow + zizmor over `action.yml`, `ci.yml` and the edited example). Run the step 4 diff check. Skim the rendered README anchors (`#run-triage-like-your-ci`) on the branch's GitHub page.
   - Done: `make quick` green and the diff check is identical. Deviation: no actionlint release (latest 1.7.12) knows the `ubuntu-26.04` label, so the Makefile has a narrow `-ignore 'label "ubuntu-26.04" is unknown'` with a comment, and AGENTS.md → Known false positives records it. The step 4 check now ends at `test-command: "`, because the new example comment also contains "test-command".
9. ✅ **Commits and PR.** Commit in two conventional commits: `ci: lint and audit on ubuntu-24.04 and ubuntu-26.04 - CLOUD-4198` (ci.yml) and `docs: runner support policy and run-triage-like-your-ci guidance - CLOUD-4198` (README, example, AGENTS.md). Push and open a PR.
10. ✅ **Verify deliverable:** PR checks show `lint-and-audit (ubuntu-24.04)` and `lint-and-audit (ubuntu-26.04)` both green (`gh pr checks --watch`). This also confirms the `ubuntu-26.04` label is available, and that apt `shellcheck`, the actionlint download and `pipx install zizmor` (Python 3.14) work there. Merge (squash or merge per repo habit), then delete the branch.
    - Both legs green on PR [#1](https://github.com/k9securityio/reachable-risk-triage-action/pull/1) (run 38616214209). Logs confirm images `ubuntu-24.04` and `ubuntu-26.04` and full shellcheck/actionlint/zizmor runs. Merged to `main` 2026-10-14 (rebase merge, keeping the conventional commits).

### Phase B — 26.04 test run in demo-k9-cloudsec-agent

Deliverable: a successful `dependency-alert-triage` run on `ubuntu-26.04`, linked in CLOUD-4198, with every stage checked off.

11. ✅ **Runner dispatch input (Q1 → Option 2).** In `../demo-k9-cloudsec-agent/.github/workflows/dependency-triage.yml`: give `workflow_dispatch` an input `runner` (`type: choice`, `options: [ubuntu-latest, ubuntu-24.04, ubuntu-26.04]`, `default: ubuntu-latest`, with a description noting it's for image test runs). Set `runs-on: ${{ inputs.runner || 'ubuntu-latest' }}`, with a comment that scheduled runs get no inputs, so they fall back to `ubuntu-latest`. Stage only that file; the demo repo has unrelated untracked files (`AGENTS.md`, `docs/reports/`). Commit to the demo's `main` in its style, `feat: runner dispatch input for runner-image test runs (CLOUD-4198)`, after running actionlint/zizmor on the file if available. Push.
    - Done: demo-k9-cloudsec-agent `17784c5` (pushed to `main`). actionlint clean. zizmor's one high finding is the existing `unpinned-uses` on `@v1` (the demo has never carried the example's ignore comment), not from this change.
12. ✅ **Pre-flight (Q2 → Option 1).** Check remaining quota on the Copilot plan behind the demo's `COPILOT_GITHUB_TOKEN` (the token owner's GitHub settings → Copilot usage). If it's too low for a full run over about 30 alerts, stop and decide with the user rather than risk a misleading quota failure. Confirm no triage run is in progress (`gh run list -R k9securityio/demo-k9-cloudsec-agent -w dependency-alert-triage -L 3`); the shared `concurrency` group would queue it anyway.
    - Done 2026-10-14: Copilot Business active on k9securityio; MCP, CLI, CLI-billed-to-org and model policies enabled by the user. Quota isn't a concern on the org plan for a single run.
    - Blocked 2026-10-14. The demo's last two scheduled runs (10-06 [37475578265](https://github.com/k9securityio/demo-k9-cloudsec-agent/actions/runs/37475578265), 10-13 [38410260053](https://github.com/k9securityio/demo-k9-cloudsec-agent/actions/runs/38410260053)) failed at the agent step after about 1.5 min with `Third-party MCP servers are disabled by your organization's Copilot policy` followed by `Error: Access denied by policy settings`. The Copilot plan behind `COPILOT_GITHUB_TOKEN` (the demo bills a user's plan) has the MCP-servers policy, and possibly the CLI policy, turned off since about 2026-10-01. A 26.04 dispatch would fail the same way, so it can't run until the token owner or the org admin re-enables the policies (https://github.com/settings/copilot, or the managing org's Copilot policies). The quota check also needs the token owner.
    - Root cause (2026-10-14): the personal Copilot plan behind `COPILOT_GITHUB_TOKEN` **ended** on 2026-10-06. The intended Pro+ → Pro downgrade (k9-business CLOUD-4075) ended the subscription instead, and GitHub has paused new individual-plan sign-ups, so it can't be bought back. The user bought **Copilot Business (1 seat, assigned to `skuenzli`) on k9securityio**. The demo now uses the action's default org-billed path (demo `dcb6a12`, which removes the `copilot-github-token` input). The `COPILOT_GITHUB_TOKEN` secret is kept so that path can be re-tested later. Remaining pre-flight: the user confirms the k9securityio Copilot policies (Copilot CLI billed to the organization, MCP servers allowed, Claude Sonnet 5 enabled).
    - Coverage gap, on record: with no individual Copilot plan available to us, the `copilot-github-token` path is untested. The action still supports it, and the README/`action.yml` wording now describes when it applies (existing individual Pro/Pro+ holders). The both-images release rule (step 7) covers the org-billed path only until someone can lend an individual-plan token.
    - This change also touches the `copilot-github-token` input description in `action.yml` (text only, no runtime change). The step 7 rule then asks for runs on both images before `@v1` moves, so Phase B dispatches `ubuntu-24.04` as well as `ubuntu-26.04`.
13. ✅ **Dispatch:** `gh workflow run dependency-alert-triage -R k9securityio/demo-k9-cloudsec-agent -f runner=ubuntu-26.04`, then `gh run watch` the run.
14. ✅ **Verify deliverable**, from the run log, job summary and artifact:
    - Verified on `ubuntu-26.04` (image 20261012.163.1) across runs [38636991959](https://github.com/k9securityio/demo-k9-cloudsec-agent/actions/runs/38636991959), [38637500302](https://github.com/k9securityio/demo-k9-cloudsec-agent/actions/runs/38637500302) and [38639343630](https://github.com/k9securityio/demo-k9-cloudsec-agent/actions/runs/38639343630) (cancelled): checkout; demo `deps-command` on Python 3.14 / Node 24 (43 s); k9 token mint; guidance fetch of all 3 resources (curl 8.18 / jq 1.8); Copilot CLI 1.0.80 install; `envsubst` present (no `command not found`; the prompt reached the agent); model `claude-sonnet-5` accepted after policy propagation; artifact upload; Teams card (HTTP 202).
    - Not verified: the triage itself (deliverables check, fix PRs). It's blocked by the k9 MCP server being `blocked by policy` on the org-billed path (CLOUD-4199). The 24.04 dispatch is also deferred to CLOUD-4199, since it would hit the same block.
    - the job ran on Ubuntu 26.04 (the "Set up job" log shows the image `ubuntu-26.04` and its version)
    - "Install Copilot CLI" succeeded, and the agent step ran
    - `envsubst` resolved: the agent log shows the expanded repo name and run URL in the prompt, not literal `$GITHUB_REPOSITORY`
    - token mint and guidance fetch succeeded (curl 8.18 / jq 1.8)
    - "Check deliverables exist" passed (`k9-triage-summary/v2`)
    - the job summary has the report; the artifact has the report, summary JSON and `agent-run.log`
    - a Teams card arrived
    - `deps-command` passed, and `test-command` (`make quick`) passed on any fix branch, or fix PRs opened / existing #56, #57 were left alone without errors
    - Completed under CLOUD-4199 on rr-triage-fixture with the final `action.yml`: ubuntu-24.04 https://github.com/k9securityio/rr-triage-fixture/actions/runs/38659441800 and ubuntu-26.04 https://github.com/k9securityio/rr-triage-fixture/actions/runs/38660421501, both full end-to-end runs (0 denied commands, fix PRs after passing tests, Teams OK).
15. ✅ **Handle failures.**
    - Split out as **CLOUD-4199**: on the org-billed path, Copilot CLI 1.0.80 reports `1 MCP server was blocked by policy: 'k9'`, so the agent can't reach the k9 MCP server. This is an auth/policy issue, not a runner image issue (likely a policy-fetch race or failure with a fresh `COPILOT_HOME`; copilot-cli #2567/#4378/#4957). The demo's toolchain didn't break on 26.04, so the Q3 stopgap pin isn't needed.
    - In the action's code: create a fix on a new branch in this repo, release it as a `fix:` in Phase C, and re-dispatch on both images (Q6 rule).
    - In the demo's own toolchain (Q3 → Option 1): pin the demo's `runs-on` default to `ubuntu-24.04` as a stopgap, create a separate CLOUD Jira issue to fix the demo's toolchain on 26.04 and unpin, and record it here.
16. ✅ **Record:** comment on CLOUD-4198 with the run URL and stage results, and note the demo stays on `ubuntu-latest` (or the stopgap pin plus the follow-on issue key).
    - Comment added to CLOUD-4198 (2026-10-14) with run URLs and stage results. Demo stays on `ubuntu-latest`; its toolchain works on 26.04 (Q3 → Option 1: no stopgap pin needed).

### Phase C — Release `v1.0.2` (Q4 → Option 1)

Deliverable: `v1.0.2` published with `@v1` moved to it, before 2026-10-19.

17. ✅ **Pre-checks:** `main` is green on both matrix legs. Phase B passed. If Phase B produced an `action.yml`/`scripts/`/`prompts/` fix, the Q6 rule applies: both-image runs pass and their URLs go in the notes. Otherwise the release is docs/CI-only and exempt.
    - 2026-10-14: `main` is green on both legs once PR #1 merges. The release is held by the user: don't tag `v1.0.2` yet. When it ships, the notes must say the full triage run on 26.04 waits on CLOUD-4199, list what was verified (step 14), and note that the `action.yml` change is description text only.
18. ✅ **Tag and release.** `git tag v1.0.2 <main sha> && git push origin v1.0.2`. Then `gh release create v1.0.2 --title v1.0.2 --notes-file <notes>`, with notes in the v1.0.1 format:
    - `## Docs`: runner support policy; "Run triage like your CI"; the troubleshooting row; the earlier unreleased README onboarding commits (`8d53e07`, `9a93da9`)
    - `## CI`: the 24.04/26.04 matrix
    - the 26.04 verification run URL
    - the `Pin:` line with the full SHA
    - Shipped as `v1.0.2` together with CLOUD-4199 (CLOUD-4199 Q6): https://github.com/k9securityio/reachable-risk-triage-action/releases/tag/v1.0.2. `v1` → `d40f4e0`.
19. ✅ **Move the major tag** (confirm with the user first, since it changes the version every `@v1` caller resolves): `git tag -f v1 v1.0.2 && git push -f origin v1`.
20. ✅ **Verify deliverable:** `git ls-remote --tags origin v1 v1.0.2` shows both tags on the same commit, and `gh release view v1.0.2` shows the notes. Check the Marketplace listing shows the new README section; this check is manual.

### Phase D — Close out

21. ✅ Update CLOUD-4198 with the PR link, release link, 26.04 run URL and any follow-on issue. Then run `/task-resolve CLOUD-4198-ubuntu-26-runner-readiness`.
22. After 2026-11-19 (optional reminder): confirm the demo's scheduled runs on the migrated `ubuntu-latest` are still green. That's ongoing 26.04 coverage, and a dispatch with `runner: ubuntu-24.04` covers 24.04 from then on.
