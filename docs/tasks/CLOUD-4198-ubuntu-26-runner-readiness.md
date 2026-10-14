
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

TODO: Ask clarifying questions for this task and replace this todo with those questions.

## Detailed implementation steps

TODO: Make a detailed list of implementation steps to complete this task and replace this todo those steps.
