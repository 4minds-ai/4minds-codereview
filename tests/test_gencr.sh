#!/usr/bin/env bash
# Behavior tests for bin/gencr (macOS bash 3.2 and Linux bash 5). Runs entirely in a
# temporary HOME with mock claude/codex CLIs that record the argv, cwd, environment and stdin
# each invocation receives. No real reviewer, network or GitHub access.
# Usage: bash tests/test_gencr.sh
# shellcheck disable=SC2016,SC2012,SC2034,SC2088  # deferred eval checks; known-safe fixture paths; literal ~ on purpose

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd -P "$(mktemp -d)" && pwd)/gencr tests"
mkdir -p "$WORK"
trap 'chmod -R u+w "$(dirname "$WORK")" 2>/dev/null; rm -rf "$(dirname "$WORK")"' EXIT

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
not_ok() { FAIL=$((FAIL + 1)); echo "not ok - $1"; [ -z "$2" ] || printf '%s\n' "$2" | sed 's/^/    # /'; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else not_ok "$desc"; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
file_contains() { grep -qF -- "$2" "$1"; }
# Portable in-place edit (GNU and BSD sed differ): edit_in_place FILE SED-SCRIPT
edit_in_place() { sed "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
sha1() { python3 -c 'import hashlib,sys; [print(hashlib.sha1(open(p,"rb").read()).hexdigest(), p) for p in sys.argv[1:]]' "$@"; }
json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); exec("print(" + sys.argv[2] + ")")' "$1" "$2"; }

# ── Fixture: installed tree, HOME, target repository, mocks (all paths contain spaces) ──

TREE="$WORK/code review"
mkdir -p "$TREE"
cp -R "$REPO/bin" "$REPO/dotfiles" "$TREE/"
INSTR_SUMS_BEFORE="$(cd "$REPO/dotfiles/claude" && sha1 ./*.md)"

export HOME="$WORK/home dir"
mkdir -p "$HOME/bin" "$HOME/.claude"
ln -s "$TREE/bin/gencr" "$HOME/bin/gencr"
GENCR="$HOME/bin/gencr"

MOCK_BIN="$WORK/mock bin"
export MOCK_STATE="$WORK/mock state"
mkdir -p "$MOCK_BIN"
cp "$REPO/tests/mocks/mock_reviewer.py" "$MOCK_BIN/mock_reviewer.py"
ln -s mock_reviewer.py "$MOCK_BIN/claude"
ln -s mock_reviewer.py "$MOCK_BIN/codex"
cat > "$MOCK_BIN/gh" <<'MOCK'
#!/bin/sh
echo "gh $*" >> "$MOCK_STATE/gh-calls"
exit 1
MOCK
cat > "$MOCK_BIN/date" <<'MOCK'
#!/bin/sh
if [ "$1" = "+%Y%m%d-%H%M%S" ]; then echo "20261023-120000"; else exec /bin/date "$@"; fi
MOCK
chmod +x "$MOCK_BIN/gh" "$MOCK_BIN/date"
export PATH="$MOCK_BIN:$PATH"
unset CODEREVIEW_BASE_BRANCH MOCK_VERDICT

TARGET="$WORK/target repo"
git init -q --bare "$WORK/origin.git"
git init -q "$TARGET"
git -C "$TARGET" config user.email test@example.com
git -C "$TARGET" config user.name Test
git -C "$TARGET" checkout -q -b staging
echo base > "$TARGET/base.txt"
echo 'old name' > "$TARGET/rename me.txt"
echo 'delete me' > "$TARGET/doomed.txt"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm base
git -C "$TARGET" remote add origin "$WORK/origin.git"
git -C "$TARGET" push -q origin staging
git -C "$TARGET" checkout -q -b feature/login-fix
mkdir -p "$TARGET/src dir"
echo 'print("hi")' > "$TARGET/src dir/app file.py"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm "feature change"
NOT_GIT="$WORK/not a repo"
mkdir -p "$NOT_GIT"

reset_mocks() { rm -rf "$MOCK_STATE"; mkdir -p "$MOCK_STATE/responses"; }
calls() { cat "$MOCK_STATE/count" 2>/dev/null || echo 0; }
run_gencr() { (cd "$TARGET" && "$GENCR" "$@") > "$WORK/out" 2> "$WORK/err"; STATUS=$?; OUT="$(cat "$WORK/out")"; ERR="$(cat "$WORK/err")"; }
rid() { printf '%02d-round%d-%s-%s' "$1" "$2" "$3" "$4"; }
agent_title() { case "$1" in claude) echo Claude ;; codex) echo Codex ;; esac; }
reports_dir() { echo "$HOME/Documents/CodeReview/$1"; }
# The (newest) review package directory of a developer's runs.
pkg() { ls -td "$(reports_dir "$1")"/review-* 2>/dev/null | head -n 1; }
full_report() { echo "$(pkg "$1")/full-report.md"; }
arg_after() { grep -A1 -x -- "$2" "$MOCK_STATE/call-$1.args" | tail -n 1; }

# queue N AGENT VERDICT AGREEMENT PEER_REPORT [FINDING_NUMBER|none] [PEER_FINDING_NUMBER] — scripted reply to the
# Nth invocation (contract v2). Each reviewer defines finding <AGENT>-<FINDING_NUMBER> (default 1; "none": no finding
# of its own). Its row on the peer's finding (when the previous reply defines it): AGREEMENT YES accepts it with the
# author's exact facets (blocking only when this reply requests changes and the author lists it as a blocker);
# NO disputes it.
queue() {
  local n="$1" agent="$2" verdict="$3" agreement="$4" peer="$5" k="${6:-1}" up peer_up blockers disposition
  local pk="${7:-${6:-1}}" own previous peer_blocks
  [ "$pk" != none ] || pk=1
  up="$(echo "$agent" | tr '[:lower:]' '[:upper:]')"
  if [ "$up" = CLAUDE ]; then peer_up=CODEX; else peer_up=CLAUDE; fi
  blockers=""; [ "$verdict" = "REQUEST CHANGES" ] && [ "$k" != none ] && blockers="- ${up}-${k}"
  disposition="- None"
  previous="$MOCK_STATE/responses/$((n - 1))"
  if [ "$peer" != "N/A" ] && [ -f "$previous" ] && grep -q "^- \*\*${peer_up}-${pk} " "$previous"; then
    if [ "$agreement" = YES ]; then
      peer_blocks="$(sed -n '/^## Merge blockers$/,/^## /p' "$previous" | grep -c "^- ${peer_up}-${pk}$")"
      if [ "$peer_blocks" -gt 0 ] && [ "$verdict" = "REQUEST CHANGES" ]; then
        disposition="- ${peer_up}-${pk}: accepted; introduced: yes; severity: high; blocking: yes — verified"
        blockers="${blockers:+$blockers
}- ${peer_up}-${pk}"
      else
        disposition="- ${peer_up}-${pk}: accepted; introduced: yes; severity: high; blocking: no — verified"
      fi
    else
      disposition="- ${peer_up}-${pk}: disputed; introduced: yes; severity: high; blocking: no — see evidence"
    fi
  fi
  [ -n "$blockers" ] || blockers="- None"
  if [ "$k" = none ]; then own="- None"; else own="- **${up}-${k} Example finding (marker ${k})**
  - Severity: High"; fi
  cat > "$MOCK_STATE/responses/$n" <<EOF
Report body MARKER-${n} from ${agent}.

## Findings
${own}$( [ "$k" = none ] || printf '\n%s' "  - Introduced by this change: yes" "  - File: src dir/app file.py:1" \
  "  - Problem: example problem" "  - Evidence: example evidence" "  - Expected vs actual: expected x, actual y" \
  "  - Tests: none detect it" "  - Fix: example fix")

## Withdrawn findings
- None

## Disposition of peer findings
${disposition}

## Merge blockers
${blockers}

## Supplemental objections
- None

## Outstanding disputed findings
$( [ "$k" = none ] && echo "- None" || echo "- ${up}-${k}: DISPUTE-${n} raised by ${agent}")

## Review notes
- Verified clean: None
- Unresolved risks: None
- Disproven claims: None
- Test gaps: None
- Out-of-scope ownership changes: None
- Other observations: None

VERDICT: ${verdict}
PEER-AGREEMENT: ${agreement}
PEER-REPORT: ${peer}
EOF
}
# A single-reviewer reply: its peer sections are empty.
queue_single() { queue "$1" "$2" "$3" N/A N/A "${4:-1}"; }
# v2_reply N FINDINGS WITHDRAWN DISPOSITIONS BLOCKERS VERDICT AGREEMENT PEER_REPORT — a hand-written contract-v2 reply
# (each section's lines as given; "- None" for an empty section).
v2_reply() {
  cat > "$MOCK_STATE/responses/$1" <<REPLY
Scripted reply $1.

## Findings
$2

## Withdrawn findings
$3

## Disposition of peer findings
$4

## Merge blockers
$5

## Supplemental objections
- None

## Outstanding disputed findings
- None

## Review notes
- Verified clean: None
- Unresolved risks: None
- Disproven claims: None
- Test gaps: None
- Out-of-scope ownership changes: None
- Other observations: None

VERDICT: $6
PEER-AGREEMENT: $7
PEER-REPORT: $8
REPLY
}
# Adds a "## Previous findings verification" section: verify N "ID: status — evidence" ...
verify() {
  local n="$1" file line
  file="$MOCK_STATE/responses/$n"
  shift
  {
    sed '/^## Review notes$/,$d' "$file"
    echo "## Previous findings verification"
    for line in "$@"; do echo "- $line"; done
    echo
    sed -n '/^## Review notes$/,$p' "$file"
  } > "$file.new" && mv "$file.new" "$file"
}

# ── 1. The gencr command: a headless review by the new engine, Claude only by default ──

