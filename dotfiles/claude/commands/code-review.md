--
description: Review a PR branch for developer $1. Saves report to ~/Documents/CodeReview/<devname>/code-review-<devname>-<branch>-<timestamp>.md. Checks for prior review to diff against.
---

You are performing a structured code review for developer: $1

## Setup — do this first

1. Run `git branch --show-current` to get the current branch name. Call it <branch>.
2. Get the current timestamp in the format YYYYMMDD-HHMMSS. Call it <timestamp>.
3. Read the checklist from `~/.claude/CODE_REVIEW.md`
4. Check if a previous review exists at `~/Documents/CodeReview/$1/code-review-$1-<branch>-*.md`
   - If one exists, load the most recent one and note what has changed or been addressed since then.
5. Review all changed files: run `git diff main...<branch> --name-only` then read each file.

## Output

Save the completed report to `~/Documents/CodeReview/$1/code-review-$1-<branch>-<timestamp>.md`

At the top of the report include:
- Developer: $1
- Branch: <branch>
- Date: today
- Prior review found: yes/no
- If yes: a short "Since last review" section summarizing what was fixed, what's still open

Then work through the checklist from CODE_REVIEW.md applying ✅ ❌ ⚠️ N/A to each item with explanation.

PRs should be blocked if critical sections (Testing, Security, Migrations) are not satisfied.
