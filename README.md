# Claude Code Review

AI-assisted code review using Claude Code. Generates structured, checklist-driven review reports from your git branch — saved locally as Markdown files.

## Prerequisites

- [git](https://git-scm.com/downloads)
- [Claude Code CLI](https://claude.ai/code) — must be installed and authenticated (`claude --version` should work)
- [Codex CLI](https://developers.openai.com/codex/cli) for Codex or adversarial reviews (`codex --version`)
- bash (macOS's bash 3.2 works) and python3 3.8 or newer (standard library only) for headless reviews
- zsh (standard on macOS) for the `gencrclaude` shell function

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

### Reviews (`gencr`)

Run this from inside any git repository (with the branch to review checked out):

```bash
gencr <dev-username>
```

`gencr swalker` runs a headless review with the new review engine: Claude reviews (the default reviewer), read-only,
and `gencr` writes the complete review package and consolidated Markdown report, prints a GitHub-ready review comment
and exits with the outcome. It decides the scope automatically and says so before any reviewer starts
(`gencr: review mode: ...`):

- no compatible earlier review of this branch in the output directory: FRESH (the complete pull request);
- otherwise INCREMENTAL from the latest compatible completed review (APPROVED or REQUEST CHANGES): same repository,
  developer, pull request, branch, base, instructions, scope and merge-base, an intact package, and a reviewed commit
  that is in HEAD's history. Reviews are ordered by commit history, never by timestamp alone;
- that review already covers HEAD: no reviewer is launched; `gencr` prints the review's ID, commit and verdict and exits
  `0` ("no new review needed" — not an approval);
- the latest review ended UNRESOLVED DISAGREEMENT (packages from before primary-reviewer authority; new runs end
  APPROVED or REQUEST CHANGES), several reviews could be the baseline and none is unambiguously the
  latest (for reviews of one commit: a missing or invalid completion time, or two sharing the latest one), or the latest
  review's own metadata is invalid: `gencr` stops before any reviewer (exit `1`), lists them, and asks you to add
  `--incremental` (optionally `--previous=<package>`) or `--fresh`. A package with invalid metadata is never coerced into
  a baseline, skipped in favour of an older review, or accepted as `--previous`.

`--incremental` requires a compatible previous review and never falls back to FRESH; it may continue an UNRESOLVED
DISAGREEMENT review (also at the same HEAD), with its own limit of three reconciliation rounds — the previous review's
ID, verdict and rounds are stated and recorded. `--fresh` always starts a complete new review and deletes nothing; when
an earlier review exists and you are at a terminal it asks first:

```
Previous code review detected for this branch.

A FRESH review will start over and ignore the previous review as its baseline.

Continue with FRESH? [Y/n] (15 seconds; default Y)
```

Enter or `y` continues, `n` cancels (exit `1`, no reviewer launched), no answer within 15 seconds continues FRESH, and
an invalid answer asks again within the same 15 seconds. The question is read from the controlling terminal (never from
standard input) and is never asked without a terminal or with `--print`.

### The original Claude workflow (`gencrclaude`)

`gencrclaude <dev-username>` (from `dotfiles/zsh/codereview.zsh`) is the original Claude-only review: it opens an
interactive Claude session with the original prompt and old report format, and never runs Codex or `bin/gencr`.

### Options

```bash
gencr swalker --version=2                             # Claude reviews with CODE_REVIEW_VERSION_2.md (-v=2 also works)
gencr swalker --codex=review                          # Codex reviews (default instructions)
gencr swalker -v=2 --codex=attack                     # Claude reviews first; Codex attacks Claude's findings
gencr swalker -v=2 --codex=review --claude=attack     # Codex reviews first; Claude attacks Codex's findings
gencr swalker -v=2 --codex=attack --claude-model=opus --codex-model gpt-5.6
gencr swalker -v=2 --codex=attack --fresh             # start over (asks first when an earlier review exists)
gencr swalker -v=2 --codex=attack --incremental       # follow-up to the latest compatible previous review
gencr swalker -v=2 --range=1a2b3c4..9f8e7d6           # fresh review of exactly these commits (HEAD = 9f8e7d6)
gencr swalker -v=2 --codex=attack --print             # print the first reviewer's exact prompt; launch nothing
gencr --help
```

- Instructions: `--version=N` / `-v=N` selects `dotfiles/claude/CODE_REVIEW_VERSION_N.md` in this repository; without it,
  `CODE_REVIEW.md` is used. A missing version is an error, never a fallback.
- Scope: FRESH reviews the complete pull request difference, from the merge-base with
  `origin/$CODEREVIEW_BASE_BRANCH` to HEAD, including changes brought in by merging other branches, renames and
  deletions; reviewers may read surrounding code. `--incremental` reviews the changes since a previous review package and
  requires every previous finding to be verified (`fixed`, `not fixed` or `obsolete`); unfixed findings are carried
  forward. Incremental reviews refuse a baseline from another repository, branch, base, pull request
  (`--pr-number`), instruction version, a different merge-base, a rewritten history, an incomplete package or a
  failed run, and tell you to run `--fresh`. An incremental approval covers only the incremental changes. Earlier review
  packages without newer optional fields (review notes, value layouts, previous-review details) stay usable as baselines;
  `gencrclaude` reports are never review packages.
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
- Finding ownership and explicit positions (report contract v2): a reviewer's `## Findings` holds only the findings it
  authors, under its own prefix (an incremental review's unfixed previous findings keep their original IDs), each with
  `Introduced by this change: yes|no`. Every earlier finding of its own is either restated there (its current version)
  or withdrawn under `## Withdrawn findings` (`- CLAUDE-2: withdrawn — <reason>`); leaving one out makes the report
  invalid. It states its position on each of the other reviewer's findings only by reference, one row per finding of
  the report it answers, with every facet: `- CODEX-1: accepted; introduced: yes; severity: medium; blocking: no —
  <evidence>` (or `disputed; …`, or `- CODEX-1: rejected — <evidence>`); `blocking: yes` goes with the ID under
  `## Merge blockers`. A claim on a finding its author withdrew is kept or ended with the source-qualified row its
  handoff shows, `- CODEX-2 (report <ID>): accepted; … — <evidence>` or `… (report <ID>): withdrawn — <reason>`.
  Objections to a finding's evidence, fix or scope go under `## Supplemental objections` (`- CLAUDE-O1 (CODEX-2; fix):
  raised — <why>`, later maintained, conceded or withdrawn; the other reviewer answers `- CLAUDE-O1: accepted|rejected
  — <why>`; its latest answer to the objection's current wording decides it, so a later rejection reopens an earlier
  acceptance). A finding whose text or blocking position changed is a new version: an earlier assessment of it is never
  counted as agreement. A restated or renamed peer finding, a missing facet, a row that names no finding of the report it refers
  to, a repeated row or an unanswered objection makes the report invalid (format normalization never supplies a
  judgment). A finding stays in the consolidated report while either reviewer keeps a claim on it, under its original
  ID and author.
- Observations that are not findings: the review instructions ask every reviewer to finish with verified clean checks,
  unresolved risks, disproven claims, test gaps and out-of-scope ownership changes. Each report ends (after every other
  section) with `## Review notes`, holding exactly these entries in order: `Verified clean`, `Unresolved risks`,
  `Disproven claims`, `Test gaps`, `Out-of-scope ownership changes`, `Other observations` (`None` when empty). They are
  kept in the full report and `findings.json` (`review_notes`), never counted as findings or blockers, and not shown in
  the review comment. `## Outstanding disputed findings` holds only one row per disputed finding, `- CODEX-2: <why>`,
  naming a finding of the review; it is the reviewer's dated statement (gencr takes the disputes from the explicit
  positions). Observation text there, inside `## Findings`, or under an unknown `##` heading after the first section
  makes the report invalid (it is never moved).
- Primary-reviewer authority: the primary reviewer's latest valid verdict is the review's verdict (primary APPROVED +
  attacker REQUEST CHANGES = APPROVED; primary REQUEST CHANGES + attacker APPROVED = REQUEST CHANGES). The attacker has
  no veto; its unresolved objections stay in every artifact with both reviewers' positions. gencr folds the reports in
  order into a ledger of each reviewer's latest position per finding — exists, introduced by this change, severity,
  blocks merge — and the version each position assessed. The review stops as soon as both verdicts and every position
  agree; otherwise the reviewers reconcile for at most 3 rounds, counted by `gencr`, and the primary always answers the
  attacker's latest report. A missing, invalid or incomplete report never yields a verdict (INCOMPLETE).
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
built from the final adjudicated results only, without calling a reviewer:

- the verdict and whether it is unanimous: `APPROVED — unanimous: both reviewers approve and agree on every finding.`,
  or `APPROVED by primary reviewer — NOT UNANIMOUS; N attacker objections remain.` (likewise for REQUEST CHANGES), both
  reviewers' verdicts, the number of attacker objections and of the primary's merge blockers, the mode and approval
  scope, the reviewed commit and the models;
- every attacker objection (of any severity), first as an index entry: its ID, title, original author, file and each
  reviewer's position on existence, introduced by this change, severity and blocking (with the version caveat when a
  position assessed an earlier version); then — as space allows — evidence (an excerpt), the recommended fix (verbatim
  in a code block, or a pointer when it does not fit), the primary's response, the attacker's latest dated statement
  ("answered later by …" when the other reviewer replied) and each open supplemental objection with the other
  reviewer's latest response (marked when it answered an earlier version of the objection);
- the primary reviewer's merge blockers by severity, then up to five other significant findings, each with the other
  reviewer's explicit position ("accepted", "rejected", "disputed", "not assessed", or "accepted an earlier version").

The comment is limited to 40,000 characters. Whatever does not fit is disclosed with numbers ("N of M attacker
objections are not shown in this comment", or not shown in full); the complete report, `findings.json` and every other
saved file are never shortened, locally or in CI. The full report's `## Adjudication` section has every finding with
both positions, version labels, statements and history. Set `GENCR_REVIEW_COMMENT=off` to print a one-line result
instead (the CI workflow does).

The terminal's final line marks the verdict with its qualification (`gencr: final verdict: ✅ APPROVED by primary
reviewer — NOT UNANIMOUS; 1 attacker objections remain; report: …`); the verdict tokens in reports, `findings.json`,
metadata and the review comment are APPROVED and REQUEST CHANGES.

Exit status: `0` APPROVED (also when not unanimous; or no new review needed: the previous review already covers HEAD), `10`
REQUEST CHANGES, `20` INCOMPLETE (invalid report, missing
prompt part, repository changed), `21` reviewer failure (CLI error, empty report, model selection failure), `22` timeout,
`23` the report could not be saved, `2` usage error, `1` other errors (including a declined FRESH confirmation and a review
mode that needs your decision).

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
bash tests/test_gencr_auto.sh   # automatic FRESH/INCREMENTAL selection and the --fresh confirmation (pseudo-terminal)
bash tests/test_gencrclaude.sh  # gencrclaude: the original Claude workflow, independent of gencr
bash tests/test_gencr_adjudication.sh  # primary-reviewer authority, explicit positions and chronological adjudication
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

Draft pull requests are never reviewed. As soon as the pull request is resolved, and before any other review
preparation (checkout, scope, previous review), `gencr-ci eligibility` reads the live pull request: it must be ready for
review (a boolean `draft: false`) at the resolved head, open (or merged, for a historical review) with consistent
`state`/`merged` values, and the event must be a manual run or `ready_for_review`. Every later preparation step runs only
for an eligible pull request, so a draft is skipped even when, say, its incremental baseline is missing. During the review the engine asks a CI-only eligibility broker (which alone holds the job's
read-only token) immediately before EVERY reviewer launch, so a pull request converted to a draft mid-review gets no
further reviewer. A confirmed draft or ineligible event is a skip: nothing is published and earlier comments and statuses
stay as they are. Missing, stale or ambiguous information fails closed as an infrastructure error, never an approval. A
"no new review needed" result likewise publishes nothing. Reviewer processes never receive `GH_TOKEN` or the broker
socket. Limits: a check-to-launch race of milliseconds remains, and the broker's token is readable by same-user processes
on Linux — part of the credential-isolation prerequisite below. The workflow's trigger stays manual-only; no
`pull_request` trigger is enabled.

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
│   ├── gencr                             # Headless reviews: automatic FRESH/INCREMENTAL, single or adversarial
│   ├── gencr_support.py                  # Reviewer invocation, previous-review lookup, report packages
│   ├── gencr_adjudicate.py               # Primary authority: the chronological claim ledger and its validation
│   ├── gencr_duplicates.py               # Incremental duplication pre-search and validation
│   └── gencr-ci                          # GitHub Actions adapter (gate, PR context, artifact, PR comment)
├── .github/workflows/
│   ├── gencr-review.yml                  # Manual PR review (mock reviewers only)
│   └── gencr-tests.yml                   # Test suites on Ubuntu and macOS
├── tests/
│   ├── test_gencr.sh                     # gencr engine tests with mock CLIs
│   ├── test_gencr_ci.sh                  # gencr-ci and workflow tests with a mock gh API
│   ├── test_gencr_dup.sh                 # Incremental duplication check tests
│   ├── test_gencr_peer.sh                # Peer-finding ownership and reference tests
│   ├── test_gencr_notes.sh               # Review notes and disputed-row tests
│   ├── test_gencr_values.sh              # Field-value grammar tests (blocks, fences, reserved lines)
│   ├── test_gencr_auto.sh                # Automatic review-mode and --fresh confirmation tests
│   ├── test_gencrclaude.sh               # gencrclaude (original Claude workflow) tests
│   ├── test_gencr_adjudication.sh        # Adjudication: unit (adjudication_unit.py) and end to end (adjudication_e2e.py)
│   ├── v2reports.py                      # Contract-v2 report builder for the adjudication tests
│   ├── workflow_sim.py                   # Runs gencr-review.yml locally, step by step (for test_gencr_ci.sh)
│   ├── run_ubuntu.sh                     # Runs every suite in Docker (Ubuntu)
│   ├── mocks/                            # Mock claude, codex and gh CLIs
│   └── fixtures/                         # Original gencrclaude function; sanitized replays of failed reviews
└── dotfiles/
    ├── claude/
    │   ├── CODE_REVIEW.md                # The review checklist
    │   ├── CODE_REVIEW_VERSION_<N>.md    # Versioned checklists (gencr --version=N)
    │   ├── code_review_query.md          # Prompt template linked by setup.sh (not used by gencr)
    │   └── commands/
    │       └── code-review.md            # /project:code-review slash command
    └── zsh/
        └── codereview.zsh                # gencrclaude(): the original Claude review workflow
```

## Troubleshooting

**`claude: command not found`**
Install Claude Code CLI: https://claude.ai/code

**`Error: not in a git repo`**
Run `gencr` or `gencrclaude` from inside a git repository.

**Review includes files from staging or other merged branches**
This should not happen — Claude is instructed to use `git log --no-merges --ancestry-path` scoped to your branch. If it does, re-run and paste the file list back to Claude with: *"these files are out of scope, only review files from non-merge commits on this branch"*.

**Wrong base branch**
Set `CODEREVIEW_BASE_BRANCH` in your `~/.zshrc` (see Configuration above).