reset_mocks
queue_single 1 claude APPROVED
run_gencr plain
check "'gencr <dev>' runs one headless Claude review (no Codex) and exits 0 on APPROVED" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 1 ] && [ "$(cat "$MOCK_STATE/call-1.agent")" = claude ] && grep -qx -- -p "$MOCK_STATE/call-1.args" && [ ! -e "$MOCK_STATE/call-2.agent" ]'
check "'gencr <dev>' writes the new-engine package and prints the GitHub review comment" \
  eval '[ -f "$(pkg plain)/manifest.json" ] && [ "$(json_get "$(pkg plain)/metadata.json" "d[\"primary\"], d[\"adversary\"]")" = "claude None" ] &&
        contains "$OUT" "========== GITHUB REVIEW COMMENT ==========" && ! contains "$OUT$ERR" "new task: clear todos"'
check "'gencr <dev>' uses the structured report contract (the prompt requires Review notes)" \
  file_contains "$MOCK_STATE/call-1.stdin" '"## Review notes": the last section'
reset_mocks
queue_single 1 claude "REQUEST CHANGES"
run_gencr plain-rc
check "'gencr <dev>' exits 10 on REQUEST CHANGES (a completed review)" eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 1 ]'
reset_mocks
queue_single 1 claude APPROVED
edit_in_place "$MOCK_STATE/responses/1" '/^## Review notes/,/^- Other observations/d'
run_gencr plain-bad
check "'gencr <dev>' exits 20 INCOMPLETE on an invalid report" eval '[ "$STATUS" -eq 20 ] && [ "$(json_get "$(pkg plain-bad)/metadata.json" "d[\"outcome\"]")" = INCOMPLETE ]'
reset_mocks
actual="$(cd "$TARGET" && "$GENCR" 2>&1)"; status=$?
check "'gencr' without a dev-username is a usage error (exit 2), not the old prompt" \
  eval '[ "$status" -eq 2 ] && contains "$actual" "missing <dev-username>" && [ "$(calls)" -eq 0 ]'
actual="$(cd "$NOT_GIT" && "$GENCR" someone 2>&1)"; status=$?
check "'gencr <dev>' outside a git repository fails before any reviewer" eval '[ "$status" -ne 0 ] && [ "$(calls)" -eq 0 ]'
if command -v zsh >/dev/null 2>&1; then
  check "gencrnew is no longer defined by dotfiles/zsh/codereview.zsh" \
    eval '! zsh -fc '"'"'source "$1"; whence -w gencrnew'"'"' zsh "$REPO/dotfiles/zsh/codereview.zsh" >/dev/null 2>&1'
else
  not_ok "zsh is required for the shell-function checks"
fi

# ── 2. Argument parsing and version resolution ─────────────────────────────────

reset_mocks
actual="$(cd "$NOT_GIT" && "$GENCR" --help 2>&1)"; status=$?
check "--help exits 0 and prints usage, even outside a git repo" [ "$status" -eq 0 ]
check "--help documents the adversarial modes, models and scopes" \
  eval 'contains "$actual" "--codex=attack" && contains "$actual" "--claude-model" && contains "$actual" "--incremental"'

run_gencr dev1 --version=2 --print; long_out="$OUT"
check "--version=2 --print succeeds" [ "$STATUS" -eq 0 ]
check "--version=2 selects CODE_REVIEW_VERSION_2.md" contains "$OUT" "(version 2): \`$TREE/dotfiles/claude/CODE_REVIEW_VERSION_2.md\`"
run_gencr dev1 -v=2 --print
check "-v=2 produces the same prompt as --version=2" [ "$OUT" = "$long_out" ]
run_gencr dev1 --print
check "no version selects the default CODE_REVIEW.md" contains "$OUT" "(default): \`$TREE/dotfiles/claude/CODE_REVIEW.md\`"
check "--print launches nothing" [ "$(calls)" -eq 0 ]
check "--print creates no report directory" [ ! -e "$HOME/Documents/CodeReview/dev1" ]

for v in 3 1; do
  run_gencr dev1 --version=$v --codex=attack
  check "--version=$v (missing file) fails without substituting another version" \
    eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "CODE_REVIEW_VERSION_${v}.md not found" && [ "$(calls)" -eq 0 ]'
done

bad_args() { # description, then arguments
  local desc="$1"; shift
  reset_mocks
  run_gencr "$@"
  if [ "$STATUS" -eq 2 ] && [ -n "$ERR" ] && [ "$(calls)" -eq 0 ]; then ok "rejects $desc"; else not_ok "rejects $desc" "status=$STATUS err=$ERR"; fi
}
bad_args "non-numeric version" dev1 --version=abc
bad_args "empty version" dev1 --version=
bad_args "zero-padded version" dev1 --version=02
bad_args "-v without =" dev1 -v 2
bad_args "--version without =" dev1 --version 2
bad_args "repeated version" dev1 --version=2 -v=2
bad_args "unsupported codex mode" dev1 --codex=bogus
bad_args "unsupported claude mode" dev1 --claude=watch
bad_args "both primary" dev1 --codex=review --claude=review
bad_args "both adversarial" dev1 --codex=attack --claude=attack
bad_args "repeated reviewer flag" dev1 --codex=attack --codex=attack
bad_args "unknown option" dev1 --frobnicate
bad_args "extra positional argument" dev1 extra --version=2
bad_args "missing dev-username" --version=2
bad_args "dev-username with a path separator" ../evil --version=2
bad_args "empty --codex value" dev1 --codex=
bad_args "empty --claude value" dev1 --claude=
bad_args "empty first then valid duplicate --codex" dev1 --codex= --codex=review --print
bad_args "empty --codex with --print" dev1 --codex= --claude= --print
bad_args "--fresh with --incremental" dev1 --fresh --incremental
bad_args "repeated --fresh" dev1 --fresh --fresh
bad_args "--previous without --incremental" dev1 --previous=/tmp/x
bad_args "empty --claude-model" dev1 --claude-model=
bad_args "--claude-model without a value" dev1 --claude-model
bad_args "--codex-model followed by an option" dev1 --codex-model --print
bad_args "malformed --claude-model" dev1 '--claude-model=op us'
bad_args "--claude-model with shell characters" dev1 '--claude-model=opus;rm'
bad_args "--codex-model starting with a dash" dev1 --codex-model=-x
bad_args "repeated --claude-model" dev1 --claude-model=opus --claude-model opus
bad_args "repeated --codex-model" dev1 --codex-model=a --codex-model=b
bad_args "zero --reviewer-timeout" dev1 --reviewer-timeout=0
bad_args "non-numeric --pr-number" dev1 --pr-number=12a
bad_args "the removed --interactive option" dev1 --interactive
run_gencr dev1 --codex=bogus
check "invalid reviewer mode names the bad value" contains "$ERR" "unsupported reviewer mode 'bogus'"
run_gencr dev1 --codex=attack --claude=attack
check "contradictory assignment is explained" contains "$ERR" "contradictory reviewer assignment"

# ── 3. Headless single reviews ─────────────────────────────────────────────────

reset_mocks
queue_single 1 claude APPROVED
run_gencr headless1 --version=2
P="$(pkg headless1)"
check "a single-reviewer run is headless by default and exits 0 on APPROVED" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 1 ] && grep -qx -- -p "$MOCK_STATE/call-1.args"'
check "the single-reviewer package has every standard file and a manifest" \
  eval 'for f in summary.md full-report.md findings.json reconciliation.md metadata.json manifest.json; do [ -f "$P/$f" ] || exit 1; done'
check "single-reviewer header shows Codex Model: Not used" file_contains "$P/full-report.md" "- Codex Model: Not used"
check "single-reviewer header shows the actual Claude model" file_contains "$P/full-report.md" "- Claude Model: mock-claude-default"
check "single-reviewer metadata records Codex as not participating" \
  [ "$(json_get "$P/metadata.json" 'd["models"]["codex"]["participated"], d["models"]["codex"]["display"], d["adversary"]')" = "False Not used None" ]
reset_mocks
queue_single 1 codex "REQUEST CHANGES"
run_gencr headless2 --codex=review
check "a single Codex review runs codex exec and exits 10 on REQUEST CHANGES" \
  eval '[ "$STATUS" -eq 10 ] && [ "$(head -n 1 "$MOCK_STATE/call-1.args")" = exec ] && file_contains "$(full_report headless2)" "- Claude Model: Not used"'

# ── 4. Adversarial orchestration ───────────────────────────────────────────────

# 4a. Both approve at round 0: immediate completion.
reset_mocks
run_gencr a1 --version=2 --codex=attack --print; printed="$OUT"
check "adversarial --print launches nothing and writes nothing" eval '[ "$(calls)" -eq 0 ] && [ ! -e "$HOME/Documents/CodeReview/a1" ]'
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)" none
queue 3 claude APPROVED YES "$(rid 2 0 codex attack)"
run_gencr a1 --version=2 --codex=attack
check "adversarial --print shows exactly the prompt the first reviewer receives" [ "$printed" = "$(cat "$MOCK_STATE/call-1.stdin")" ]
check "both APPROVED: stops after the two initial reviews" eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 2 ]'
check "both APPROVED: final verdict APPROVED, 0 rounds" \
  eval 'file_contains "$(full_report a1)" "- Final Verdict: APPROVED" && file_contains "$(full_report a1)" "- Reconciliation Rounds: 0 (maximum 3)"'
check "Claude-first: Claude is invoked first, non-interactively" eval '[ "$(cat "$MOCK_STATE/call-1.agent")" = claude ] && grep -qx -- -p "$MOCK_STATE/call-1.args"'
check "Claude-first: Codex is invoked second, via codex exec" eval '[ "$(cat "$MOCK_STATE/call-2.agent")" = codex ] && [ "$(head -n 1 "$MOCK_STATE/call-2.args")" = exec ]'

