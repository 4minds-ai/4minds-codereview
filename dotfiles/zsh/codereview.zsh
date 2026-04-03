
gencrnew() {
  if [ -z "$1" ]; then
    echo "Usage: gencrnew <dev-username>"
    return 1
  fi

  local dev="$1"
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

  claude "new task: clear todos/tasks/planning; perform a code review using ~/.claude/CODE_REVIEW.md; write a new report to ~/Documents/CodeReview/${dev}/code-review-${dev}-${safe_branch}-${timestamp}.md; previous reviews may exist at ~/Documents/CodeReview/${dev}/code-review-${dev}-${safe_branch}-*.md; do not update existing reports; GIT BRANCH NOTE: the actual git branch name is '${raw_branch}' — use this name (or HEAD) for ALL git commands; the base branch is 'origin/${base_branch}' (use the remote tracking ref, not the local branch, to avoid stale merge-base); the output file path uses a sanitized version ('${safe_branch}') where slashes are replaced with dashes — do NOT use the sanitized name in git commands; HARD RULE: if any code change lacks new or updated tests, it MUST be reported as a 🔴 BLOCKER (B-*), NEVER Low or Medium, and the final verdict MUST be \"❌ REQUEST CHANGES\"; STRICT SCOPE RULE: only review files touched by commits made directly on this branch — get the file list by running: git log --no-merges --ancestry-path \$(git merge-base 'origin/${base_branch}' HEAD)..HEAD --pretty=format: --name-only | sort -u | grep -v '^\$' — do NOT review files brought in via merge commits (e.g. merges from staging or other branches); if the file list looks unexpectedly large, verify with git log --oneline --no-merges 'origin/${base_branch}'..'${raw_branch}' before proceeding"
}
