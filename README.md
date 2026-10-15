# Reachable Risk Triage Action

Most of your Dependabot queue cannot reach your code, and the few alerts that can are buried
in it. This action triages every open alert on a schedule you choose: an AI agent runs inside
your GitHub Actions job, scores each alert with the k9 Security
[Reachable Risk](https://www.k9security.io/lp/reachable-risk/) rubric, publishes a full triage
report, opens a tested fix PR for each finding worth fixing, and optionally posts the outcome to
Microsoft Teams. The agent analyzes, the action orchestrates, and engineers decide using
evidence: nothing merges or dismisses without you.

The k9 MCP server stays the source of truth for the triage procedure. Every run fetches the
current workflow guidance and risk rubric from the server, so scoring improvements reach you
without an action upgrade.

## Quickstart

1. Check the [prerequisites](#prerequisites) and create the [secrets](#secrets).
2. Add the workflow below as `.github/workflows/dependency-triage.yml` in your repository
   (it is also available as [`examples/dependency-triage.yml`](examples/dependency-triage.yml)).
3. Run it once by hand (Actions → dependency-alert-triage → Run workflow), then verify:
   - the job summary shows the triage report with a verdict for every open alert;
   - the `dependency-triage-report` artifact contains the report, the summary JSON, and the
     agent log;
   - your Teams channel received a card, if you configured the webhook.

   Zero open alerts is a normal clean run, and the report says so.

```yaml
name: dependency-alert-triage

on:
  schedule:
    - cron: "0 14 * * 2" # weekly, Tuesday 14:00 UTC
  workflow_dispatch:

# Fix branches and PRs are pushed with the GH_TRIAGE_TOKEN PAT, not the
# Actions token, so no write permission is needed here.
permissions:
  contents: read # checkout of this repo (manifests, .k9security/risk-context.yaml)
  copilot-requests: write # authenticates Copilot CLI via the Actions token

# Never let two triage runs overlap (a manual dispatch during the cron run
# would double-score and double-file); queue instead of cancel so a running
# triage always finishes and reports.
concurrency:
  group: dependency-alert-triage
  cancel-in-progress: false

jobs:
  triage:
    runs-on: ubuntu-latest # Use the same runner image as the CI job that runs your tests.
    timeout-minutes: 120
    steps:
      # Set up the same toolchain as the CI job that runs your tests, so
      # test-command behaves as it does in CI. Check out first only if a
      # setup step caches dependencies or reads repo files; the action's own
      # checkout then checks out the same ref again, which is harmless.
      # - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
      #   with:
      #     persist-credentials: false
      # - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0
      #   with:
      #     node-version-file: .nvmrc
      #     cache: npm

      # The floating v1 major tag is the recommended default: fixes reach
      # every caller without per-repo edits. Policy-restricted orgs can pin
      # to a release SHA instead — see the README's versioning section.
      - uses: k9securityio/reachable-risk-triage-action@v1 # zizmor: ignore[unpinned-uses]
        with:
          k9-client-id: ${{ secrets.K9_CLIENT_ID }}
          k9-client-secret: ${{ secrets.K9_CLIENT_SECRET }}
          github-token: ${{ secrets.GH_TRIAGE_TOKEN }}
          teams-webhook-url: ${{ secrets.TEAMS_WEBHOOK_URL }}
          agent: copilot
          model: claude-sonnet-5
          # deps-command (required) installs your dependencies before the
          # agent analyzes the repo: installed dependency trees are essential
          # for accurate reachability analysis. test-command gates fix PRs —
          # a PR opens only when it passes on the bumped branch; leave it
          # unset to get reports without fix PRs.
          deps-command: "npm ci"
          test-command: "npm test"
```

GitHub does not let a composite action declare `permissions`, `concurrency`, or
`timeout-minutes`, so those blocks stay in your workflow.

`deps-command` and `test-command` are your repository's own install and test commands.
`deps-command` is required and runs before the agent analyzes the repo: reachability analysis
inspects the installed dependency trees (site-packages, node_modules), not just the manifests.
Fix PRs are opened only when the test command passes on the bumped branch; leave `test-command`
unset to get triage reports without fix PRs.

### Run triage like your CI

Give the triage job the same `runs-on` and the same toolchain setup steps (for example
`actions/setup-python` or `actions/setup-node`) as the CI job that runs your tests. Then
`test-command` passes in triage whenever it passes in CI, and you don't change your build for
the action. When a runner image change breaks your toolchain, your CI breaks too, and the fix
you make there carries over to triage.

Setup steps that cache dependencies (`cache: pip`, `cache: npm`) read your lockfiles, so add an
`actions/checkout` step (with `persist-credentials: false`) before them. The action's own
checkout then checks out the same ref again, which is harmless. Without caching, you don't need
a checkout of your own. The example workflow shows where these steps go.

Optional: commit a `.k9security/risk-context.yaml` describing your execution contexts (which
paths run where, network exposure, data sensitivity). The agent binds each alert to the
matching contexts when scoring; without the file, the agent scores without repository-specific
context.

## Prerequisites

1. **GitHub Copilot.** One of:
   - **A Copilot Business or Enterprise plan on the organization that owns the repository**
     (recommended). The action authenticates the Copilot CLI with the built-in Actions token plus
     the `copilot-requests: write` permission (declared in the example workflow). Usage is billed
     to the organization, not to any seat holder. In Organization Settings → Copilot → Policies,
     confirm "Allow use of Copilot CLI billed to the organization" is enabled (it is on by
     default), and that MCP servers are allowed: the agent calls the k9 MCP server.
   - **An individual Copilot Pro, Pro+ or Max plan**, used through the
     [`COPILOT_GITHUB_TOKEN`](#secrets) secret. Usage is billed to that user's plan.
2. **A k9 Security account** with the
   [Reachable Risk](https://www.k9security.io/lp/reachable-risk/) plan (`score_risk` access). Free to start, no credit card required.
3. **Dependabot alerts enabled** on the repository.
4. Optional: **a Microsoft Teams channel** where run outcomes should be announced.
5. **A GitHub-hosted Ubuntu runner.** The action supports the Ubuntu images GitHub currently
   supports — today `ubuntu-24.04` and `ubuntu-26.04` (`ubuntu-latest` resolves to one of them) —
   and is tested on x64. Use the image your CI uses; see
   [Run triage like your CI](#run-triage-like-your-ci).

## Secrets

Repository (or organization) Actions secrets:

| Secret | Value |
| --- | --- |
| `K9_CLIENT_ID` / `K9_CLIENT_SECRET` | A k9 Service Client (M2M): in the k9 app, My Account → Service Clients (M2M) → Create, then copy the id and secret (the secret is shown once). The action mints a fresh short-lived token from these on every run; there is nothing to rotate on a schedule and no token that expires in a drawer. |
| `GH_TRIAGE_TOKEN` | A fine-grained PAT (organization-owned is fine) with repository permissions `Dependabot alerts: read`, `Contents: write`, and `Pull requests: write` on the repository. Used only by `gh` to read alerts, push fix branches, and open fix PRs. It needs no Copilot permission. The Actions-issued `GITHUB_TOKEN` cannot read Dependabot alerts, which is why a PAT is required. |
| `TEAMS_WEBHOOK_URL` (optional) | See [Create the Teams webhook](#create-the-teams-webhook). When unset, the run reports to the job summary and artifact only. |
| `COPILOT_GITHUB_TOKEN` (optional) | For organizations without a Copilot Business or Enterprise plan: a classic token of a user who holds an individual Copilot Pro, Pro+ or Max plan, passed via the `copilot-github-token` input. When set, it overrides the org-billed path and bills that user's plan. The org-billed path is recommended: usage is billed to the organization rather than to one person's plan. Do not use an org-owned fine-grained PAT: it cannot carry the account-level Copilot Requests permission ([github/copilot-cli#223](https://github.com/github/copilot-cli/issues/223)). |

## Inputs

| Input | Required | Default | Purpose |
| --- | --- | --- | --- |
| `k9-client-id` | yes | — | k9 Service Client (M2M) id |
| `k9-client-secret` | yes | — | k9 Service Client (M2M) secret |
| `github-token` | yes | — | Fine-grained PAT for `gh` (see Secrets) |
| `agent` | yes | — | Agent CLI. v1 supports `copilot`; other values fail fast |
| `model` | yes | — | Model the agent CLI uses (e.g. `claude-sonnet-5`) |
| `deps-command` | yes | — | Repo's dependency-install command; runs before analysis (reachability needs installed deps) and again on fix branches |
| `test-command` | no | `""` | Repo's test command; when unset, the run reports only and opens no fix PRs |
| `teams-webhook-url` | no | `""` | Teams Workflows webhook; when unset, no Teams notification |
| `copilot-github-token` | no | Actions token | Copilot auth override (see Secrets) |
| `k9-mcp-url` | no | `https://mcp.k9security.io/mcp` | k9 MCP server URL |
| `k9-auth-domain` | no | `auth.k9security.io` | k9 OAuth token domain |
| `k9-audience` | no | `https://mcp.k9security.io/` | OAuth audience for the k9 MCP server |

## Create the Teams webhook

Microsoft retired classic "Incoming Webhook" connectors in May 2026; the supported replacement
is a Workflows (Power Automate) webhook:

1. In Teams, open the target channel → ⋯ → **Workflows** (installs the Workflows app if needed).
2. Create the flow from the template **"Post to a channel when a webhook request is received"**
   and point it at the channel.
3. Copy the HTTP POST URL it displays and store it as the `TEAMS_WEBHOOK_URL` secret.

The card shows alert and verdict counts and a button to the run page. A run that fails to
produce a report posts an explicit failure card: silence is never success.

## Where results land

- **Full report**: on the workflow run page, rendered inline in the job summary and attached
  as the `dependency-triage-report` artifact (the Teams card's button opens this page). Run
  pages require GitHub login with repository access, and artifacts expire with your
  run-retention setting (default 90 days). The durable longitudinal record is k9's
  scored-findings corpus, which every run feeds automatically.
- **Fix PRs**: one per package with actionable findings (FIX_TODAY, or SCHEDULE past its
  fix-release cooldown), labeled `dependency-triage`, opened only after your test command passes
  on the bumped branch; a failing test run lands in the report instead of a PR. When an open
  Dependabot PR already covers the fix, the report marks it ready-to-merge rather than
  duplicating it. REVIEW findings are reported but never acted on: a REVIEW means the evidence
  supports no recommendation yet, so the decision stays with you. Nothing is ever merged or
  dismissed by the action.
- **Counts on the Teams card**: "Alerts scored" counts alerts; FIX_TODAY/REVIEW/SCHEDULE/DEFER
  count *verdicts*, one per execution context an alert's code runs in, so verdicts
  legitimately sum higher than alerts on any project with more than one execution context. The
  two numbers are not a discrepancy.

## Versioning and pinning

- `@v1`: floating major tag, moved on every release in the v1 line. Recommended: fixes and
  improvements reach your workflow without edits. Breaking changes get a new major (`@v2`).
- `@v1.x.y`: immutable release tags, for orgs that bump deliberately.
- `@<full-sha> # vX.Y.Z`: for organizations whose policy (or [zizmor](https://docs.zizmor.sh/)
  `unpinned-uses` audit) requires hash pinning. Take the SHA from the
  [releases page](../../releases).

The action's own dependencies are hash-pinned and zizmor-audited in CI on every change.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Agent step fails immediately: `Authentication failed … ensure it has the 'Copilot Requests' permission` | A fine-grained PAT is being used for Copilot auth. Organization-owned fine-grained PATs cannot carry the account-level Copilot Requests permission (github/copilot-cli#223). Use the default org-billed path (no Copilot secret at all), or a *classic* token in `copilot-github-token`. |
| Agent step fails immediately: `Access denied by policy settings` | The organization's Copilot CLI policy is disabled or the organization has no configured Copilot plan. Enable "Allow use of Copilot CLI billed to the organization", or use the `copilot-github-token` override. On the `copilot-github-token` path, the token owner's individual plan may have ended: check their Copilot settings page. |
| Agent log shows `1 MCP server was blocked by policy: 'k9'`, and the agent never calls k9 tools | Copilot CLI couldn't fetch the organization's MCP registry policy (HTTP 403 for the Actions token on the org-billed path), so it blocked every non-default MCP server. Copilot CLI 1.0.98 resolves this, and the action pins it from v1.0.2. On an older pinned release, move to `@v1` or a newer release. If it persists, confirm MCP servers are allowed in Organization Settings → Copilot → Policies and that no MCP registry allowlist excludes the k9 server. |
| Job summary shows "Denied agent commands" (warning: `Copilot CLI denied N agent command(s)`) | Copilot CLI refused some shell commands the agent tried, so the agent worked around them, e.g. by running a different test invocation or doing coarser reachability analysis. The action runs the CLI with `--allow-all-tools --allow-all-paths` so your `deps-command` and `test-command` run as written. Denials usually mean an organization Copilot policy restricts permissions, or a command reached for a URL (URLs stay restricted on purpose). Review the listed commands before trusting reachability or test results for that run. |
| Agent log shows `Third-party MCP servers are disabled by your organization's Copilot policy` | The Copilot plan billing the run doesn't allow MCP servers, so the agent can't reach the k9 MCP server. Allow MCP servers in Organization Settings → Copilot → Policies. On the `copilot-github-token` path, the same message appears when the token owner's plan has ended. |
| Run fails at "Check deliverables exist" | The agent ran but produced no report. Read `agent-run.log` in the run artifact: the failure evidence is there. The Teams card for a failed run says so explicitly. |
| Fix PRs stopped opening, or `test-command` fails in triage but passes in CI | The triage job's runner image or toolchain setup differs from your CI job's, for example after GitHub moved `ubuntu-latest` to a new Ubuntu release. Read the failing test output in `agent-run.log`, then match `runs-on` and the setup steps to your CI job ([Run triage like your CI](#run-triage-like-your-ci)). |
| Alert fetch fails / zero alerts unexpectedly | `GH_TRIAGE_TOKEN` is missing `Dependabot alerts: read` on the repository, or Dependabot alerts are disabled. A genuine zero-alert state is reported as a normal clean run, not an error. |
| Agent stops mid-run: `You have exceeded your monthly quota` | The Copilot plan billing the run is out of monthly credits. On the `copilot-github-token` path this is that user's personal allowance; each triage run consumes credits in proportion to alert count. Wait for the monthly reset, use a different Copilot-licensed user's token, or prefer the org-billed default path. The run fails loudly: the missing report fails the deliverables check and Teams gets a failure card. |
| actionlint/zizmor flag `copilot-requests` as an unknown permission | False positive: the permission is real but newer than the linters' permission lists (zizmor ≤1.29, actionlint ≤1.7.10). Do not remove the permission. |

## Roadmap

The `agent` input exists so that we can build support for triaging with Claude Code or Opencode. The
prompt, guidance fetch, report publishing, and notifications are agent-neutral. v1 ships the
Copilot CLI path.

## License

Apache-2.0. See [LICENSE](LICENSE).