shared="$(pkg a1)/00-shared-prompt.md"
for n in 1 2; do
  check "invocation $n receives the complete shared prompt verbatim" \
    eval '[ "$(head -c "$(wc -c < "$shared")" "$MOCK_STATE/call-$n.stdin")" = "$(cat "$shared")" ]'
  check "invocation $n receives the full version 2 instructions" \
    eval 'grep -qF "# Adversarial Review Protocol (Required for High-Risk Changes)" "$MOCK_STATE/call-$n.stdin" && grep -qF "## Severity and exit criteria" "$MOCK_STATE/call-$n.stdin"'
  check "invocation $n runs in the reviewed repository" [ "$(cat "$MOCK_STATE/call-$n.cwd")" = "$TARGET" ]
done
check "both reviewers receive identical review standards" \
  eval '[ "$(sed -n "/^===== BEGIN REVIEW INSTRUCTIONS/,/^===== END REVIEW INSTRUCTIONS/p" "$MOCK_STATE/call-1.stdin")" = "$(sed -n "/^===== BEGIN REVIEW INSTRUCTIONS/,/^===== END REVIEW INSTRUCTIONS/p" "$MOCK_STATE/call-2.stdin")" ]'
check "shared prompt names the review scope file list" file_contains "$shared" "  - A src dir/app file.py"
check "Claude is told it is the primary reviewer" file_contains "$MOCK_STATE/call-1.stdin" "- You are: Claude, the primary reviewer"
check "Codex is told it is the adversarial reviewer" file_contains "$MOCK_STATE/call-2.stdin" "- You are: Codex, the adversarial reviewer"
check "Codex's handoff includes Claude's complete findings" file_contains "$MOCK_STATE/call-2.stdin" "Report body MARKER-1 from claude."
check "Codex's handoff names the report to answer" file_contains "$MOCK_STATE/call-2.stdin" "- Report to respond to: $(rid 1 0 claude initial)"
check "Claude runs restricted and safe-mode with file tools only, no shell, no permission bypass" \
  eval 'grep -qx -- --restricted "$MOCK_STATE/call-1.args" && grep -qx -- --safe-mode "$MOCK_STATE/call-1.args" && [ "$(arg_after 1 --tools)" = "Read,Grep,Glob" ] && [ "$(arg_after 1 --allowedTools)" = "Read,Grep,Glob" ] && grep -qx "Bash,Edit,Write,NotebookEdit" "$MOCK_STATE/call-1.args" && grep -qx dontAsk "$MOCK_STATE/call-1.args" && ! grep -qi bypass "$MOCK_STATE/call-1.args"'
check "both reviewers receive the scoped diff computed by gencr" \
  eval 'grep -qF "+print(\"hi\")" "$MOCK_STATE/call-1.stdin" && grep -qF "+print(\"hi\")" "$MOCK_STATE/call-2.stdin" && grep -qF "===== BEGIN SCOPED DIFF" "$shared"'
check "Codex is pointed at the reviewed repository root" [ "$(arg_after 2 --cd)" = "$TARGET" ]
check "Codex runs in the read-only sandbox and ignores repository AGENTS.md" \
  eval '[ "$(arg_after 2 --sandbox)" = read-only ] && grep -qx "project_doc_max_bytes=0" "$MOCK_STATE/call-2.args"'
check "no model flag is passed when none was requested" eval '! grep -qx -- --model "$MOCK_STATE/call-1.args" && ! grep -qx -- --model "$MOCK_STATE/call-2.args"'

# 4b. Both request changes with aligned findings at round 0.
reset_mocks
queue 1 claude "REQUEST CHANGES" N/A N/A
queue 2 codex "REQUEST CHANGES" YES "$(rid 1 0 claude initial)" none
run_gencr a2 --codex=attack
check "both REQUEST CHANGES, every position agrees: stops after two calls, exit 10" \
  eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 2 ] && file_contains "$(full_report a2)" "- Final Verdict: REQUEST CHANGES" && file_contains "$(full_report a2)" "every explicit position agree"'

# 4c. Different findings: reconciliation begins; agreement in round 1.
reset_mocks
queue 1 claude "REQUEST CHANGES" N/A N/A
queue 2 codex "REQUEST CHANGES" YES "$(rid 1 0 claude initial)"
queue 3 claude "REQUEST CHANGES" YES "$(rid 2 0 codex attack)"
run_gencr a3 --codex=attack
check "a new attacker finding: the primary must answer it; agreement in round 1 stops the review" \
  eval '[ "$(calls)" -eq 3 ] && file_contains "$(full_report a3)" "- Reconciliation Rounds: 1 (maximum 3)"'
check "round 1 handoff tells Claude to answer Codex's report and keeps the disputes" \
  eval 'file_contains "$MOCK_STATE/call-3.stdin" "- Report to respond to: $(rid 2 0 codex attack)" && file_contains "$MOCK_STATE/call-3.stdin" "DISPUTE-2 raised by codex"'

# 4d. Conflicting verdicts; agreement in round 2.
reset_mocks
queue 1 claude APPROVED N/A N/A
queue 2 codex "REQUEST CHANGES" NO "$(rid 1 0 claude initial)"
queue 3 claude APPROVED NO "$(rid 2 0 codex attack)"
queue 4 codex "REQUEST CHANGES" NO "$(rid 3 1 claude reconcile)"
queue 5 claude APPROVED NO "$(rid 4 1 codex respond)"
queue 6 codex APPROVED YES "$(rid 5 1 claude reconcile)"
queue 7 claude APPROVED YES "$(rid 6 2 codex respond)"
run_gencr a4 --codex=attack
check "conflicting verdicts reconcile until the primary's round-2 response agrees with every position" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 7 ] && file_contains "$(full_report a4)" "- Final Verdict: APPROVED" && file_contains "$(full_report a4)" "- Reconciliation Rounds: 2 (maximum 3)"'

# 4e/4f. Disagreement through round 3, both starting orders; models stay bound to agents.
limit_run() { # dev primary adversary options...
  local dev="$1" p="$2" a="$3"; shift 3
  reset_mocks
  queue 1 "$p" APPROVED N/A N/A
  queue 2 "$a" "REQUEST CHANGES" NO "$(rid 1 0 "$p" initial)"
  queue 3 "$p" APPROVED NO "$(rid 2 0 "$a" attack)"
  queue 4 "$a" "REQUEST CHANGES" NO "$(rid 3 1 "$p" reconcile)"
  queue 5 "$p" APPROVED NO "$(rid 4 1 "$a" respond)"
  queue 6 "$a" "REQUEST CHANGES" NO "$(rid 5 1 "$p" reconcile)"
  queue 7 "$p" APPROVED NO "$(rid 6 2 "$a" respond)"
  queue 8 "$a" "REQUEST CHANGES" NO "$(rid 7 2 "$p" reconcile)"
  queue 9 "$p" APPROVED NO "$(rid 8 3 "$a" respond)"
  queue 10 "$a" "REQUEST CHANGES" NO "$(rid 9 3 "$p" reconcile)"
  [ -z "$LIMIT_HOOK" ] || eval "$LIMIT_HOOK"
  run_gencr "$dev" "$@"
}
LIMIT_HOOK=""
for order in "claude codex --version=2 --codex=attack" "codex claude --version=2 --codex=review --claude=attack"; do
  # shellcheck disable=SC2086
  set -- $order
  p="$1" a="$2" dev="limit-$1"
  shift 2
  limit_run "$dev" "$p" "$a" "$@" --claude-model=claude-x --codex-model codex-y
  agents="$(for n in 1 2 3 4 5 6 7 8 9; do cat "$MOCK_STATE/call-$n.agent" 2>/dev/null; done | tr '\n' ' ')"
  check "$p-first: exactly 9 invocations, no fourth round; the primary's APPROVED applies (exit 0)" eval '[ "$(calls)" -eq 9 ] && [ "$STATUS" -eq 0 ]'
  check "$p-first: invocation order alternates, primary evaluates last" [ "$agents" = "$p $a $p $a $p $a $p $a $p " ]
  rounds="$(for n in 1 2 3 4 5 6 7 8 9; do sed -n "s/^- Current reconciliation round: \([0-9]*\).*/\1/p" "$MOCK_STATE/call-$n.stdin"; done | tr '\n' ' ')"
  check "$p-first: round counter is never reset across handoffs" [ "$rounds" = "0 0 1 1 1 2 2 3 3 " ]
  check "$p-first: no invocation mentions a fourth round" eval '! grep -l "^- Current reconciliation round: 4" "$MOCK_STATE"/call-*.stdin >/dev/null 2>&1'
  check "$p-first: every handoff states the 3-round maximum" \
    eval '[ "$(grep -l "^- Maximum permitted reconciliation rounds: 3" "$MOCK_STATE"/call-*.stdin | wc -l | tr -d " ")" -eq 9 ]'
  check "$p-first: round 3 handoffs announce the last round" eval 'file_contains "$MOCK_STATE/call-9.stdin" "This is the last permitted reconciliation round"'
  check "$p-first: the last primary call evaluates the adversary's round 3 report" \
    file_contains "$MOCK_STATE/call-9.stdin" "- Report to respond to: $(rid 8 3 "$a" respond)"
  check "$p-first: later rounds still carry the complete original instructions and every prior report" \
    eval '[ "$(head -c "$(wc -c < "$(pkg "$dev")/00-shared-prompt.md")" "$MOCK_STATE/call-9.stdin")" = "$(cat "$(pkg "$dev")/00-shared-prompt.md")" ] && file_contains "$MOCK_STATE/call-9.stdin" "Report body MARKER-1 from" && file_contains "$MOCK_STATE/call-9.stdin" "Report body MARKER-8 from"'
  check "$p-first: role stays correct in round 3" \
    eval 'file_contains "$MOCK_STATE/call-8.stdin" "- You are: $(agent_title "$a"), the adversarial reviewer" && file_contains "$MOCK_STATE/call-9.stdin" "- You are: $(agent_title "$p"), the primary reviewer"'
  bound=1
  for n in 1 2 3 4 5 6 7 8 9; do
    case "$(cat "$MOCK_STATE/call-$n.agent")" in
      claude) [ "$(arg_after "$n" --model)" = claude-x ] || bound=0 ;;
      codex) [ "$(arg_after "$n" --model)" = codex-y ] || bound=0 ;;
    esac
  done
  check "$p-first: each agent receives its own model on every one of its invocations" [ "$bound" -eq 1 ]
  report="$(full_report "$dev")"
  check "$p-first: header shows both requested models" \
    eval 'file_contains "$report" "- Claude Model: claude-x" && file_contains "$report" "- Codex Model: codex-y"'
  check "$p-first: limit report is the primary's APPROVED, never unanimous, never UNRESOLVED DISAGREEMENT" \
    eval 'file_contains "$report" "- Final Verdict: APPROVED" && file_contains "$report" "APPROVED by primary reviewer — NOT UNANIMOUS" && ! file_contains "$report" "UNRESOLVED DISAGREEMENT"'
  check "$p-first: limit report records the round limit" file_contains "$report" "reconciliation limit reached (3 of 3 rounds)"
  check "$p-first: limit report preserves both reviewers' disputed and blocking findings" \
    eval 'file_contains "$report" "DISPUTE-9 raised by $p" && file_contains "$report" "DISPUTE-8 raised by $a" && file_contains "$report" "- $(echo "$a" | tr a-z A-Z)-1"'
