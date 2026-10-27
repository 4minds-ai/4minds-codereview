#!/usr/bin/env bash
# Primary-reviewer authority and chronological adjudication (contract v2): unit tests of the position grammar and the
# claim ledger (tests/adjudication_unit.py), then end-to-end runs of bin/gencr with queued mock reviewer reports
# (tests/adjudication_e2e.py). Mock reviewer CLIs; no network. Usage: bash tests/test_gencr_adjudication.sh

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd -P "$(mktemp -d)" && pwd)/gencr adjudication tests"
mkdir -p "$WORK"
trap 'rm -rf "$(dirname "$WORK")"' EXIT

export REPO HOME="$WORK/home" MOCK_STATE="$WORK/mock state" TARGET="$WORK/target"
mkdir -p "$HOME"
MOCK_BIN="$WORK/mock bin"
mkdir -p "$MOCK_BIN"
cp "$REPO/tests/mocks/mock_reviewer.py" "$MOCK_BIN/mock_reviewer.py"
ln -s mock_reviewer.py "$MOCK_BIN/claude"
ln -s mock_reviewer.py "$MOCK_BIN/codex"
export PATH="$MOCK_BIN:$PATH" CODEREVIEW_BASE_BRANCH=staging
unset MOCK_VERDICT GENCR_REVIEW_COMMENT GITHUB_ACTIONS

git init -q --bare "$WORK/origin.git"
git init -q "$TARGET"
git -C "$TARGET" config user.email t@example.com
git -C "$TARGET" config user.name T
git -C "$TARGET" checkout -q -b staging
echo base > "$TARGET/base.txt"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm base
git -C "$TARGET" remote add origin "$WORK/origin.git"
git -C "$TARGET" push -q origin staging
git -C "$TARGET" fetch -q origin
git -C "$TARGET" checkout -q -b feature
printf 'def sync():\n    return 1\n' > "$TARGET/app.py"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm feature

status=0
python3 -B "$REPO/tests/adjudication_unit.py" "$REPO" || status=1
python3 -B "$REPO/tests/adjudication_e2e.py" || status=1
exit "$status"
