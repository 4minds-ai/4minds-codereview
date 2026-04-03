# Claude Code Review

AI-assisted code review using Claude Code. Generates structured, checklist-driven review reports from your git branch — saved locally as Markdown files.

## Prerequisites

- [git](https://git-scm.com/downloads)
- [Claude Code CLI](https://claude.ai/code) — must be installed and authenticated (`claude --version` should work)
- zsh (standard on macOS)

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
│   └── gencr                             # Outputs the review prompt (legacy/debug use)
└── dotfiles/
    ├── claude/
    │   ├── CODE_REVIEW.md                # The review checklist
    │   ├── code_review_query.md          # Prompt template (used by gencr)
    │   └── commands/
    │       └── code-review.md            # /project:code-review slash command
    └── zsh/
        └── codereview.zsh                # gencrnew() shell function
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