done

reset_mocks
queue 1 codex "REQUEST CHANGES" N/A N/A
queue 2 claude "REQUEST CHANGES" NO "$(rid 1 0 codex initial)"
queue 3 codex "REQUEST CHANGES" NO "$(rid 2 0 claude attack)"
queue 4 claude "REQUEST CHANGES" NO "$(rid 3 1 codex reconcile)"
queue 5 codex "REQUEST CHANGES" NO "$(rid 4 1 claude respond)"
queue 6 claude "REQUEST CHANGES" NO "$(rid 5 1 codex reconcile)"
queue 7 codex "REQUEST CHANGES" NO "$(rid 6 2 claude respond)"
queue 8 claude "REQUEST CHANGES" NO "$(rid 7 2 codex reconcile)"
queue 9 codex "REQUEST CHANGES" NO "$(rid 8 3 claude respond)"
run_gencr limit-rc --claude=attack
check "both REQUEST CHANGES but still disputed after round 3: REQUEST CHANGES, limit reached" \
  eval '[ "$(calls)" -eq 9 ] && file_contains "$(full_report limit-rc)" "- Final Verdict: REQUEST CHANGES" && file_contains "$(full_report limit-rc)" "reconciliation limit reached"'

# 4g. Failures are explicit, classified, and never fall back to a single reviewer.
failure_case() { # description, error text, expected exit, then setup commands run after queueing
  local desc="$1" expect="$2" code="$3" dev="fail$((PASS + FAIL))"
  shift 3
  reset_mocks
  queue 1 claude APPROVED N/A N/A
  queue 2 codex APPROVED YES "$(rid 1 0 claude initial)"
  "$@"
  run_gencr "$dev" --codex=attack
  if [ "$STATUS" -eq "$code" ] && contains "$ERR" "$expect" && [ "$(calls)" -le 2 ] \
      && [ "$(json_get "$(pkg "$dev")/metadata.json" 'd["category"]')" = infrastructure ]; then
    ok "$desc"
  else
    not_ok "$desc" "status=$STATUS calls=$(calls) err=$ERR"
  fi
}
codex_fails() { echo 3 > "$MOCK_STATE/exit-2"; }
codex_empty() { : > "$MOCK_STATE/responses/2"; }
codex_no_trailer() { edit_in_place "$MOCK_STATE/responses/2" '/^PEER-REPORT:/d'; }
codex_wrong_peer() { edit_in_place "$MOCK_STATE/responses/2" 's/^PEER-REPORT: .*/PEER-REPORT: 99-round0-claude-initial/'; }
codex_quoted_verdict() { printf 'VERDICT: REQUEST CHANGES\n%s\n' "$(cat "$MOCK_STATE/responses/2")" > "$MOCK_STATE/responses/2"; }
codex_approves_with_blocker() { edit_in_place "$MOCK_STATE/responses/2" 's/^- None$/- CODEX-1/'; }
codex_rc_without_blocker() { edit_in_place "$MOCK_STATE/responses/2" 's/^VERDICT: APPROVED/VERDICT: REQUEST CHANGES/'; }
codex_missing_section() { edit_in_place "$MOCK_STATE/responses/2" '/^## Disposition of peer findings/d'; }
codex_bold_verdict() { edit_in_place "$MOCK_STATE/responses/2" 's/^VERDICT: APPROVED/**VERDICT: APPROVED**/'; }
codex_ghost_blocker() {
  python3 - "$MOCK_STATE/responses/2" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r"## Findings\n(.*?)\n\n## ", "## Findings\n- None\n\n## ", s, flags=re.S)
s = s.replace("## Merge blockers\n- None", "## Merge blockers\n- GHOST-NOT-A-FINDING").replace("VERDICT: APPROVED", "VERDICT: REQUEST CHANGES")
open(p, "w").write(s)
EOF
}
codex_undefined_blocker() { edit_in_place "$MOCK_STATE/responses/2" 's/^- None$/- CODEX-7/; s/^VERDICT: APPROVED/VERDICT: REQUEST CHANGES/'; }
codex_missing_field() { edit_in_place "$MOCK_STATE/responses/2" '/^  - Evidence:/d'; }
codex_peer_prefix() { edit_in_place "$MOCK_STATE/responses/2" 's/^- \*\*CODEX-1 /- **CLAUDE-9 /'; }
codex_no_disposition() { edit_in_place "$MOCK_STATE/responses/2" 's/^- CLAUDE-1: accepted; .*$/- None/'; }
codex_untagged_finding() { edit_in_place "$MOCK_STATE/responses/2" 's/^- \*\*CODEX-1 Example/- Example/'; }
codex_blank_field() { edit_in_place "$MOCK_STATE/responses/2" 's/^  - Evidence: .*/  - Evidence:/'; }
codex_space_field() { edit_in_place "$MOCK_STATE/responses/2" 's/^  - File: .*/  - File:    /'; }
codex_bare_disposition() { edit_in_place "$MOCK_STATE/responses/2" 's/^- CLAUDE-1: accepted; .*$/- CLAUDE-1/'; }
codex_no_rationale() { edit_in_place "$MOCK_STATE/responses/2" 's/^- CLAUDE-1: accepted; .*$/- CLAUDE-1: accepted/'; }
codex_no_facets() { edit_in_place "$MOCK_STATE/responses/2" 's/^- CLAUDE-1: accepted; .*$/- CLAUDE-1: accepted — verified/'; }
claude_is_error() { touch "$MOCK_STATE/error-1"; }
failure_case "a failed Codex launch is reported, not skipped (exit 21)" "Codex exited with status 3" 21 codex_fails
failure_case "an empty Codex report is rejected (exit 21)" "Codex returned an empty report" 21 codex_empty
failure_case "a Claude is_error result is a reviewer failure (exit 21)" "Claude reported an error" 21 claude_is_error
failure_case "a missing control line is rejected (exit 20)" "expected exactly one PEER-REPORT: line" 20 codex_no_trailer
failure_case "a response to the wrong report is rejected" "PEER-REPORT must be $(rid 1 0 claude initial)" 20 codex_wrong_peer
failure_case "a second VERDICT line is rejected" "expected exactly one VERDICT: line, found 2" 20 codex_quoted_verdict
failure_case "APPROVED with merge blockers is rejected" "APPROVED with merge blockers listed" 20 codex_approves_with_blocker
failure_case "REQUEST CHANGES without blockers is rejected" "REQUEST CHANGES without any merge blocker" 20 codex_rc_without_blocker
failure_case "a missing required section is rejected" "missing required section '## Disposition of peer findings'" 20 codex_missing_section
failure_case "a decorated verdict line is rejected" "expected exactly one VERDICT: line, found 0" 20 codex_bold_verdict
failure_case "a ghost merge blocker with no findings is rejected" "each merge blocker must start with a finding ID" 20 codex_ghost_blocker
failure_case "a merge blocker ID that no report defines is rejected" "merge blocker CODEX-7 is not a finding defined in this review" 20 codex_undefined_blocker
failure_case "a finding without its Evidence field is rejected" "finding CODEX-1 is missing the field(s): Evidence" 20 codex_missing_field
failure_case "a finding defined with the other reviewer's prefix is rejected" "each finding must start with a bold CODEX-<n> ID" 20 codex_peer_prefix
failure_case "a report that skips a peer finding's disposition is rejected" "has no row for CLAUDE-1" 20 codex_no_disposition
failure_case "a finding without an ID is rejected" "each finding must start with a bold CODEX-<n> ID" 20 codex_untagged_finding
failure_case "a finding with an empty Evidence value is rejected" "finding CODEX-1 has an empty Evidence field" 20 codex_blank_field
failure_case "a finding with a whitespace-only File value is rejected" "finding CODEX-1 has an empty File field" 20 codex_space_field
failure_case "a bare peer ID without a disposition is rejected" "is not a valid entry: - CLAUDE-1" 20 codex_bare_disposition
failure_case "a disposition without facets or supporting evidence is rejected" "every facet is required" 20 codex_no_rationale
failure_case "a contract-v1 row (status and evidence, no facets) is rejected in contract v2" "every facet is required" 20 codex_no_facets

reset_mocks
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)"
echo 30 > "$MOCK_STATE/sleep-2"
started=$(date +%s)
run_gencr timeout1 --codex=attack --reviewer-timeout=2
elapsed=$(( $(date +%s) - started ))
check "a reviewer exceeding --reviewer-timeout is stopped: exit 22, TIMEOUT outcome" \
  eval '[ "$STATUS" -eq 22 ] && [ "$elapsed" -lt 20 ] && [ "$(json_get "$(pkg timeout1)/metadata.json" "d[\"outcome\"]")" = TIMEOUT ] && contains "$ERR" "timed out after 2 seconds"'

