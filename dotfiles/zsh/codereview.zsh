
gencrnew() {
  if [ -z "$1" ]; then
    echo "Usage: gencrnew <dev-username>"
    return 1
  fi

  local dev="$1"
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || true

  if [ -z "$branch" ]; then
    echo "Error: not in a git repo"
    return 1
  fi

  local timestamp
  timestamp=$(date +"%Y%m%d-%H%M%S")

  # sanitize branch
  branch="${branch//\//-}"
  branch="${branch// /-}"

  mkdir -p "$HOME/Documents/CodeReview/$dev"

  claude "new task: clear todos/tasks/planning; perform a code review on current branch ${branch} using ~/.claude/CODE_REVIEW.md; write a new report to ~/Documents/CodeReview/${dev}/code-review-${dev}-${branch}-${timestamp}.md; previous reviews may exist at ~/Documents/CodeReview/${dev}/code-review-${dev}-${branch}-*.md; do not update existing reports; NOTE: branch name has already been sanitized (slashes replaced with dashes); HARD RULE: if any code change lacks new or updated tests, it MUST be reported as a 🔴 BLOCKER (B-*), NEVER Low or Medium, and the final verdict MUST be \"❌ REQUEST CHANGES\""
}
