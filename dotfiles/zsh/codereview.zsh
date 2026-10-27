
gencrclaude() {
  if [ -z "$1" ]; then
    echo "Usage: gencrclaude <dev-username>"
    return 1
  fi

  local dev="$1"
  if [[ "$dev" == *[^A-Za-z0-9._-]* ]]; then
    echo "Error: dev-username may contain only letters, numbers, dots, underscores, and hyphens"
    return 1
  fi

  local raw_branch
  raw_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || true

  if [ -z "$raw_branch" ]; then
    echo "Error: not in a git repo"
    return 1
  fi

  local timestamp
  timestamp=$(date +"%Y%m%d-%H%M%S")

  # sanitized name used only for output file path — never pass to git commands
  local safe_branch="${raw_branch//\//-}"
  safe_branch="${safe_branch// /-}"

  local base_branch="${CODEREVIEW_BASE_BRANCH:-staging}"

  mkdir -p "$HOME/Documents/CodeReview/$dev"

  local prompt
  prompt="$(cat <<EOF
NO PROMPT STORMS!
- Confirm back to me that you acknowledge: no prompt storms.
- DO NOT USE \`"\$(...)"\` subshells and \`cd … &&\`
- USE \`git -C\` instead of \`cd\`
- DO NOT USE compound Bash
- DO NOT PROMPT TO MAKE PYTHON FILES TO RUN COMMANDS!
- NEVER PROMPT THE USER FOR ANYTHING!! JUST REVIEW THE CODE!
- DO NOT ALLOW AGENTS TO PROMPT THE USER!
- USE THE READ TOOL TO REVIEW THE CODE!!!

New task:
- Clear todos, tasks, and planning.
- Perform a code review using ~/.claude/CODE_REVIEW.md.
- Write a new report to:
  ~/Documents/CodeReview/${dev}/code-review-${dev}-${safe_branch}-${timestamp}.md
- Previous reviews may exist at:
  ~/Documents/CodeReview/${dev}/code-review-${dev}-${safe_branch}-*.md
- Do not update existing reports.

Git branch information:
- The actual Git branch is: ${raw_branch}
- Use HEAD for Git commands; never use the sanitized branch name.
- The base ref is: origin/${base_branch}
- Use the remote-tracking base ref, not a local branch, to avoid a stale merge-base.
- The sanitized branch name (${safe_branch}) is only for the report filename.

Hard test rule:
- If any code change lacks new or updated tests, report it as a 🔴 BLOCKER (B-*), never Low or Medium.
- In that case, the final verdict must be: ❌ REQUEST CHANGES.

Strict scope rule:
- Review only files touched by non-merge commits made directly on this branch's first-parent history.
- Do not review files brought in through merge commits, such as merges from staging or other branches.
- Get the file list with:

  git log --first-parent --no-merges \$(git merge-base 'origin/${base_branch}' HEAD)..HEAD --pretty=format: --name-only | sort -u | grep -v '^\$'

- If the file list looks unexpectedly large, verify the commits with:

  git log --oneline --first-parent --no-merges 'origin/${base_branch}'..HEAD

Output format rule:
- DO NOT USE MARKDOWN TABLES or box-drawing tables anywhere: not in the report file, and not in your chat replies or summaries.
- Report findings as bullet lists. Reports get pasted into GitHub comments, which are too narrow to show tables well.
- Start each finding with its ID and a short title, then put details in nested bullets, for example:
  - **B-1 Cycle test passes even with the fix undone**
    - File: path/to/file.ts:42
    - Problem: ...
    - Fix: ...
- Use the same bullet format for comparisons such as prior findings vs. how they were fixed.
EOF
)"

  claude "$prompt"
}