reset_mocks
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)"
echo 1 > "$MOCK_STATE/exit-1"
run_gencr failclaude --codex=attack
check "a failed primary launch stops before the adversary is invoked" \
  eval '[ "$STATUS" -eq 21 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "Claude exited with status 1"'
reset_mocks
echo 1 > "$MOCK_STATE/exit-1"
run_gencr failmodel --claude-model=no-such-model
check "a model-selection failure is reported with the requested model, without fallback" \
  eval '[ "$STATUS" -eq 21 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "requested model: no-such-model"'

reset_mocks
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)"
echo 'rm -f "$HOME"/Documents/CodeReview/noshared/review-*/00-shared-prompt.md' > "$MOCK_STATE/hook-1"
run_gencr noshared --codex=attack
check "a missing shared prompt stops before Codex is launched" \
  eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "Codex was not launched" && file_contains "$(full_report noshared)" "- Final Verdict: INCOMPLETE"'
reset_mocks
queue 1 claude APPROVED N/A N/A
queue 2 codex "REQUEST CHANGES" NO "$(rid 1 0 claude initial)"
printf 'rm -f "$HOME"/Documents/CodeReview/noprior/review-*/%s.report.md\n' "$(rid 1 0 claude initial)" > "$MOCK_STATE/hook-2"
run_gencr noprior --codex=attack
check "a missing prior report stops before the next reviewer is launched (the reply answering it cannot be checked)" \
  eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 2 ] && contains "$ERR" "cannot check the dispositions: missing report" && ! contains "$ERR" "final verdict:"'

reset_mocks
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)"
echo 'echo moved >> "$PWD/src dir/app file.py"' > "$MOCK_STATE/hook-2"
run_gencr moved --codex=attack
check "a working tree that changes during the review makes it INCOMPLETE" \
  eval '[ "$STATUS" -eq 20 ] && contains "$ERR" "the repository changed during the review"'
git -C "$TARGET" checkout -q -- .

reset_mocks
echo 'x' >> "$TARGET/src dir/app file.py"
run_gencr dirty --codex=attack
check "uncommitted tracked changes are refused before any reviewer runs" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "uncommitted changes" && [ "$(calls)" -eq 0 ]'
git -C "$TARGET" checkout -q -- .

# 4h. Prompt content is passed literally (no shell evaluation), including spaces in paths.
reset_mocks
cat > "$TREE/dotfiles/claude/CODE_REVIEW_VERSION_9.md" <<'EOF'
Literal check: $(touch "$HOME/pwned") `touch "$HOME/pwned2"` ${HOME} "quotes" 'single'
EOF
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)"
run_gencr literal -v=9 --codex=attack
check "instruction text with \$(...), backticks and quotes reaches both CLIs verbatim" \
  eval 'grep -qxF -f "$TREE/dotfiles/claude/CODE_REVIEW_VERSION_9.md" "$MOCK_STATE/call-1.stdin" && grep -qxF -f "$TREE/dotfiles/claude/CODE_REVIEW_VERSION_9.md" "$MOCK_STATE/call-2.stdin"'
check "instruction text is never executed" eval '[ ! -e "$HOME/pwned" ] && [ ! -e "$HOME/pwned2" ]'
rm -f "$TREE/dotfiles/claude/CODE_REVIEW_VERSION_9.md"

reset_mocks
CODEREVIEW_BASE_BRANCH=nope run_gencr nobase --codex=attack
check "missing origin base ref fails clearly" eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "base ref origin/nope not found" && [ "$(calls)" -eq 0 ]'

# ── 5. Fresh scope: the complete PR difference ─────────────────────────────────

git -C "$TARGET" checkout -q -b side staging
echo 'side branch defect' > "$TARGET/side.txt"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm "side work"
git -C "$TARGET" checkout -q feature/login-fix
git -C "$TARGET" merge -q --no-ff -m "merge side" side
git -C "$TARGET" mv "rename me.txt" "renamed.txt"
git -C "$TARGET" rm -q doomed.txt
git -C "$TARGET" commit -qm "rename and delete"
git -C "$TARGET" checkout -q staging
echo 'base moved' > "$TARGET/base-only.txt"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm "base advances"
git -C "$TARGET" push -q origin staging
git -C "$TARGET" checkout -q feature/login-fix
reset_mocks
run_gencr scope --codex=attack --print
check "fresh scope includes a file brought in by merging a side branch" \
  eval 'contains "$OUT" "  - A side.txt" && contains "$OUT" "+side branch defect"'
check "fresh scope shows renames and deletions" \
  eval 'contains "$OUT" "  - R rename me.txt -> renamed.txt" && contains "$OUT" "  - D doomed.txt" && contains "$OUT" "-delete me"'
check "fresh scope uses the merge-base, not the advanced base tip" \
  eval '! contains "$OUT" "base-only.txt" && contains "$OUT" "the merge-base $(git -C "$TARGET" merge-base origin/staging HEAD)"'
check "the FRESH contract replaces the strict first-parent rule in headless prompts" \
  eval 'contains "$OUT" "Review mode: FRESH" && ! contains "$OUT" "Strict scope rule:" && contains "$OUT" "callers, consumers and execution paths"'

# Unusual file names are diffed under their real names; newline names are rejected.
printf 'quoted-name-change\n' > "$TARGET/quote\"na\\me.txt"
printf 'tab-name-change\n' > "$TARGET/tab	name.txt"
git -C "$TARGET" add -A && git -C "$TARGET" commit -qm "unusual names"
run_gencr quoted --codex=attack --print
check "files with quotes, backslashes and tabs keep their diff in the prompt" \
  eval '[ "$STATUS" -eq 0 ] && contains "$OUT" "+quoted-name-change" && contains "$OUT" "+tab-name-change" && contains "$OUT" "  - A quote\"na\\me.txt"'
git -C "$TARGET" reset -q --hard HEAD~1
printf 'x\n' > "$TARGET/new
line.txt"
git -C "$TARGET" add -A && git -C "$TARGET" commit -qm "newline name"
run_gencr newline --codex=attack --print
check "a file name containing a newline is rejected explicitly" \
  eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "unsupported file name containing a newline" && [ "$(calls)" -eq 0 ]'
git -C "$TARGET" reset -q --hard HEAD~1

# External diff and textconv helpers configured in the reviewed repository never run.
reset_mocks
cat > "$WORK/evil-helper" <<EOF
#!/bin/sh
touch "$WORK/helper-ran"
EOF
chmod +x "$WORK/evil-helper"
git -C "$TARGET" config diff.external "$WORK/evil-helper"
git -C "$TARGET" config diff.evil.textconv "$WORK/evil-helper"
echo '*.py diff=evil' > "$TARGET/.git/info/attributes"
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)"
run_gencr helpers --codex=attack
check "external diff and textconv helpers are never executed" eval '[ "$STATUS" -eq 0 ] && [ ! -e "$WORK/helper-ran" ] && grep -qF "+print(\"hi\")" "$MOCK_STATE/call-1.stdin"'
git -C "$TARGET" config --unset diff.external
git -C "$TARGET" config --unset diff.evil.textconv
rm -f "$TARGET/.git/info/attributes"

# ── 6. Incremental reviews ─────────────────────────────────────────────────────

INC_DIR="$WORK/inc reports"
reset_mocks
queue 1 claude "REQUEST CHANGES" N/A N/A
queue 2 codex "REQUEST CHANGES" YES "$(rid 1 0 claude initial)"
queue 3 claude "REQUEST CHANGES" YES "$(rid 2 0 codex attack)"
run_gencr inc --codex=attack --output-dir="$INC_DIR" --pr-number=42
FRESH_PKG="$(ls -d "$INC_DIR"/review-*)"
FRESH_ID="$(json_get "$FRESH_PKG/metadata.json" 'd["run_id"]')"
FRESH_SHA="$(git -C "$TARGET" rev-parse HEAD)"
check "--output-dir receives the package; nothing in the default directory" \
  eval '[ "$STATUS" -eq 10 ] && [ -f "$FRESH_PKG/manifest.json" ] && [ ! -e "$(reports_dir inc)" ]'

echo 'print("fixed")' > "$TARGET/src dir/app file.py"
git -C "$TARGET" commit -qam "fix CLAUDE-1"
reset_mocks
queue 1 codex APPROVED N/A N/A 2
verify 1 "CLAUDE-1: fixed — the print call was corrected" "CODEX-1: fixed — no longer applies"
queue 2 claude APPROVED YES "$(rid 1 0 codex initial)" 2
verify 2 "CLAUDE-1: fixed — confirmed" "CODEX-1: fixed — confirmed"
run_gencr inc --codex=review --claude=attack --incremental --output-dir="$INC_DIR" --pr-number=42
INC_PKG="$(ls -td "$INC_DIR"/review-* | head -n 1)"
check "incremental review succeeds against the validated previous package (exit 0)" eval '[ "$STATUS" -eq 0 ] && [ "$INC_PKG" != "$FRESH_PKG" ]'
check "incremental prompt names the previous review, its SHA and the open findings" \
  eval 'file_contains "$MOCK_STATE/call-1.stdin" "follow-up to review $FRESH_ID, which reviewed $FRESH_SHA" && file_contains "$MOCK_STATE/call-1.stdin" "verify each one): CLAUDE-1 CODEX-1"'
check "incremental prompt embeds the previous full report and only the new diff" \
  eval 'file_contains "$MOCK_STATE/call-1.stdin" "===== BEGIN PREVIOUS REVIEW $FRESH_ID" && file_contains "$MOCK_STATE/call-1.stdin" "+print(\"fixed\")" && ! file_contains "$MOCK_STATE/call-1.stdin" "+side branch defect"'
for f in summary.md full-report.md; do
  check "INCREMENTAL header with previous ID and SHA in $f" \
    eval 'file_contains "$INC_PKG/$f" "- Review Mode: INCREMENTAL" && file_contains "$INC_PKG/$f" "- Previous Review ID: $FRESH_ID" && file_contains "$INC_PKG/$f" "- Previous Reviewed SHA: $FRESH_SHA" && file_contains "$INC_PKG/$f" "not a full PR approval"'
