#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Prerequisites ─────────────────────────────────────────────────────────────

check_prereq() {
  if ! command -v "$1" &>/dev/null; then
    echo "❌ Required tool not found: $1"
    echo "   $2"
    exit 1
  fi
}

check_prereq git   "Install git: https://git-scm.com/downloads"
check_prereq claude "Install Claude Code CLI: https://claude.ai/code"

# ── Directories ───────────────────────────────────────────────────────────────

mkdir -p ~/Documents/CodeReview
mkdir -p ~/.claude/commands

# ── Symlinks ──────────────────────────────────────────────────────────────────

ln -sf "${REPO_DIR}/dotfiles/claude/code_review_query.md" ~/.claude/code_review_query.md
echo "✓ ~/.claude/code_review_query.md"

ln -sf "${REPO_DIR}/dotfiles/claude/CODE_REVIEW.md" ~/.claude/CODE_REVIEW.md
echo "✓ ~/.claude/CODE_REVIEW.md"

ln -sf "${REPO_DIR}/dotfiles/claude/commands/code-review.md" ~/.claude/commands/code-review.md
echo "✓ ~/.claude/commands/code-review.md"

# ── Optional: ~/bin ───────────────────────────────────────────────────────────

if [ -d ~/bin ]; then
  ln -sf "${REPO_DIR}/bin/gencr" ~/bin/gencr
  echo "✓ ~/bin/gencr"
else
  echo "ℹ  ~/bin not found — skipping gencr symlink (add ~/bin to PATH or create it manually)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "✅ Setup complete."
echo ""
echo "Next: add this line to your ~/.zshrc:"
echo "   source ${REPO_DIR}/dotfiles/zsh/codereview.zsh"
echo ""
echo "Optional — override the default base branch 'staging' (add to ~/.zshrc):"
echo "   export CODEREVIEW_BASE_BRANCH=main"
