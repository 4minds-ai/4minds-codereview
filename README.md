# Claude Code Review

AI-assisted code review using Claude Code. Generates structured, checklist-driven review reports from your git branch — saved locally as Markdown files.

## Prerequisites

- [git](https://git-scm.com/downloads)
- [Claude Code CLI](https://claude.ai/code) — must be installed and authenticated (`claude --version` should work)
- [Codex CLI](https://developers.openai.com/codex/cli) for Codex or adversarial reviews (`codex --version`)
- bash (macOS's bash 3.2 works) and python3 3.8 or newer (standard library only) for headless reviews
- zsh (standard on macOS) for the `gencrnew` shell function

`gencr` runs the same way on macOS and Linux. It uses the CLIs' existing authentication (for example Amazon Bedrock
configured in `~/.claude/settings.json` and `~/.codex/config.toml`); it never needs GitHub credentials locally.

## Setup

```bash
git clone <repo-url> ~/src/codereview
cd ~/src/codereview
bash setup.sh
```

The setup script will:
- Check that `git` and `claude` are available
- Symlink the Claude config files into `~/.claude/`
- Create `~/Documents/CodeReview/` for review output
- Symlink `gencr` into `~/bin/` if that directory exists

Then add this line to your `~/.zshrc` to load the shell function:

```zsh
source ~/src/codereview/dotfiles/zsh/codereview.zsh
```

Reload your shell:

```bash
source ~/.zshrc
```

## Configuration

### Base branch

Reviews diff against `staging` by default. To override (e.g. for a personal project that uses `main`), add this to your `~/.zshrc`:

```zsh
export CODEREVIEW_BASE_BRANCH=main
```

## Usage

### From the terminal (recommended)

Run this from inside any git repo:

```bash
gencrnew <dev-username>
```

Example:

```bash
gencrnew swalker
```

This launches Claude Code with a fully constructed review prompt. Claude will:
1. Identify only the files touched by commits made directly on the current branch (merge commits are excluded)
2. Run through the checklist in `~/.claude/CODE_REVIEW.md`
3. Check for a prior review of the same branch and summarize what changed since then
4. Save the report to `~/Documents/CodeReview/<dev-username>/code-review-<dev>-<branch>-<timestamp>.md`

`gencrnew` is a thin wrapper around `gencr <dev-username> --claude=review --interactive`: it opens the same interactive
Claude session with the same prompt as before, and accepts extra options such as `gencrnew swalker --version=2`.

### Headless reviews (`gencr`)

`gencr <dev-username>` with no options prints the legacy one-line prompt, as before. With options, `gencr` runs the
review headless: the reviewer CLIs run non-interactively and read-only, and `gencr` writes a standard report package and
exits with the outcome.

```bash
gencr swalker --version=2                             # Claude reviews (fresh) with CODE_REVIEW_VERSION_2.md (-v=2 also works)
gencr swalker --codex=review                          # Codex reviews (default instructions)
gencr swalker -v=2 --codex=attack                     # Claude reviews first; Codex attacks Claude's findings
gencr swalker -v=2 --codex=review --claude=attack     # Codex reviews first; Claude attacks Codex's findings
gencr swalker -v=2 --codex=attack --claude-model=opus --codex-model gpt-5.6
gencr swalker -v=2 --codex=attack --incremental       # follow-up to the newest compatible previous review
gencr swalker -v=2 --range=1a2b3c4..9f8e7d6           # fresh review of exactly these commits (HEAD = 9f8e7d6)
gencr swalker --interactive                           # interactive Claude session (what gencrnew runs)
gencr swalker -v=2 --codex=attack --print             # print the first reviewer's exact prompt; launch nothing
gencr --help
```

- Instructions: `--version=N` / `-v=N` selects `dotfiles/claude/CODE_REVIEW_VERSION_N.md` in this repository; without it,
  `CODE_REVIEW.md` is used. A missing version is an error, never a fallback.
- Scope: `--fresh` (the default) reviews the complete pull request difference, from the merge-base with
  `origin/$CODEREVIEW_BASE_BRANCH` to HEAD, including changes brought in by merging other branches, renames and
  deletions; reviewers may read surrounding code. `--incremental` reviews the changes since a previous review package and
  requires every previous finding to be verified (`fixed`, `not fixed` or `obsolete`); unfixed findings are carried
  forward. Incremental reviews refuse a baseline from another repository, branch, base, pull request
  (`--pr-number`), instruction version, a different merge-base, a rewritten history, an incomplete package or a
  failed run, and tell you to run `--fresh`. An incremental approval covers only the incremental changes.
- Merged branches: before any reviewer starts, `gencr` prints how it resolved the scope
  (`gencr: review scope: FRESH, method ..., target ..., base ..., head ...`). Check out the branch head to review it:
  - Open branch, or a squash/rebase-merged branch whose head is not in the base: method `merge-base`, target
    `current branch delta` (what the branch changes compared with the base today). This is not proof of the original
    pull request: when the merge-base reached the base through someone else's merge, `gencr` prints a note, and commits
    of the branch that were integrated separately are not reviewed. Give `--range` to review the original proposal.
  - Merged by a merge commit: `gencr` finds the merge commit that introduced HEAD into the base's first-parent history
    (method `merge-commit (found)`, or give it with `--merge-commit=SHA`) and reviews the branch as proposed, from where
    it started before that merge to HEAD; later base commits and edits made only in the merge commit are excluded. To
    review the integrated result instead, check out the merge commit and give `--range=<its first parent>..<merge>`.
  - `--range=BASE..HEAD` reviews exactly that range (SHAs; HEAD must be checked out; BASE must be an ancestor).
  - Fast-forward merges, octopus merges, branches merged indirectly through another branch, shallow clones and
    criss-cross histories with more than one equally good fork point stop with an error that says what to give
    (`--range`, `--merge-commit` or `git fetch --unshallow`); `gencr` never guesses a range. `--range` and
    `--merge-commit` are fresh-only; an explicit-range review is never an incremental baseline, and a merge-commit
    review is one only while HEAD is still the merged head.
- Duplication (incremental only): every changed hunk since the previous review, including deletion-only hunks, is a
  change subject, and `gencr` pre-searches the committed HEAD snapshot (regular files only; no symlinks, submodules,
  generated/vendored, binary or files over 1 MB; bounded in files, bytes, windows and time) for exact and
  identifier-renamed copies of the new code, including code approved in earlier reviews of the same PR. Reviewers get the
  subjects and up to 12 candidates (both locations, snippets, and whether the original existed at the merge-base and at
  the previous review), and must account for every subject (targeted searches for semantic duplicates) and every candidate
  (`duplicate (ID)`, `legitimate reuse`, `common pattern`, `not duplicate`). Duplication findings give `File:` (new code)
  and `Duplicate of:` (existing code), checked against the repository. More than 200 subjects stops the review as
  INCOMPLETE; a bounded index that could not finish is reported as `Duplication Index: partial`. Fresh reviews are
  unchanged. The account is the reviewers' attestation; `gencr` validates its structure, not semantic recall.
- Models: `--claude-model` / `--codex-model` (as `=MODEL` or `MODEL`) are passed to that CLI on every invocation,
  whichever role it has. Without them the CLI's configured default is used. Reports show the model each CLI reported
  using; `Not reported` when a CLI does not say, `Not used` for a reviewer that did not take part.
- Reviewers: Claude runs `-p --restricted --safe-mode` with only Read/Grep/Glob and the `env`/`model` values of your
  user `~/.claude/settings.json` (so Bedrock authentication and the default model keep working); repository settings,
  CLAUDE.md, hooks and plugins are ignored. Codex runs `exec --sandbox read-only` and ignores the repository's AGENTS.md.
  `gencr` computes the scope and diff itself and delivers one shared prompt, verbatim, to every invocation.
- Report format: every finding field is a nested bullet `- <Label>:` and every `## Review notes` entry a bullet
  `- <Label>:`, with one value grammar: the value is text on the label line, a block of lines directly below it
  (indented at least two spaces deeper, no blank line before the first), or both. Nested bullets, code and blank lines
  inside a value are kept byte for byte in `findings.json` (with each field's layout), the reports and the next
  incremental baseline, and the full report shows a block below its label as written. `Severity`, `File` and
  `Duplicate of` are single lines. Outside a fenced code block (``` or ~~~), a value line may not look like report
  structure — a field or entry label, a finding heading, a `## ` heading or a `VERDICT:`/`PEER-` line — so indented text
  can never stand for or swallow a field, finding, section or control line; inside a fence it is literal text. Empty
  values, text that belongs to no field, unknown or repeated labels, missing fields and repeated report sections make a
  report invalid instead of being dropped. When a report is invalid only because a label carries a qualifier
  (`Evidence (traced, not executed):`), `gencr` repairs that formatting itself, without calling any reviewer and
  without counting a round: it moves only the qualifier and the label colon, checks independently that every finding,
  field value, verdict and peer reference is unchanged byte for byte, then validates the result with the same rules.
  The reviewer's response is kept as `<id>.report.original.md`, `<id>.normalization.json` records the repairs, and the
  reports say "format normalized". Anything else stays INCOMPLETE.
- Finding ownership: a reviewer's `## Findings` holds only the findings it authors, under its own prefix (an incremental
  review's unfixed previous findings keep their original IDs). It accepts, rejects or disputes the other reviewer's
  findings only by reference: exactly one `- CODEX-1: accepted — <evidence>` row per finding of the report it answers,
  and the ID under `## Merge blockers` when it blocks. To keep accepting a finding the other reviewer's latest report
  no longer lists, it writes the source-qualified row its handoff shows, `- CODEX-2 (report <earlier report ID>):
  accepted — <evidence>` (acceptance only; leaving the row out withdraws it). A restated or renamed peer finding, a
  row that names no finding of the report it refers to, or a repeated row makes the report invalid (it is never
  renamed or repaired). An accepted peer finding stays in the consolidated report, `findings.json` and the review
  comment under its original ID and author, taken from the exact report version that was accepted, even if its
  author no longer lists it.
- Observations that are not findings: the review instructions ask every reviewer to finish with verified clean checks,
  unresolved risks, disproven claims, test gaps and out-of-scope ownership changes. Each report ends (after every other
  section) with `## Review notes`, holding exactly these entries in order: `Verified clean`, `Unresolved risks`,
  `Disproven claims`, `Test gaps`, `Out-of-scope ownership changes`, `Other observations` (`None` when empty). They are
  kept in the full report and `findings.json` (`review_notes`), never counted as findings or blockers, and not shown in
  the review comment. `## Outstanding disputed findings` holds only one row per disputed finding, `- CODEX-2: <why>`,
  naming a finding of the review; observation text there, inside `## Findings`, or under an unknown `##` heading after
  the first section makes the report invalid (it is never moved).
- Adversarial reviews stop when both reviewers approve, or both request changes with aligned findings; otherwise they
  reconcile for at most 3 rounds, counted by `gencr`.
- `--reviewer-timeout=SECONDS` stops a reviewer that runs too long. The review refuses uncommitted tracked changes and
  fails if HEAD or tracked files change during the review.

Each headless run writes `~/Documents/CodeReview/<dev-username>/review-<dev>-<branch>-<timestamp>-<id>/` (or
`--output-dir=DIR`, which must be outside the reviewed repository) containing `summary.md`, `full-report.md`,
`findings.json`, `reconciliation.md`, `metadata.json`, `manifest.json` (written last) and every prompt and report, plus a
copy of the full report at `code-review-<dev>-<branch>-<timestamp>-<id>.md`. Simultaneous runs get separate
directories, and no file is ever overwritten. Every report starts with the same header: review mode (FRESH or
INCREMENTAL, with the previous review ID and SHA), approval scope, reviewed HEAD SHA, base and merge-base, review scope
(method, target, range and merge commit), Claude and Codex models, verdicts and rounds.

When a headless review finishes and its package is saved, `gencr` prints a short review comment you can paste into
GitHub's REQUEST CHANGES review, between `========== GITHUB REVIEW COMMENT ==========` and
`========== END REVIEW COMMENT ==========`, then the path of the complete report (send it to the developer with the
comment). The comment is the block saved at the top of `summary.md` (the PR comment in CI uses the same block). It is
built from the final results only, without calling a reviewer: the verdict (or, for an incomplete run, that no valid
approval or rejection was produced), the mode and approval scope, the reviewed commit, the models, every merge blocker
first (by severity), then up to five other significant findings and the disputed items, and an instruction to address
the full report. Each finding shows who listed it and the other reviewer's explicit position on it ("accepted",
"rejected", "disputed", "not assessed", or "accepted an earlier version" when the finding changed after that review);
an overall verdict is never presented as agreement on a finding, and a review that ended without agreement says so.
Recommended fixes are copied verbatim (in a code block when they contain `@`, HTML comments or similar). The comment is
limited to 40,000 characters: if the merge blockers do not all fit, it states the total, how many it lists and how
many more there are (with their IDs when they fit); the complete report and `findings.json` always have all of them.
Set `GENCR_REVIEW_COMMENT=off` to print a one-line result instead (the CI workflow does).

Exit status: `0` APPROVED, `10` REQUEST CHANGES, `11` UNRESOLVED DISAGREEMENT, `20` INCOMPLETE (invalid report, missing
prompt part, repository changed), `21` reviewer failure (CLI error, empty report, model selection failure), `22` timeout,
`23` the report could not be saved, `2` usage error, `1` other errors.

### Tests

```bash
bash tests/test_gencr.sh      # engine: mock reviewer CLIs, no network
bash tests/test_gencr_ci.sh   # GitHub adapter and workflows: mock gh API
bash tests/test_gencr_dup.sh  # incremental duplication check: real Git fixtures, mock reviewers
bash tests/test_gencr_scope.sh  # review scope: open and merged branches, explicit ranges (real Git fixtures)
bash tests/test_gencr_format.sh # report grammar, multiline values and format normalization
bash tests/test_gencr_summary.sh # GitHub-ready review comment (terminal and PR comment)
bash tests/test_gencr_peer.sh  # peer-finding ownership and references (replays a real failed reconciliation)
bash tests/test_gencr_notes.sh # review notes and disputed rows (replays a real misplaced-observations failure)
bash tests/test_gencr_values.sh # field values: inline, block, fences and reserved lines (replays a real failure)
bash tests/run_ubuntu.sh      # all suites in a clean Ubuntu container (needs Docker)
```

### GitHub Actions (manual, mock reviewers only)

`.github/workflows/gencr-review.yml` reviews a pull request of this repository when started manually
(`workflow_dispatch`) from the default branch. Open and merged pull requests are reviewed (closed unmerged ones are
refused). For a fresh review of a merged pull request, the job passes `--merge-commit` for a regular merge, or an exact
`--range` built from the pull request's complete commit list (every page read, the count checked against the pull
request, and the commits checked against the local history); if that cannot be established it fails and says to review
locally with `--range`. Inputs: PR number, instruction version, fresh or incremental, primary and
adversarial reviewer (or none), optional models, artifact retention (1–90 days) and reviewer timeout. A first `trust`
job, which runs no repository code and has no permissions, rejects any ref other than the default branch and any backend
other than mock; nothing else runs without it. The review job checks out trusted tooling from the workflow's own commit
and the PR head as data only, with read-only permissions, and runs `gencr`; the publish job (pull-requests and statuses
write only, no PR code) checks that the package belongs to this repository, pull request and reviewed commit, updates one
bot-managed PR comment and sets the status on the reviewed commit: success only for APPROVED from a successful review
job. While only mock reviewers exist, results use the `gencr/review-mock` status context and are labelled as pipeline
tests, not code reviews; a mock result is never accepted as the baseline of a real incremental review. Every run uploads
`code-review-pr-N/` (`summary.md`, `full-report.md`, `findings.json`, `reconciliation.md`, `metadata.json`,
`manifest.json`, `ci-backend.json`, `transcripts/`) as a workflow artifact, and the bot comment is the package's own
review comment from `summary.md` plus the artifact link; artifacts expire after the retention period and are not
permanent PR attachments. No report is ever committed. `.github/workflows/gencr-tests.yml` runs the test suites on
Ubuntu and macOS without secrets.

Paid reviews are disabled: the only reviewer backend is `mock`. Enabling real Claude and Codex reviews in CI requires a
DevOps-provisioned organization-owned CI identity with validated Bedrock access for both CLIs, a credential-isolation
design proven with canary secrets (reviewer processes must not be able to read the credentials or reach unauthorized
network destinations), and a reviewed change to the workflow. The workflow is not a required check and blocks no merge.

### From inside Claude Code

```
/project:code-review <dev-username>
```

## Review reports

Reports are saved to:

```
~/Documents/CodeReview/<dev-username>/
  code-review-<dev>-<branch>-<timestamp>.md
```

Each report covers:

- Risk assessment (Low / Medium / High)
- Correctness & logic
- Testing (missing tests are an automatic **🔴 BLOCKER**)
- Data integrity & state
- Concurrency & async
- Performance
- Security
- API & contract
- Database & migrations (with production safety rules)
- Observability
- Frontend behavior
- Rollout safety
- Housekeeping

## Hard rules

These are enforced regardless of PR size or context:

- **Missing tests → 🔴 BLOCKER** — any code change without new or updated tests is a blocker, not a low/medium finding. The final verdict will be `❌ REQUEST CHANGES`.
- **Scope is the branch only** — Claude reviews only files from non-merge commits on the current branch. Files brought in via `Merge branch 'staging'` (or similar) are excluded.

## Structure

```
~/src/codereview/
├── setup.sh                              # Symlinks dotfiles, checks prerequisites
├── bin/
│   ├── gencr                             # Legacy prompt; headless and interactive reviews
│   ├── gencr_support.py                  # Reviewer invocation, previous-review lookup, report packages
│   ├── gencr_duplicates.py               # Incremental duplication pre-search and validation
│   └── gencr-ci                          # GitHub Actions adapter (gate, PR context, artifact, PR comment)
├── .github/workflows/
│   ├── gencr-review.yml                  # Manual PR review (mock reviewers only)
│   └── gencr-tests.yml                   # Test suites on Ubuntu and macOS
├── tests/
│   ├── test_gencr.sh                     # gencr/gencrnew tests with mock CLIs
│   ├── test_gencr_ci.sh                  # gencr-ci and workflow tests with a mock gh API
│   ├── test_gencr_dup.sh                 # Incremental duplication check tests
│   ├── test_gencr_peer.sh                # Peer-finding ownership and reference tests
│   ├── test_gencr_notes.sh               # Review notes and disputed-row tests
│   ├── test_gencr_values.sh              # Field-value grammar tests (blocks, fences, reserved lines)
│   ├── run_ubuntu.sh                     # Runs both suites in Docker (Ubuntu)
│   ├── mocks/                            # Mock claude, codex and gh CLIs
│   └── fixtures/                         # Previous gencrnew; sanitized replay of a failed reconciliation
└── dotfiles/
    ├── claude/
    │   ├── CODE_REVIEW.md                # The review checklist
    │   ├── CODE_REVIEW_VERSION_<N>.md    # Versioned checklists (gencr --version=N)
    │   ├── code_review_query.md          # Legacy prompt template (plain gencr)
    │   └── commands/
    │       └── code-review.md            # /project:code-review slash command
    └── zsh/
        └── codereview.zsh                # gencrnew() wrapper around gencr
```

## Troubleshooting

**`claude: command not found`**
Install Claude Code CLI: https://claude.ai/code

**`Error: not in a git repo`**
Run `gencrnew` from inside a git repository.

**Review includes files from staging or other merged branches**
This should not happen — Claude is instructed to use `git log --no-merges --ancestry-path` scoped to your branch. If it does, re-run and paste the file list back to Claude with: *"these files are out of scope, only review files from non-merge commits on this branch"*.

**Wrong base branch**
Set `CODEREVIEW_BASE_BRANCH` in your `~/.zshrc` (see Configuration above).