done
check "incremental metadata records mode, scope and previous review" \
  [ "$(json_get "$INC_PKG/metadata.json" 'd["review_mode"], d["approval_scope"], d["previous_review"]["id"] == "'"$FRESH_ID"'", d["previous_review"]["reviewed_sha"] == "'"$FRESH_SHA"'"')" = "INCREMENTAL incremental True True" ]

# Verification contract.
inc_failure() { # description, expected error, setup...
  local desc="$1" expect="$2"
  shift 2
  reset_mocks
  queue 1 codex APPROVED N/A N/A 2
  verify 1 "CLAUDE-1: fixed — ok" "CODEX-1: fixed — ok"
  "$@"
  run_gencr inc --codex=review --claude=attack --incremental --output-dir="$INC_DIR" --pr-number=42 --previous="$FRESH_PKG"
  if [ "$STATUS" -eq 20 ] && contains "$ERR" "$expect"; then ok "$desc"; else not_ok "$desc" "status=$STATUS err=$ERR"; fi
}
drop_verification_line() { edit_in_place "$MOCK_STATE/responses/1" '/^- CODEX-1: fixed/d'; }
not_fixed_not_carried() { edit_in_place "$MOCK_STATE/responses/1" 's/^- CODEX-1: fixed — ok/- CODEX-1: not fixed — still broken/'; }
reuse_previous_id() { edit_in_place "$MOCK_STATE/responses/1" 's/^- \*\*CODEX-2 Example/- **CODEX-1 Brand new/'; }
drop_section() { edit_in_place "$MOCK_STATE/responses/1" '/^## Previous findings verification/d'; }
inc_failure "a report that skips a previous finding is rejected" "has no '- CODEX-1: fixed|not fixed|obsolete" drop_verification_line
inc_failure "an unfixed previous finding must be carried forward" "previous finding CODEX-1 is not fixed but is missing" not_fixed_not_carried
inc_failure "a previous finding ID cannot be reused for a new finding" "reuses a previous finding ID" reuse_previous_id
inc_failure "the verification section is mandatory" "missing required section '## Previous findings verification'" drop_section

reset_mocks
cat > "$MOCK_STATE/responses/1" <<'EOF'
Codex carries Claude's finding.

## Findings
- **CLAUDE-1 Example finding still present**
  - Severity: High
  - Introduced by this change: yes
  - File: src dir/app file.py:1
  - Problem: still broken
  - Evidence: line 1
  - Expected vs actual: x vs y
  - Tests: none
  - Fix: fix it

## Withdrawn findings
- None

## Disposition of peer findings
- None

## Merge blockers
- CLAUDE-1

## Supplemental objections
- None

## Outstanding disputed findings
- None

## Previous findings verification
- CLAUDE-1: not fixed — the defect remains
- CODEX-1: obsolete — code removed

## Review notes
- Verified clean: None
- Unresolved risks: None
- Disproven claims: None
- Test gaps: None
- Out-of-scope ownership changes: None
- Other observations: None

VERDICT: REQUEST CHANGES
PEER-AGREEMENT: N/A
PEER-REPORT: N/A
EOF
run_gencr inc --codex=review --incremental --output-dir="$INC_DIR" --pr-number=42 --previous="$FRESH_PKG"
CARRY_PKG="$(ls -td "$INC_DIR"/review-* | head -n 1)"
check "a reviewer may carry the other reviewer's unfixed finding under its original ID" \
  eval '[ "$STATUS" -eq 10 ] && [ "$(json_get "$CARRY_PKG/findings.json" "[f[\"id\"] for f in d[\"final_findings\"]]")" = "['"'"'CLAUDE-1'"'"']" ]'

# Baseline validation fails closed.
inc_reject() { # description, expected error, then gencr arguments
  local desc="$1" expect="$2"
  shift 2
  reset_mocks
  run_gencr inc "$@"
  if [ "$STATUS" -eq 1 ] && contains "$ERR" "$expect" && contains "$ERR" "Run with --fresh" && [ "$(calls)" -eq 0 ]; then
    ok "$desc"
  else
    not_ok "$desc" "status=$STATUS calls=$(calls) err=$ERR"
  fi
}
inc_reject "no previous review package" "no previous review packages found" --incremental --output-dir="$WORK/empty reports"
inc_reject "different review instructions" "different review instructions" --incremental -v=2 --output-dir="$INC_DIR" --pr-number=42 --previous="$FRESH_PKG"
inc_reject "different pull request" "different pull request" --incremental --output-dir="$INC_DIR" --pr-number=43 --previous="$FRESH_PKG"
reset_mocks
(cd "$TARGET" && git push -q origin side)
CODEREVIEW_BASE_BRANCH=side run_gencr inc --incremental --output-dir="$INC_DIR" --pr-number=42 --previous="$FRESH_PKG"
check "a different base branch is rejected" eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "different base branch"'
cp -R "$FRESH_PKG" "$WORK/tampered"
echo '{"schema": 1, "final_findings": []}' > "$WORK/tampered/findings.json"
inc_reject "a modified package" "package file findings.json is missing or modified" --incremental --output-dir="$INC_DIR" --pr-number=42 --previous="$WORK/tampered"
cp -R "$FRESH_PKG" "$WORK/no-manifest"; rm -f "$WORK/no-manifest/manifest.json"
inc_reject "a package without a manifest (incomplete)" "manifest.json missing" --incremental --output-dir="$INC_DIR" --pr-number=42 --previous="$WORK/no-manifest"
reset_mocks
echo 1 > "$MOCK_STATE/exit-1"
run_gencr incsrc --codex=review --output-dir="$WORK/failed reports"
reset_mocks
run_gencr incsrc --codex=review --incremental --output-dir="$WORK/failed reports"
check "a previous INCOMPLETE/infrastructure run is never a baseline" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "is not a completed review" && contains "$ERR" "Run with --fresh" && [ "$(calls)" -eq 0 ]'
git -C "$TARGET" branch -q pre-rewrite
git -C "$TARGET" reset -q --hard HEAD~2
echo 'rewritten' > "$TARGET/src dir/app file.py"
git -C "$TARGET" commit -qam "rewritten history"
inc_reject "a force-pushed (non-descendant) head" "is not an ancestor of HEAD" --incremental --output-dir="$INC_DIR" --pr-number=42 --previous="$FRESH_PKG"
git -C "$TARGET" reset -q --hard pre-rewrite
git -C "$TARGET" merge -q --no-ff -m "merge base" origin/staging
inc_reject "a merge-base that moved (base merged in)" "the merge-base changed" --incremental --output-dir="$INC_DIR" --pr-number=42 --previous="$FRESH_PKG"
git -C "$TARGET" reset -q --hard pre-rewrite
reset_mocks
run_gencr inc --codex=review --incremental --output-dir="$INC_DIR" --pr-number=42 --print
check "without --previous, the latest compatible review is selected (here it already covers HEAD: nothing to review)" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "no new review needed: review $(json_get "$CARRY_PKG/metadata.json" "d[\"run_id\"]") (verdict REQUEST CHANGES) already covers HEAD" && [ "$(calls)" -eq 0 ]'

# Contract v2: leaving one's own finding out of a later report is never a withdrawal; the report is invalid.
reset_mocks
queue 1 claude "REQUEST CHANGES" N/A N/A
v2_reply 2 "- None" "- None" "- CLAUDE-1: disputed; introduced: yes; severity: high; blocking: yes — the guard is reachable" \
  "- CLAUDE-1" "REQUEST CHANGES" NO "$(rid 1 0 claude initial)"
v2_reply 3 "- None" "- None" "- None" "- None" APPROVED NO "$(rid 2 0 codex attack)"
run_gencr omitted --codex=attack --output-dir="$WORK/omitted reports"
check "a finding left out of the author's later report (not withdrawn) makes that report invalid: INCOMPLETE" \
  eval '[ "$STATUS" -eq 20 ] && contains "$ERR" "your finding CLAUDE-1" && contains "$ERR" "leaving it out is not a withdrawal"'

# A blocker its author withdrew while the other reviewer keeps its claim stays open with its original definition,
# and the next incremental review must verify it.
ORPHAN_DIR="$WORK/orphan reports"
reset_mocks
queue 1 claude "REQUEST CHANGES" N/A N/A
v2_reply 2 "- None" "- None" "- CLAUDE-1: accepted; introduced: yes; severity: critical; blocking: yes — reachable, and worse than stated" \
  "- CLAUDE-1" "REQUEST CHANGES" NO "$(rid 1 0 claude initial)"
for n in 3 5 7 9; do
  if [ "$n" -eq 3 ]; then answered="$(rid 2 0 codex attack)"; else answered="$(rid $((n - 1)) $(( (n - 3) / 2 )) codex respond)"; fi
  v2_reply "$n" "- None" "- CLAUDE-1: withdrawn — the guard is unreachable after the early return" "- None" "- None" \
    APPROVED NO "$answered"
done
for n in 4 6 8; do
  v2_reply "$n" "- None" "- None" \
    "- CLAUDE-1 (report $(rid 1 0 claude initial)): accepted; introduced: yes; severity: critical; blocking: yes — still reachable through retry()" \
    "- CLAUDE-1" "REQUEST CHANGES" NO "$(rid $((n - 1)) $(( n < 6 ? 1 : (n - 4) / 2 )) claude reconcile)"
