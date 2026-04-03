
mkdir -p ~/Documents/CodeReview

ln -sf ~/src/codereview/dotfiles/claude/code_review_query.md ~/.claude/code_review_query.md
ln -sf ~/src/codereview/dotfiles/claude/CODE_REVIEW.md ~/.claude/CODE_REVIEW.md
ln -sf ~/src/codereview/dotfiles/claude/commands/code-review.md ~/.claude/commands/code-review.md

if [ -d ~/bin ]; then
  ln -sf ~/src/codereview/bin/gencr ~/bin/gencr
fi
