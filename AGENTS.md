# AGENTS.md

This file provides guidance to AI coding agents (Claude Code reads it via the CLAUDE.md symlink) when working with code in this repository.

## What this repository is

A composite GitHub Action (`k9securityio/reachable-risk-triage-action`) that runs scheduled, agent-driven triage of a repository's Dependabot alerts using the k9 Security MCP server's Reachable Risk rubric. There is no application code, build step, or test suite — the deliverable is `action.yml` plus its bash scripts, prompt, and example caller workflow. This is a published supply-chain artifact that customers execute with secrets in scope; CI treats lint/audit findings as release gates.

## Commands

There is no build or unit-test step. CI (`.github/workflows/ci.yml`) runs three checks; run them locally before pushing:

```bash
shellcheck scripts/*.sh
actionlint -ignore 'unknown permission scope "copilot-requests"' .github/workflows/*.yml examples/*.yml
zizmor --min-severity low . examples/dependency-triage.yml
```

To exercise the guidance-fetch script against the real k9 MCP server (needs a bearer token minted via client_credentials — see the "Mint k9 MCP token" step in `action.yml` for the curl):

```bash
K9_MCP_URL=https://mcp.k9security.io/mcp K9_MCP_TOKEN=<jwt> bash scripts/fetch-k9-guidance.sh
```

Output lands in `out/` (gitignored).

## Architecture

The pipeline in `action.yml` (verified end-to-end): checkout → `gh auth setup-git` → install repo deps (`deps-command`) → mint short-lived k9 M2M token → fetch k9 workflow guidance → install Copilot CLI (version-pinned) → run the agent headlessly with the k9 MCP server → check deliverables → publish job summary + artifact → notify Teams.

Key design decisions to preserve:

- **The k9 MCP server is the source of truth for the triage procedure.** `scripts/fetch-k9-guidance.sh` reads the server's `k9://workflow/*` MCP resources over raw JSON-RPC and writes them to `out/k9-guidance/*.md` for the agent (Copilot CLI can call MCP tools but not read MCP resources). Never restate rubric or workflow procedure text in this repo — rubric updates must reach users without a release of this action.
- **`prompts/dependency-triage-prompt.md` is the agent's contract.** It is expanded with `envsubst` on a fixed variable allowlist (`$GITHUB_REPOSITORY $GITHUB_SERVER_URL $GITHUB_RUN_ID $K9_DEPS_COMMAND $K9_TEST_COMMAND` — keep the list in `action.yml` in sync with the placeholders). It defines the deliverable contract: `out/dependency-triage-report.md` and `out/triage-summary.json` with schema `k9-triage-summary/v2`. Three places must agree on that schema: the prompt, the "Check deliverables exist" step, and `scripts/notify-teams.sh`.
- **Scope guarantees are load-bearing product claims**: the action opens fix PRs and reports, but never merges anything and never dismisses alerts; REVIEW verdicts are never acted on; fix PRs open only when `test-command` passes on the bumped branch. Don't loosen these in the prompt or scripts without treating it as a breaking behavior change.
- **Two-token model.** `github-token` is a fine-grained PAT for `gh` (Dependabot alerts: read + Contents/PRs: write — the Actions `GITHUB_TOKEN` cannot read Dependabot alerts). Copilot auth is separate (`COPILOT_GITHUB_TOKEN` > `GH_TOKEN` precedence in the CLI is why the agent step pins `COPILOT_GITHUB_TOKEN` explicitly). The k9 token is minted fresh each run and handed between steps via a `$RUNNER_TEMP` file, deliberately not `GITHUB_ENV`.
- **Failure is loud, silence is never success.** The agent exiting 0 is not trusted: the deliverables check fails the job if the report/summary are missing or off-schema; `pipefail` on the agent step keeps `tee` from masking a copilot failure; a missing summary makes `notify-teams.sh` post an explicit run-failed card. Zero open alerts is a normal clean run, not an error.
- **The caller workflow owns what a composite action cannot declare** — `permissions` (including `copilot-requests: write`), `concurrency`, `timeout-minutes`. Changes there go in `examples/dependency-triage.yml` and the README, not `action.yml`.
- **The `agent` input is the seam** for future Claude Code / Opencode support; the guidance fetch, prompt, deliverables check, and notifications are agent-neutral. v1 fails fast on anything but `copilot`.

## Known false positives — do not "fix"

- actionlint (≤1.7.10) and zizmor (≤1.29) flag `copilot-requests` as an unknown permission. The permission is real; the ignores in CI are deliberate. Re-check on linter upgrades.
- The example caller uses the floating `@v1` tag with `# zizmor: ignore[unpinned-uses]` on purpose; the action's own dependencies stay hash-pinned.
- The global `npm install -g @github/copilot@<pinned>` carries `# zizmor: ignore[adhoc-packages]` as an accepted, version-bounded residual finding.

## Versioning

Releases move a floating `@v1` major tag plus immutable `@v1.x.y` tags; breaking changes get a new major. Commit messages follow conventional-commit style (`feat:`, `fix:`, `docs:`, `feat!:` for breaking).