done
run_gencr orphan --codex=attack --output-dir="$ORPHAN_DIR"
ORPHAN_PKG="$(ls -d "$ORPHAN_DIR"/review-*)"
check "a withdrawn finding the other reviewer keeps as a blocker stays open (primary APPROVED, not unanimous)" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 9 ] && [ "$(json_get "$ORPHAN_PKG/findings.json" "[(f[\"id\"], f[\"blocker\"]) for f in d[\"final_findings\"]]")" = "[('"'"'CLAUDE-1'"'"', True)]" ]'
for f in "$ORPHAN_PKG/full-report.md" "$ORPHAN_DIR/code-review-$(json_get "$ORPHAN_PKG/metadata.json" 'd["run_id"]').md"; do
  check "the withdrawn-but-kept blocker keeps its full evidence and provenance in $(basename "$f")" \
    eval 'file_contains "$f" "- **CLAUDE-1 Example finding (marker 1)** — merge blocker" && file_contains "$f" "  - Problem: example problem" && file_contains "$f" "  - Evidence: example evidence" && file_contains "$f" "withdrawn by Claude in report $(rid 3 1 claude reconcile)" && file_contains "$f" "kept open by Codex"'
done
echo 'print("unrelated")' > "$TARGET/unrelated.py"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm "unrelated change"
reset_mocks
queue_single 1 claude APPROVED 2
verify 1 "CLAUDE-9: obsolete — not a previous finding"
run_gencr orphan --claude=review --incremental --output-dir="$ORPHAN_DIR"
check "the next incremental review must verify that earlier-round blocker" \
  eval '[ "$STATUS" -eq 20 ] && contains "$ERR" "has no '"'"'- CLAUDE-1: fixed|not fixed|obsolete" && file_contains "$MOCK_STATE/call-1.stdin" "verify each one): CLAUDE-1"'
check "the next incremental prompt carries that blocker's evidence" \
  eval 'file_contains "$MOCK_STATE/call-1.stdin" "  - Evidence: example evidence" && file_contains "$MOCK_STATE/call-1.stdin" "- **CLAUDE-1 Example finding (marker 1)** — merge blocker"'
cp -R "$ORPHAN_PKG" "$WORK/inconsistent"
python3 - "$WORK/inconsistent" <<'EOF'
import hashlib, json, os, sys
d = sys.argv[1]
f = json.load(open(os.path.join(d, "findings.json"))); f["final_findings"] = []
data = json.dumps(f, indent=2) + "\n"; open(os.path.join(d, "findings.json"), "w").write(data)
m = json.load(open(os.path.join(d, "manifest.json"))); m["files"]["findings.json"] = hashlib.sha256(data.encode()).hexdigest()
open(os.path.join(d, "manifest.json"), "w").write(json.dumps(m, indent=2) + "\n")
EOF
reset_mocks
run_gencr orphan --claude=review --incremental --output-dir="$ORPHAN_DIR" --previous="$WORK/inconsistent"
check "a package whose blockers are not open findings is never an incremental baseline" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "inconsistent package: merge blockers CLAUDE-1" && [ "$(calls)" -eq 0 ]'
git -C "$TARGET" reset -q --hard HEAD~1

# Output directories with quotes and backslashes work from fresh to incremental.
QUOTED_DIR="$WORK/q\"uo\\te reports"
reset_mocks
queue_single 1 codex "REQUEST CHANGES"
run_gencr quotedout --codex=review --output-dir="$QUOTED_DIR"
fresh_status=$STATUS
echo 'print("fix")' >> "$TARGET/src dir/app file.py"
git -C "$TARGET" commit -qam "fix for quoted-dir review"
reset_mocks
run_gencr quotedout --codex=review --incremental --output-dir="$QUOTED_DIR" --previous="$(ls -d "$QUOTED_DIR"/review-*)"
check "an output directory with quotes and backslashes supports fresh then incremental reviews" \
  eval '[ "$fresh_status" -eq 10 ] && [ "$STATUS" -eq 0 ] && file_contains "$MOCK_STATE/call-1.stdin" "Review mode: INCREMENTAL"'
git -C "$TARGET" reset -q --hard HEAD~1

# ── 7. Model identification ────────────────────────────────────────────────────

reset_mocks
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)"
run_gencr m-default --codex=attack
P="$(pkg m-default)"
check "default models: the CLI-reported actual models are shown" \
  eval 'file_contains "$P/full-report.md" "- Claude Model: mock-claude-default" && file_contains "$P/full-report.md" "- Codex Model: mock-codex-default"'
check "default models: requested is recorded as the CLI configured default" \
  [ "$(json_get "$P/metadata.json" 'd["models"]["claude"]["requested"], d["models"]["claude"]["requested_source"]')" = "None CLI configured default" ]

reset_mocks
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)" none
echo "anthropic.claude-opus-x-v1" > "$MOCK_STATE/model-1"
run_gencr m-claude --codex=attack --claude-model=opus
P="$(pkg m-claude)"
check "Claude-only override: Claude gets --model opus, Codex gets none" \
  eval '[ "$(arg_after 1 --model)" = opus ] && ! grep -qx -- --model "$MOCK_STATE/call-2.args"'
check "requested and resolved model are both shown when they differ" \
  file_contains "$P/full-report.md" "- Claude Model: anthropic.claude-opus-x-v1 (requested: opus)"

reset_mocks
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)"
run_gencr m-codex --codex=attack --codex-model gpt-x
check "Codex-only override (space form): Codex gets --model gpt-x, Claude gets none" \
  eval '[ "$(arg_after 2 --model)" = gpt-x ] && ! grep -qx -- --model "$MOCK_STATE/call-1.args" && file_contains "$(full_report m-codex)" "- Codex Model: gpt-x"'

LIMIT_HOOK='echo "gpt-x-2026-a" > "$MOCK_STATE/model-2"'
limit_run m-change claude codex --codex=attack --codex-model=gpt-x
LIMIT_HOOK=""
P="$(pkg m-change)"
check "a model change between rounds is shown per round, with the request" \
  file_contains "$P/full-report.md" "- Codex Model: Multiple: gpt-x-2026-a (round 0); gpt-x (rounds 1, 2, 3) (requested: gpt-x)"
check "metadata keeps each invocation's actual model and round" \
  [ "$(json_get "$P/metadata.json" '[(i["round"], i["actual"]) for i in d["models"]["codex"]["invocations"]][:2]')" = "[('0', ['gpt-x-2026-a']), ('1', ['gpt-x'])]" ]

reset_mocks
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)" none
touch "$MOCK_STATE/no-model-1" "$MOCK_STATE/no-model-2"
run_gencr m-none --codex=attack --codex-model=gpt-x
P="$(pkg m-none)"
check "an unreported actual model is Not reported, never invented" \
  eval 'file_contains "$P/full-report.md" "- Claude Model: Not reported (requested: CLI default)" && file_contains "$P/full-report.md" "- Codex Model: Not reported (requested: gpt-x)"'

for P in "$(pkg m-none)" "$INC_PKG" "$(pkg headless1)"; do
  check "header fields match across summary.md, full-report.md, reconciliation.md and metadata.json ($(basename "$P"))" \
    python3 - "$P" <<'EOF'
import json, os, sys
d = json.load(open(os.path.join(sys.argv[1], "metadata.json")))
want = {"Review Mode": d["review_mode"], "Claude Model": d["models"]["claude"]["display"],
        "Codex Model": d["models"]["codex"]["display"], "Final Verdict": d["final_verdict"],
        "Reviewed HEAD SHA": d["identity"]["head_sha"], "Approval Scope": d["approval_scope_label"]}
if d["previous_review"]:
    want["Previous Review ID"] = d["previous_review"]["id"]
    want["Previous Reviewed SHA"] = d["previous_review"]["reviewed_sha"]
for name in ("summary.md", "full-report.md", "reconciliation.md"):
    text = open(os.path.join(sys.argv[1], name)).read()
    for key, value in want.items():
        if "- %s: %s\n" % (key, value) not in text:
            sys.exit("%s lacks %s" % (name, key))
EOF
done

# ── 8. Trusted Claude settings (local Bedrock defaults under --restricted) ─────

cat > "$HOME/.claude/settings.json" <<'EOF'
{"env": {"CLAUDE_CODE_USE_BEDROCK": "1", "AWS_PROFILE": "canary-profile", "AWS_SECRET_CANARY": "CANARY-SECRET-9f3a"},
 "model": "canary-default-model",
 "permissions": {"allow": ["Bash(git push)"]},
 "hooks": {"PreToolUse": []}, "enabledPlugins": {"x": true}}
EOF
mkdir -p "$TARGET/.claude"
echo '{"env": {"PROJECT_CANARY": "1"}, "permissions": {"allow": ["Bash"]}}' > "$TARGET/.claude/settings.json"
git -C "$TARGET" add .claude && git -C "$TARGET" commit -qm "repo claude settings"
reset_mocks
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)"
run_gencr settings1 --codex=attack
check "Claude receives a trusted settings file holding only env and model from user settings" \
  [ "$(json_get "$MOCK_STATE/call-1.settings" 'sorted(d), d["model"], d["env"]["AWS_PROFILE"]')" = "['env', 'model'] canary-default-model canary-profile" ]
check "the trusted settings file never includes permissions, hooks, plugins or project settings" \
  eval '! grep -qE "permissions|hooks|Plugins|PROJECT_CANARY" "$MOCK_STATE/call-1.settings"'
settings_path="$(sed -n 2p "$MOCK_STATE/call-1.settings-mode")"
check "the trusted settings file is private (0600), outside the package, and removed afterwards" \
  eval '[ "$(head -n 1 "$MOCK_STATE/call-1.settings-mode")" = 0o600 ] && ! contains "$settings_path" "$HOME/Documents" && [ ! -e "$settings_path" ]'
check "credential-shaped canaries never reach the review package or its prompts" \
  eval '! grep -rq "CANARY-SECRET-9f3a" "$(pkg settings1)"'
check "Codex is not given Claude's settings" eval '! grep -qx -- --settings "$MOCK_STATE/call-2.args"'
reset_mocks
queue 1 claude APPROVED N/A N/A
queue 2 codex APPROVED YES "$(rid 1 0 claude initial)"
run_gencr settings2 --codex=attack --claude-model=opus
check "an explicit --claude-model is passed alongside the trusted settings" \
  eval '[ "$(arg_after 1 --model)" = opus ] && grep -qx -- --settings "$MOCK_STATE/call-1.args"'
