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
5. Determine the base branch by running:
   ```
   echo "${CODEREVIEW_BASE_BRANCH:-main}"
   ```
   Call this value <base>. Use it in all git commands below.

6. Get the list of files to review by running:
   ```
   git log --no-merges --ancestry-path $(git merge-base <base> HEAD)..HEAD --pretty=format: --name-only | sort -u | grep -v '^$'
   ```
   This returns only files touched by commits made directly on this branch — it intentionally excludes merge commits (e.g. merges from staging or other branches). Review only these files.

## STRICT SCOPE RULE

**Only review files returned by the command in step 6.**
- Do NOT review files that were brought in via merge commits (e.g. `Merge branch 'staging' into <branch>`).
- Do NOT review files from other branches that were merged into this branch for the purpose of keeping it up to date.
- If the file list looks unexpectedly large, run `git log --oneline --no-merges <base>..<branch>` to verify only the developer's own commits are in scope, and cross-reference before proceeding.
- When in doubt, exclude the file — only include it if a non-merge commit on this branch directly modified it.

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
