#!/usr/bin/env bash
# Regression tests for gencrclaude (dotfiles/zsh/codereview.zsh): the preserved original Claude-only review workflow.
# It must stay independent of the new engine: it launches Claude with the original prompt and old report format, never
# Codex and never bin/gencr. Mock claude/codex CLIs and a tripwire bin/gencr; no network.
# Usage: bash tests/test_gencrclaude.sh
# shellcheck disable=SC2016,SC2034  # deferred eval checks

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd -P "$(mktemp -d)" && pwd)/gencrclaude tests"
mkdir -p "$WORK"
trap 'rm -rf "$(dirname "$WORK")"' EXIT

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
not_ok() { FAIL=$((FAIL + 1)); echo "not ok - $1"; [ -z "$2" ] || printf '%s\n' "$2" | sed 's/^/    # /'; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else not_ok "$desc"; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }

if ! command -v zsh >/dev/null 2>&1; then
  not_ok "zsh is required for the gencrclaude tests"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# A copy of the repository whose bin/gencr is a tripwire: gencrclaude must never run it.
TREE="$WORK/tree"
mkdir -p "$TREE/bin"
cp -R "$REPO/dotfiles" "$TREE/"
printf '#!/bin/sh\necho "bin/gencr was run" >> "$MOCK_OUT/tripwire"\n' > "$TREE/bin/gencr"
chmod +x "$TREE/bin/gencr"

export HOME="$WORK/home"
mkdir -p "$HOME"
MOCK_BIN="$WORK/mock bin"
export MOCK_OUT="$WORK/mock out"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/claude" <<'EOF'
#!/bin/sh
n=$(( $(cat "$MOCK_OUT/claude-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$MOCK_OUT/claude-count"
printf '%s' "$#" > "$MOCK_OUT/claude-argc"
printf '%s' "$1" > "$MOCK_OUT/claude-prompt"
EOF
printf '#!/bin/sh\necho "codex was run" >> "$MOCK_OUT/tripwire"\n' > "$MOCK_BIN/codex"
printf '#!/bin/sh\necho "gencr on PATH was run" >> "$MOCK_OUT/tripwire"\n' > "$MOCK_BIN/gencr"
cat > "$MOCK_BIN/date" <<'EOF'
#!/bin/sh
if [ "$1" = "+%Y%m%d-%H%M%S" ]; then echo "20261025-120000"; else exec /bin/date "$@"; fi
EOF
chmod +x "$MOCK_BIN/claude" "$MOCK_BIN/codex" "$MOCK_BIN/gencr" "$MOCK_BIN/date"
export PATH="$MOCK_BIN:$PATH"
unset CODEREVIEW_BASE_BRANCH

TARGET="$WORK/target"
git init -q "$TARGET"
git -C "$TARGET" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m base
git -C "$TARGET" checkout -q -b feature/login-fix
NOT_GIT="$WORK/not a repo"
mkdir -p "$NOT_GIT"

reset_mocks() { rm -rf "$MOCK_OUT"; mkdir -p "$MOCK_OUT"; }
# run_fn FILE DIR ARGS... — sources FILE in a clean zsh and runs gencrclaude from DIR; sets STATUS and OUT.
run_fn() {
  local file="$1" dir="$2"
  shift 2
  OUT="$(cd "$dir" && zsh -fc 'source "$1"; shift; gencrclaude "$@"' zsh "$file" "$@" 2>&1)"
  STATUS=$?
}
calls() { cat "$MOCK_OUT/claude-count" 2>/dev/null || echo 0; }

# The preserved original function (main 2b045f7, renamed), run under the same mocks, is the reference.
reset_mocks
run_fn "$REPO/tests/fixtures/gencrclaude.original.zsh" "$TARGET" swalker
cp "$MOCK_OUT/claude-prompt" "$WORK/original.prompt"
check "the reference run of the original function launched Claude once" eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 1 ]'

reset_mocks
run_fn "$TREE/dotfiles/zsh/codereview.zsh" "$TARGET" swalker
check "gencrclaude launches Claude exactly once, with one argument (the prompt)" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 1 ] && [ "$(cat "$MOCK_OUT/claude-argc")" = 1 ]'
check "gencrclaude sends exactly the original prompt" cmp -s "$MOCK_OUT/claude-prompt" "$WORK/original.prompt"
prompt="$(cat "$MOCK_OUT/claude-prompt")"
check "the prompt is the original workflow's (old report path and checklist, no new-engine contract)" \
  eval 'contains "$prompt" "NO PROMPT STORMS!" && contains "$prompt" "Perform a code review using ~/.claude/CODE_REVIEW.md." &&
        contains "$prompt" "~/Documents/CodeReview/swalker/code-review-swalker-feature-login-fix-20261025-120000.md" &&
        contains "$prompt" "The base ref is: origin/staging" && ! contains "$prompt" "## Review notes" &&
        ! contains "$prompt" "_codereview_gencr" && ! contains "$prompt" "bin/gencr"'
check "gencrclaude never runs Codex, bin/gencr or a gencr on PATH" eval '[ ! -e "$MOCK_OUT/tripwire" ]'
check "gencrclaude creates the developer's report directory, as before" eval '[ -d "$HOME/Documents/CodeReview/swalker" ]'

reset_mocks
CODEREVIEW_BASE_BRANCH=main run_fn "$TREE/dotfiles/zsh/codereview.zsh" "$TARGET" swalker
check "CODEREVIEW_BASE_BRANCH still selects the base ref" grep -qF "The base ref is: origin/main" "$MOCK_OUT/claude-prompt"

reset_mocks
run_fn "$TREE/dotfiles/zsh/codereview.zsh" "$TARGET"
check "without a dev-username: the original usage message, exit 1, no Claude" \
  eval '[ "$STATUS" -eq 1 ] && [ "$OUT" = "Usage: gencrclaude <dev-username>" ] && [ "$(calls)" -eq 0 ]'
run_fn "$TREE/dotfiles/zsh/codereview.zsh" "$TARGET" "bad/name"
check "an invalid dev-username is rejected as before, exit 1, no Claude" \
  eval '[ "$STATUS" -eq 1 ] && contains "$OUT" "dev-username may contain only letters, numbers, dots, underscores, and hyphens" && [ "$(calls)" -eq 0 ]'
run_fn "$TREE/dotfiles/zsh/codereview.zsh" "$NOT_GIT" swalker
check "outside a git repository: the original error, exit 1, no Claude" \
  eval '[ "$STATUS" -eq 1 ] && [ "$OUT" = "Error: not in a git repo" ] && [ "$(calls)" -eq 0 ]'
check "no run ever touched Codex or bin/gencr" eval '[ ! -e "$MOCK_OUT/tripwire" ]'

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