rm -f "$HOME/.claude/settings.json"
git -C "$TARGET" reset -q --hard HEAD~1
reset_mocks
queue_single 1 claude APPROVED
run_gencr settings3 --claude=review
check "without user settings no --settings file is passed" eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 1 ] && ! grep -qx -- --settings "$MOCK_STATE/call-1.args"'

# ── 9. Persistence, concurrency, output location, local isolation ──────────────

reset_mocks
queue_single 1 claude APPROVED
echo 'chmod a-w "$HOME"/Documents/CodeReview/savefail/review-*' > "$MOCK_STATE/hook-1"
run_gencr savefail --claude=review
check "an unsaved package fails with exit 23 and says so, never announcing success" \
  eval '[ "$STATUS" -eq 23 ] && contains "$ERR" "could NOT" && ! contains "$ERR" "final verdict: APPROVED"'
chmod -R u+w "$(reports_dir savefail)"

check "the package publisher never overwrites an existing file or a directory" \
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import gencr_support as g, os, tempfile
d = tempfile.mkdtemp(); p = os.path.join(d, "x"); open(p, "w").write("first")
try:
    g.publish(p, "second"); sys.exit(1)
except OSError: pass
os.mkdir(os.path.join(d, "dir"))
try:
    g.publish(os.path.join(d, "dir"), "x"); sys.exit(1)
except OSError: pass
sys.exit(0 if open(p).read() == "first" and os.listdir(os.path.join(d, "dir")) == [] and sorted(os.listdir(d)) == ["dir", "x"] else 1)' "$TREE/bin"

reset_mocks
export MOCK_VERDICT=APPROVED
(cd "$TARGET" && "$GENCR" race --codex=review > "$WORK/race1.out" 2> "$WORK/race1.err"; echo $? > "$WORK/race1.status") &
(cd "$TARGET" && "$GENCR" race --codex=review > "$WORK/race2.out" 2> "$WORK/race2.err"; echo $? > "$WORK/race2.status") &
wait
unset MOCK_VERDICT
check "two simultaneous runs (same branch, same second) both succeed in separate packages" \
  eval '[ "$(cat "$WORK/race1.status")" -eq 0 ] && [ "$(cat "$WORK/race2.status")" -eq 0 ] && [ "$(ls -d "$(reports_dir race)"/review-* | wc -l | tr -d " ")" -eq 2 ] && [ "$(ls "$(reports_dir race)"/code-review-*.md | wc -l | tr -d " ")" -eq 2 ]'

reset_mocks
run_gencr inside --output-dir="$TARGET/reports"
check "an output directory inside the reviewed repository is refused" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "inside the reviewed repository" && [ "$(calls)" -eq 0 ]'
rm -rf "$TARGET/reports"
ln -s "$TARGET/src dir" "$WORK/sneaky"
run_gencr inside --output-dir="$WORK/sneaky"
check "a symlink that resolves inside the repository is refused" eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "inside the reviewed repository"'

# --output-dir / --previous: a leading ~ means HOME (literal tilde, as from a quoted or =-joined argument).
tilde_pkg() { ls -d "$HOME/$1"/review-* 2>/dev/null | head -n 1; }
reset_mocks
queue_single 1 claude APPROVED
run_gencr tilde1 --claude=review '--output-dir=~/tilde out/eq form'
check "--output-dir=~/... writes under HOME (path with spaces), never a literal ~ in the repository" \
  eval '[ "$STATUS" -eq 0 ] && [ -f "$(tilde_pkg "tilde out/eq form")/manifest.json" ] && [ ! -e "$TARGET/~" ]'
reset_mocks
queue_single 1 claude APPROVED
run_gencr tilde2 --claude=review --output-dir '~/tilde out/space form'
check "--output-dir ~/... (space-separated form) writes under HOME" \
  eval '[ "$STATUS" -eq 0 ] && [ -f "$(tilde_pkg "tilde out/space form")/manifest.json" ]'
reset_mocks
run_gencr tilde3 --codex=attack '--output-dir=~/tilde print/never created' --print
check "--print with a ~ output directory succeeds and creates nothing" \
  eval '[ "$STATUS" -eq 0 ] && [ ! -e "$HOME/tilde print" ] && [ ! -e "$TARGET/~" ] && [ "$(calls)" -eq 0 ]'
run_gencr tilde4 --codex=attack '--output-dir=~' --print
check "--output-dir=~ alone means HOME" eval '[ "$STATUS" -eq 0 ] && [ ! -e "$TARGET/~" ]'
bad_args "a ~user output directory" tilde5 '--output-dir=~root/x'
bad_args "an --output-dir without a value" tilde5 --output-dir
bad_args "an empty --output-dir" tilde5 --output-dir=
reset_mocks
HOME="$TARGET" run_gencr tilde6 --codex=attack '--output-dir=~/reports' --print
check "a ~ path that resolves inside the repository is still refused" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "inside the reviewed repository" && [ ! -e "$TARGET/reports" ]'
run_gencr inside2 --codex=attack '--output-dir=src dir/../reports' --print
check "a relative path inside the repository is refused" eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "is inside the reviewed repository"'
run_gencr inside3 --codex=attack '--output-dir=missing/../../target repo/reports' --print
check "a not-yet-existing path is normalized before the check (missing/../.. back into the repository)" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "$(cd -P "$TARGET" && pwd)/reports is inside the reviewed repository"'
run_gencr inside4 --codex=attack --output-dir "$TARGET/reports" --print
check "an explicit absolute path inside the repository is refused (space form)" eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "inside the reviewed repository"'
# Containment is by filesystem identity: a case alias of the repository is the repository on case-insensitive
# filesystems (macOS default) and a different directory on case-sensitive ones (Linux); nothing is created on refusal.
ALIAS="$WORK/TARGET REPO"
reset_mocks
queue_single 1 claude APPROVED
run_gencr inside5 --claude=review --output-dir="$TARGET/new reports"
check "a refused real run creates nothing inside the repository" \
  eval '[ "$STATUS" -eq 1 ] && [ ! -e "$TARGET/new reports" ] && [ "$(calls)" -eq 0 ]'
if [ -d "$ALIAS" ]; then
  for mode in --print ""; do
    reset_mocks
    queue_single 1 claude APPROVED
    run_gencr casealias --claude=review --output-dir="$ALIAS/case reports" $mode
    check "case-insensitive filesystem: a case alias of the repository is refused (${mode:-real run})" \
      eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "inside the reviewed repository" && [ ! -e "$TARGET/case reports" ] && [ "$(calls)" -eq 0 ]'
  done
else
  reset_mocks
  run_gencr casealias --codex=attack --output-dir="$ALIAS/case reports" --print
  check "case-sensitive filesystem: a differently-cased path is a different directory and is allowed" \
    eval '[ "$STATUS" -eq 0 ] && [ ! -e "$ALIAS" ]'
fi

reset_mocks
queue_single 1 claude APPROVED
run_gencr relout --claude=review '--output-dir=../relative out'
check "a relative path outside the repository is resolved against the current directory" \
  eval '[ "$STATUS" -eq 0 ] && [ -f "$(ls -d "$WORK/relative out"/review-* | head -n 1)/manifest.json" ]'
mkdir -p "$HOME/tilde prev"
cp -R "$(tilde_pkg "tilde out/eq form")" "$HOME/tilde prev/pkg"
reset_mocks
run_gencr tilde1 --claude=review --incremental '--output-dir=~/tilde out/eq form' --previous '~/tilde prev/pkg' --print
check "--previous ~/... (space form) is expanded too (the package is read: it covers HEAD)" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "no new review needed: review $(json_get "$HOME/tilde prev/pkg/metadata.json" "d[\"run_id\"]")"'

reset_mocks
queue_single 1 claude APPROVED
GITHUB_ACTIONS=true GITHUB_TOKEN=ghs_canary GH_TOKEN=ghs_canary GITHUB_REPOSITORY=x/y run_gencr localci --claude=review
check "local runs never call gh or GitHub, even with GitHub variables set" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 1 ] && [ -f "$(pkg localci)/manifest.json" ] && [ ! -e "$MOCK_STATE/gh-calls" ]'
check "the review engine contains no GitHub API or gh usage" \
  eval '! grep -nE "api\.github\.com|(^|[^a-z_])gh (api|pr|run)|GITHUB_" "$TREE/bin/gencr" "$TREE/bin/gencr_support.py" |
    grep -vE "^[^:]+:[0-9]+:REVIEWER_ENV_DENY = \(\"GH_TOKEN\", \"GITHUB_TOKEN\", \"GENCR_ELIGIBILITY_SOCKET\"\)$"'
# The one exempt line only removes tokens from reviewer processes; it must stay exactly that list.
check "the engine names GitHub tokens only to remove them from reviewer processes" \
  eval '[ "$(grep -c "REVIEWER_ENV_DENY" "$TREE/bin/gencr_support.py")" -eq 2 ] && grep -q "if key not in REVIEWER_ENV_DENY and not key.startswith(\"GENCR_ELIGIBILITY_\")}" "$TREE/bin/gencr_support.py"'

check "no generated report or artifact is ever written inside the reviewed repository" \
  eval '[ -z "$(git -C "$TARGET" status --porcelain --untracked-files=all --ignored)" ]'

# ── 10. Repository invariants ──────────────────────────────────────────────────

INSTR_SUMS_AFTER="$(cd "$REPO/dotfiles/claude" && sha1 ./*.md)"
check "review instruction files are unchanged" [ "$INSTR_SUMS_BEFORE" = "$INSTR_SUMS_AFTER" ]
if command -v shellcheck >/dev/null 2>&1; then
  check "bin/gencr and the tests pass shellcheck (warnings and errors)" \
    shellcheck -s bash -S warning "$REPO/bin/gencr" "$REPO/tests/test_gencr.sh"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
