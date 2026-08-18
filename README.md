# Reachable Risk Triage Action

Triage your repository's Dependabot alerts on a schedule you choose, prioritized by what is
actually reachable and exploitable in your code. An AI agent runs inside your GitHub Actions job
and scores every open alert with the k9 Security
[Reachable Risk](https://www.k9security.io/lp/reachable-risk/) rubric,
publishes a full triage report, opens a tested fix PR for each finding worth fixing, and posts
the outcome to Microsoft Teams. The agent analyzes, the action orchestrates, and engineers
decide using evidence: nothing merges or dismisses without you.

The k9 MCP server stays the source of truth for the triage procedure. Every run fetches the
current workflow guidance and risk rubric from the server, so scoring improvements reach you
without an action upgrade.

## Quickstart

1. Check the [prerequisites](#prerequisites) and create the [secrets](#secrets).
2. Copy [`examples/dependency-triage.yml`](examples/dependency-triage.yml) to
   `.github/workflows/dependency-triage.yml` in your repository.
3. Run it once by hand (Actions → dependency-alert-triage → Run workflow) and read the job
   summary.

The caller workflow is ~15 lines. GitHub does not let a composite action declare `permissions`,
`concurrency`, or `timeout-minutes`, so those blocks in the example must stay in your workflow.

```yaml
jobs:
  triage:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    steps:
      - uses: k9securityio/reachable-risk-triage-action@v1
        with:
          k9-client-id: ${{ secrets.K9_CLIENT_ID }}
          k9-client-secret: ${{ secrets.K9_CLIENT_SECRET }}
          github-token: ${{ secrets.GH_TRIAGE_TOKEN }}
          teams-webhook-url: ${{ secrets.TEAMS_WEBHOOK_URL }}
          deps-command: "npm ci"
          test-command: "npm test"
```

`deps-command` and `test-command` are your repository's own install and test commands.
`deps-command` is required and runs before the agent analyzes the repo: reachability analysis
inspects the installed dependency trees (site-packages, node_modules), not just the manifests.
Fix PRs are opened only when the test command passes on the bumped branch; leave `test-command`
unset to get triage reports without fix PRs.

## Prerequisites

1. **GitHub Copilot for your organization.** The action authenticates the Copilot CLI with the
   built-in Actions token plus the `copilot-requests: write` permission (declared in the example
   workflow), billed to your organization's Copilot plan. Confirm the organization policy
   **"Allow use of Copilot CLI billed to the organization"** is enabled (Organization Settings →
   Copilot → Policies; it is on by default).
2. **A k9 Security account** with the
   [Reachable Risk](https://www.k9security.io/lp/reachable-risk/) plan (`score_risk` access).
3. **Dependabot alerts enabled** on the repository.
4. Optional: **a Microsoft Teams channel** where run outcomes should be announced.

## Secrets

Repository (or organization) Actions secrets:

| Secret | Value |
| --- | --- |
| `K9_CLIENT_ID` / `K9_CLIENT_SECRET` | A k9 **Service Client (M2M)**: in the k9 app, My Account → Service Clients (M2M) → Create, then copy the id and secret (the secret is shown once). The action mints a fresh short-lived token from these on every run; there is nothing to rotate on a schedule and no token that expires in a drawer. |
| `GH_TRIAGE_TOKEN` | A fine-grained PAT (organization-owned is fine) with repository permissions **Dependabot alerts: read**, **Contents: write**, **Pull requests: write** on the repository. Used only by `gh` to read alerts and to push fix branches and open fix PRs. It does NOT need any Copilot permission. The Actions-issued `GITHUB_TOKEN` cannot read Dependabot alerts, which is why a PAT is required. |
| `TEAMS_WEBHOOK_URL` (optional) | See [Create the Teams webhook](#create-the-teams-webhook). When unset, the run reports to the job summary and artifact only. |
| `COPILOT_GITHUB_TOKEN` (optional) | Only for organizations that cannot hold a Copilot Business plan (GitHub has paused new Copilot Business signups for Free/Team-plan organizations): a classic token of a Copilot-licensed user, passed via the `copilot-github-token` input. When set, it overrides the org-billed path and bills that user's plan. Do NOT use an org-owned fine-grained PAT — it cannot carry the account-level Copilot Requests permission ([github/copilot-cli#223](https://github.com/github/copilot-cli/issues/223)). |

## Inputs

| Input | Required | Default | Purpose |
| --- | --- | --- | --- |
| `k9-client-id` | yes | — | k9 Service Client (M2M) id |
| `k9-client-secret` | yes | — | k9 Service Client (M2M) secret |
| `github-token` | yes | — | Fine-grained PAT for `gh` (see Secrets) |
| `deps-command` | yes | — | Repo's dependency-install command; runs before analysis (reachability needs installed deps) and again on fix branches |
| `test-command` | no | `""` | Repo's test command; unset ⇒ no fix PRs, report only |
| `teams-webhook-url` | no | `""` | Teams Workflows webhook; unset ⇒ no Teams notification |
| `copilot-github-token` | no | Actions token | Copilot auth override (see Secrets) |
| `agent` | no | `copilot` | Agent CLI. v1 supports `copilot`; other values fail fast |
| `model` | no | `claude-sonnet-5` | Model the agent CLI uses |
| `k9-mcp-url` | no | `https://mcp.k9security.io/mcp` | k9 MCP server URL |
| `k9-auth-domain` | no | `auth.k9security.io` | k9 OAuth token domain |
| `k9-audience` | no | `https://mcp.k9security.io/` | OAuth audience for the k9 MCP server |

## Create the Teams webhook

Microsoft retired classic "Incoming Webhook" connectors in May 2026; the supported replacement
is a **Workflows (Power Automate)** webhook:

1. In Teams, open the target channel → ⋯ → **Workflows** (installs the Workflows app if needed).
2. Create the flow from the template **"Post to a channel when a webhook request is received"**
   and point it at the channel.
3. Copy the HTTP POST URL it displays and store it as the `TEAMS_WEBHOOK_URL` secret.

The card shows alert and verdict counts and a button to the run page. A run that fails to
produce a report posts an explicit failure card — silence is never success.

## Where results land

- **Full report**: on the workflow run page — rendered inline in the job summary, and attached
  as the `dependency-triage-report` artifact (the Teams card's button opens this page). Run
  pages require GitHub login with repository access, and artifacts expire with your
  run-retention setting (default 90 days). The durable longitudinal record is k9's
  scored-findings corpus, which every run feeds automatically.
- **Fix PRs**: one per package with actionable findings (FIX_TODAY, or SCHEDULE past its
  fix-release cooldown), labeled `dependency-triage`, opened only after your test command passes
  on the bumped branch; a failing test run lands in the report instead of a PR. When an open
  Dependabot PR already covers the fix, the report marks it ready-to-merge rather than
  duplicating it. REVIEW findings are reported but never acted on — a REVIEW means the evidence
  supports no recommendation yet, so the decision stays with you. Nothing is ever merged or
  dismissed by the action.
- **Counts on the Teams card**: "Alerts scored" counts alerts; FIX_TODAY/REVIEW/SCHEDULE/DEFER
  count **verdicts** — one per execution context an alert's code runs in — so verdicts
  legitimately sum higher than alerts on any project with more than one execution context. The
  two numbers are not a discrepancy.

## Versioning and pinning

- `@v1` — floating major tag, moved on every release in the v1 line. Recommended: fixes and
  improvements reach your workflow without edits. Breaking changes get a new major (`@v2`).
- `@v1.x.y` — immutable release tags, for orgs that bump deliberately.
- `@<full-sha> # vX.Y.Z` — for organizations whose policy (or [zizmor](https://docs.zizmor.sh/)
  `unpinned-uses` audit) requires hash pinning. Take the SHA from the
  [releases page](../../releases).

The action's own dependencies are hash-pinned and zizmor-audited in CI on every change.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Agent step fails immediately: `Authentication failed … ensure it has the 'Copilot Requests' permission` | A fine-grained PAT is being used for Copilot auth. Organization-owned fine-grained PATs cannot carry the account-level Copilot Requests permission (github/copilot-cli#223). Use the default org-billed path (no Copilot secret at all), or a **classic** token in `copilot-github-token`. |
| Agent step fails immediately: `Access denied by policy settings` | The organization's Copilot CLI policy is disabled or the organization has no configured Copilot plan. Enable "Allow use of Copilot CLI billed to the organization", or use the `copilot-github-token` override. |
| Run fails at "Check deliverables exist" | The agent ran but produced no report. Read `agent-run.log` in the run artifact — the failure evidence is there. The Teams card for a failed run says so explicitly. |
| Alert fetch fails / zero alerts unexpectedly | `GH_TRIAGE_TOKEN` is missing Dependabot alerts: read on the repository, or Dependabot alerts are disabled. A genuine zero-alert state is reported as a normal clean run, not an error. |
| actionlint/zizmor flag `copilot-requests` as an unknown permission | False positive: the permission is real but newer than the linters' permission lists (zizmor ≤1.29, actionlint ≤1.7.10). Do not remove the permission. |

## Roadmap

The `agent` input is the seam for driving the same triage with Claude Code or Opencode; the
prompt, guidance fetch, report publishing, and notifications are agent-neutral. v1 ships the
Copilot CLI path.

## License

Apache-2.0. See [LICENSE](LICENSE).
