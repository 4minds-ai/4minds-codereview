#!/usr/bin/env bash
# Review-notes tests for bin/gencr: observations the review instructions require that are not findings (verified clean
# checks, unresolved risks, disproven claims, test gaps, out-of-scope ownership changes, other observations) have one
# validated destination, "## Review notes", the last section; "## Findings" stays findings only; "## Outstanding
# disputed findings" holds only rows about a known finding ID. Nothing is moved or repaired. Replays a sanitized copy
# of a real failed review (tests/fixtures/observation-sections) in both reviewer orders.
# Mock reviewer CLIs; no network. Usage: bash tests/test_gencr_notes.sh
# shellcheck disable=SC2016,SC2034  # deferred eval checks

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO/tests/fixtures/observation-sections"
WORK="$(cd -P "$(mktemp -d)" && pwd)/gencr notes tests"
mkdir -p "$WORK"
trap 'chmod -R u+w "$(dirname "$WORK")" 2>/dev/null; rm -rf "$(dirname "$WORK")"' EXIT

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
not_ok() { FAIL=$((FAIL + 1)); echo "not ok - $1"; [ -z "$2" ] || printf '%s\n' "$2" | sed 's/^/    # /'; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else not_ok "$desc" "status=${STATUS:-} $(printf '%s' "${ERR:-}" | tail -n 2)"; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); exec("print(" + sys.argv[2] + ")")' "$1" "$2"; }

export HOME="$WORK/home"
mkdir -p "$HOME"
MOCK_BIN="$WORK/mock bin"
export MOCK_STATE="$WORK/mock state"
mkdir -p "$MOCK_BIN"
cp "$REPO/tests/mocks/mock_reviewer.py" "$MOCK_BIN/mock_reviewer.py"
ln -s mock_reviewer.py "$MOCK_BIN/claude"
ln -s mock_reviewer.py "$MOCK_BIN/codex"
export PATH="$MOCK_BIN:$PATH"
unset CODEREVIEW_BASE_BRANCH MOCK_VERDICT GENCR_REVIEW_COMMENT GITHUB_ACTIONS
REAL_PYTHON="$(python3 -c 'import sys; print(sys.executable)')"

TARGET="$WORK/target"
git init -q --bare "$WORK/origin.git"
git init -q "$TARGET"
git -C "$TARGET" config user.email t@example.com
git -C "$TARGET" config user.name T
git -C "$TARGET" checkout -q -b staging
echo base > "$TARGET/base.txt"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm base
git -C "$TARGET" remote add origin "$WORK/origin.git"
git -C "$TARGET" push -q origin staging
git -C "$TARGET" checkout -q -b feature
printf 'def sync():\n    return 1\n' > "$TARGET/app.py"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm feature

# Every scenario is an independent first review: no earlier package of the same developer may be its baseline.
reset_mocks() { rm -rf "$MOCK_STATE" "${HOME:?}/Documents/CodeReview"; mkdir -p "$MOCK_STATE/responses"; }
calls() { cat "$MOCK_STATE/count" 2>/dev/null || echo 0; }
rid() { printf '%02d-round%d-%s-%s' "$1" "$2" "$3" "$4"; }
run_gencr() { # DEV ARGS...
  local dev="$1"; shift
  (cd "$TARGET" && "$REPO/bin/gencr" "$dev" "$@") > "$WORK/stdout" 2> "$WORK/stderr"
  STATUS=$?; OUT="$(cat "$WORK/stdout")"; ERR="$(cat "$WORK/stderr")"
  PKG="$(ls -td "$HOME/Documents/CodeReview/$dev"/review-* 2>/dev/null | head -n 1)"
}
block() { python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import gencr_summary as g; sys.stdout.write(g.extract(open(sys.argv[2]).read()))' "$REPO/bin" "$PKG/summary.md"; }
# Final findings as "ID:reporter:report:blocker" lines.
finals() { json_get "$PKG/findings.json" '"\n".join("%s:%s:%s:%s" % (f["id"], f["reported_by"], f["report_id"], f["blocker"]) for f in d["final_findings"])' | sort; }

# Roles for an order: claude-first (Claude primary) or codex-first (the mirror image).
order_flags() { if [ "$1" = claude ]; then echo "--codex=attack"; else echo "--codex=review --claude=attack"; fi; }
# Mirrors text between the reviewers (CLAUDE<->CODEX, Claude<->Codex, claude<->codex) for the codex-first order.
mirror() { sed -e 's/CLAUDE/@P@/g; s/CODEX/CLAUDE/g; s/@P@/CODEX/g' -e 's/Claude/@P@/g; s/Codex/Claude/g; s/@P@/Codex/g' \
               -e 's/claude/@P@/g; s/codex/claude/g; s/@P@/codex/g'; }
# fixture N NAME ORDER — the sanitized fixture as the reply to call N, mirrored for the codex-first order.
fixture() { if [ "$3" = claude ]; then cp "$FIXTURES/$2.md" "$MOCK_STATE/responses/$1"; else mirror < "$FIXTURES/$2.md" > "$MOCK_STATE/responses/$1"; fi; }
# Removes the finding blocks with prefix $2 from the ## Findings section of reply $1 (nothing else changes).
drop_blocks() {
  python3 -B - "$MOCK_STATE/responses/$1" "$2" <<'EOF'
import re, sys
path, prefix = sys.argv[1], sys.argv[2]
lines, out, skip, inside = open(path).read().split("\n"), [], False, False
for line in lines:
    if line.startswith("## "):
        inside, skip = line == "## Findings", False
    elif inside and line.startswith("- "):
        skip = line.startswith("- **%s-" % prefix)
    if not skip:
        out.append(line)
open(path, "w").write(re.sub(r"\n{3,}", "\n\n", "\n".join(out)))
EOF
}
# Edits the disposition section of reply $1 with python expression $2 applied to its text s.
edit_reply() {
  python3 -B - "$MOCK_STATE/responses/$1" "$2" <<'EOF'
import sys
path, expr = sys.argv[1], sys.argv[2]
s = open(path).read()
s = eval(expr)
open(path, "w").write(s)
EOF
}

# gen N JSON — a reviewer response from a spec: verdict, agreement, peer, findings [{id,title,severity,fix}],
# blockers [ids], dispositions [lines after "- "], disputes [lines after "- "], verification [lines],
# notes {label: value} (every Review notes label defaults to None).
gen() {
  python3 -B - "$MOCK_STATE/responses/$1" "$2" <<'EOF'
import json, sys
path, spec = sys.argv[1], json.loads(sys.argv[2])
out = ["Report.", "", "## Findings"]
for f in spec.get("findings", []):
    out += ["- **%s %s**" % (f["id"], f.get("title", "A finding")), "  - Severity: %s" % f.get("severity", "High"),
            "  - File: app.py:1", "  - Problem: problem text", "  - Evidence: evidence text",
            "  - Expected vs actual: x vs y", "  - Tests: none", "  - Fix: %s" % f.get("fix", "apply the fix")]
if not spec.get("findings"):
    out.append("- None")
out += ["", "## Disposition of peer findings"] + (["- " + d for d in spec.get("dispositions", [])] or ["- None"])
out += ["", "## Merge blockers"] + (["- " + b for b in spec.get("blockers", [])] or ["- None"])
out += ["", "## Outstanding disputed findings"] + (["- " + d for d in spec.get("disputes", [])] or ["- None"])
if "verification" in spec:
    out += ["", "## Previous findings verification"] + ["- " + v for v in spec["verification"]]
labels = ("Verified clean", "Unresolved risks", "Disproven claims", "Test gaps", "Out-of-scope ownership changes",
          "Other observations")
out += ["", "## Review notes"] + ["- %s: %s" % (l, spec.get("notes", {}).get(l, "None")) for l in labels]
out += ["", "VERDICT: " + spec["verdict"], "PEER-AGREEMENT: " + spec.get("agreement", "N/A"),
        "PEER-REPORT: " + spec.get("peer", "N/A"), ""]
open(path, "w").write("\n".join(out))
EOF
}

# gen_for ORDER N ROLE JSON — gen with the spec written for the claude-first order (role primary|adversary),
# mirrored for the codex-first order.
gen_for() { local spec="$4"; [ "$1" = claude ] || spec="$(printf '%s' "$4" | mirror)"; gen "$2" "$spec"; }

notes_of() { json_get "$PKG/findings.json" "d[\"review_notes\"][\"$1\"][\"$2\"]"; }
# A one-call run of reply $1 (already queued as response 1) for ORDER $2.
one_call() { # DEV ORDER
  # shellcheck disable=SC2046
  run_gencr "$1" $(order_flags "$2")
}
# A complete attack reply accepting the initial fixture's CLAUDE-1..7 (claude-first names).
attack_reply() { # AGREEMENT [EXTRA_SPEC_JSON_MEMBERS]
  echo "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"$1\", \"peer\": \"01-round0-claude-initial\",
    \"findings\": [{\"id\": \"CODEX-1\", \"title\": \"Peer finding\"}], \"blockers\": [\"CLAUDE-1\", \"CLAUDE-2\", \"CLAUDE-3\"],
    \"dispositions\": [\"CLAUDE-1: accepted — ok\", \"CLAUDE-2: accepted — ok\", \"CLAUDE-3: accepted — ok\", \"CLAUDE-4: accepted — ok\",
                       \"CLAUDE-5: accepted — ok\", \"CLAUDE-6: accepted — ok\", \"CLAUDE-7: accepted — ok\"]$2}"
}

# ── 1. The real failure, replayed: rejected, kept byte for byte, never repaired or moved ──

for order in claude codex; do
  if [ "$order" = claude ]; then P=Claude PP=CLAUDE p=claude; else P=Codex PP=CODEX p=codex; fi
  reset_mocks
  fixture 1 01-claude-initial-misplaced "$order"
  one_call "misplaced-$order" "$order"
  R1="$PKG/$(rid 1 0 "$p" initial)"
  check "$order-first replay: the observations inside '## Findings' make the report invalid (exit 20, 1 call)" \
    eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 1 ] && [ "$(json_get "$PKG/metadata.json" "d[\"outcome\"]")" = INCOMPLETE ]'
  check "$order-first replay: the error names the missing destination and the misplaced lines" \
    eval 'contains "$ERR" "missing required section '"'"'## Review notes'"'"'" && contains "$ERR" "is outside any field: Things I checked and found clean:"'
  check "$order-first replay: the response is kept byte for byte; normalization does not repair or move it" \
    eval 'cmp -s "$R1.report.md" "$R1.report.original.md" && cmp -s "$R1.report.md" "$MOCK_STATE/responses/1" && [ "$(json_get "$R1.normalization.json" "d[\"result\"]")" = irreparable ]'

  # The same misplacement with a "## Review notes" section present: rejected for the placement itself.
  reset_mocks
  fixture 1 01-claude-initial-corrected "$order"
  edit_reply 1 "s.replace('  - Fix: synthetic fix 7\n', '  - Fix: synthetic fix 7\n\nThings I checked and found clean:\n- The host is pinned.\n', 1)"
  one_call "misplaced2-$order" "$order"
  check "$order-first: observation text after the last finding is rejected with a pointer to '## Review notes'" \
    eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "each finding must start with a bold ${PP}-<n> ID: - The host is pinned." && contains "$ERR" "observations that are not findings go under '"'"'## Review notes'"'"'"'

  # Corrected: the observations under "## Review notes" are valid, preserved, and never findings or blockers.
  reset_mocks
  fixture 1 01-claude-initial-corrected "$order"
  gen_for "$order" 2 adversary "$(attack_reply YES)"
  # shellcheck disable=SC2046
  run_gencr "corrected-$order" $(order_flags "$order")
  check "$order-first corrected: the review completes (exit 10, 2 calls) with only the seven findings and CODEX-1" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 2 ] && [ "$(json_get "$PKG/findings.json" "len(d[\"final_findings\"])")" -eq 8 ]'
  check "$order-first corrected: the full report keeps the notes, byte for byte, under the reviewer's final position" \
    eval 'grep -qxF "### Review notes" "$PKG/full-report.md" && grep -qxF "  - The response byte cap is checked before each chunk is appended." "$PKG/full-report.md" && grep -qxF -- "- Disproven claims: None" "$PKG/full-report.md"'
  check "$order-first corrected: findings.json keeps the notes per reviewer, separate from findings" \
    eval 'contains "$(notes_of "$p" "Verified clean")" "- The host is pinned and redirects are off." && [ "$(notes_of "$p" "Test gaps")" = None ] && ! grep -q "\"id\": \".*pinned" "$PKG/findings.json"'
  check "$order-first corrected: notes are not findings, blockers or disputes in the summary" \
    eval '! contains "$(block)" "redirects are off" && ! contains "$(block)" "live-verified" && grep -qxF -- "- Critical: 1" "$PKG/summary.md" && grep -qxF -- "- Low: 2" "$PKG/summary.md" && ! grep -q "live-verified" "$PKG/summary.md"'

  # Both reviewers receive the same rules: the shared prompt part is byte-identical between the two calls.
  check "$order-first prompts: both reviewers get the identical shared instructions, with the notes section and its mapping" \
    eval '[ "$(sed "/^===== YOUR ROLE =====\$/,\$d" "$MOCK_STATE/call-1.stdin")" = "$(sed "/^===== YOUR ROLE =====\$/,\$d" "$MOCK_STATE/call-2.stdin")" ] &&
          grep -qF "  - \"## Review notes\": the last section" "$MOCK_STATE/call-1.stdin" &&
          grep -qF "Hypotheses and unverified risks go under \"Unresolved risks\", never into \"## Findings\"" "$MOCK_STATE/call-1.stdin" &&
          ! grep -qF "Every report must distinguish confirmed defects, missing or ineffective tests, false positives, disputed findings, unresolved risks, and merge-blocking issues." "$MOCK_STATE/call-1.stdin"'
done

# ── 2. "## Review notes" boundaries (initial report, 1 call) ──

notes_case() { # ORDER DESCRIPTION EXPECTED-ERROR PYTHON-EDIT
  local order="$1" desc="$2" expect="$3"
  reset_mocks
  fixture 1 01-claude-initial-corrected "$order"
  edit_reply 1 "$4"
  one_call "notes-$order" "$order"
  if [ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "$expect"; then ok "$order-first: $desc"
  else not_ok "$order-first: $desc" "status=$STATUS calls=$(calls) err=$(printf '%s' "$ERR" | tail -n 2)"; fi
}
notes_ok() { # ORDER DESCRIPTION PYTHON-EDIT [EXTRA-CHECK]
  local order="$1" desc="$2"
  reset_mocks
  fixture 1 01-claude-initial-corrected "$order"
  edit_reply 1 "$3"
  # shellcheck disable=SC2046
  run_gencr "notesok-$order" $( [ "$order" = claude ] && echo --claude=review || echo --codex=review )
  if [ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 1 ] && { [ -z "$4" ] || eval "$4"; }; then ok "$order-first: $desc"
  else not_ok "$order-first: $desc" "status=$STATUS calls=$(calls) err=$(printf '%s' "$ERR" | tail -n 2)"; fi
}
for order in claude codex; do
  if [ "$order" = claude ]; then PP=CLAUDE; else PP=CODEX; fi
  notes_case "$order" "a second notes section is rejected" "more than one '## Review notes' section" \
    "s.replace('VERDICT:', '## Review notes\n- Verified clean: None\n\nVERDICT:', 1)"
  notes_case "$order" "labels out of order are rejected" "'## Review notes' must list" \
    "s.replace('- Disproven claims: None\n- Test gaps: None\n', '- Test gaps: None\n- Disproven claims: None\n', 1)"
  notes_case "$order" "a missing label is rejected" "'## Review notes' must list" \
    "s.replace('- Test gaps: None\n', '', 1)"
  notes_case "$order" "a repeated label is rejected" "'## Review notes' must list" \
    "s.replace('- Test gaps: None\n', '- Test gaps: None\n- Test gaps: None\n', 1)"
  notes_case "$order" "an unknown label is rejected" "'## Review notes' must list" \
    "s.replace('- Other observations: None\n', '- Other observations: None\n- Confirmed defects: CLAUDE-1\n', 1)"
  notes_case "$order" "an empty value is rejected" "'## Review notes': Test gaps has no value" \
    "s.replace('- Test gaps: None\n', '- Test gaps:\n', 1)"
  notes_case "$order" "None followed by more text is rejected" "'## Review notes': Test gaps is None but has more content" \
    "s.replace('- Test gaps: None\n', '- Test gaps: None\n  - one gap after all\n', 1)"
  notes_ok "$order" "a value written as a block directly below its label is valid and kept" \
    "s.replace('- Test gaps: None\n', '- Test gaps:\n  - coverage unavailable\n  - no load test\n', 1)" \
    '[ "$(notes_of "$( [ "$order" = claude ] && echo claude || echo codex)" "Test gaps")" = "- coverage unavailable
- no load test" ]'
  notes_case "$order" "None written below its label, with more text, is rejected" "'## Review notes': Test gaps is None but has more content" \
    "s.replace('- Test gaps: None\n', '- Test gaps:\n  None\n  - coverage unavailable\n', 1)"
  notes_case "$order" "observation text before the first finding is rejected" "'## Findings' line 6 is not part of a finding: Things I checked and found clean:" \
    "s.replace('## Findings\n\n', '## Findings\nThings I checked and found clean:\n  - Credential logging is redacted.\n\n', 1)"
  notes_case "$order" "text outside a label is rejected" "'## Review notes' line" \
    "s.replace('- Disproven claims: None\n', 'Some prose.\n- Disproven claims: None\n', 1)"
  notes_case "$order" "a section after the notes is rejected" "'## Review notes' must be the last section" \
    "s.replace('VERDICT:', '## Outstanding disputed findings\n- None\n\nVERDICT:', 1).replace('## Outstanding disputed findings\n- None\n\n## Review notes', '## Review notes', 1)"
  notes_case "$order" "an unknown heading after the first section is rejected, not dropped" "unknown section '## Unresolved risks'" \
    "s.replace('## Merge blockers', '## Unresolved risks\n- something\n\n## Merge blockers', 1)"
  notes_ok "$order" "a title heading before the first section is allowed" \
    "s.replace('I\'m requesting changes.', '## Code Review: feature (widget sync)\n\nI\'m requesting changes.', 1)"
  notes_case "$order" "an unfenced finding heading inside a note is rejected (never a finding, never swallowed)" \
    "line 96 inside the Other observations value looks like a finding heading" \
    "s.replace('- Other observations: None', '- Other observations: an example heading\n  - **${PP}-9 Not a finding**', 1)"
  notes_ok "$order" "a fenced finding heading inside a note stays note text (never a finding)" \
    "s.replace('- Other observations: None', '- Other observations: an example heading\n  \`\`\`\n  - **${PP}-9 Not a finding**\n  \`\`\`', 1)" \
    '[ "$(json_get "$PKG/findings.json" "len(d[\"final_findings\"])")" -eq 7 ] && ! grep -q "Not a finding" "$PKG/summary.md"'
  notes_ok "$order" "all-None notes are valid" "s"
done

# Format normalization of a finding never touches the notes: they come through byte for byte.
for order in claude codex; do
  reset_mocks
  fixture 1 01-claude-initial-corrected "$order"
  edit_reply 1 "s.replace('  - Evidence: (traced, not executed) synthetic evidence 1', '  - Evidence (traced, not executed): synthetic evidence 1', 1).replace('- Other observations: None', '- Other observations: odd  spacing\\t and a trailing space \n  \`\`\`\n  - **CLAUDE-9 still a note**\n  \`\`\`', 1)"
  # shellcheck disable=SC2046
  run_gencr "normnotes-$order" $( [ "$order" = claude ] && echo --claude=review || echo --codex=review )
  R1="$PKG/01-round0-$order-initial"
  check "$order-first: a normalized report keeps its notes byte for byte" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(json_get "$R1.normalization.json" "d[\"result\"]")" = normalized ] &&
          [ "$(sed -n "/^## Review notes\$/,\$p" "$R1.report.md")" = "$(sed -n "/^## Review notes\$/,\$p" "$R1.report.original.md")" ] &&
          grep -qF "odd  spacing" "$R1.report.md" && grep -qF -- "-9 still a note**" "$R1.report.md" && [ "$(grep -cxF "  \`\`\`" "$R1.report.md")" -eq 2 ]'
done

# ── 3. "## Outstanding disputed findings" rows are linked to a known finding ──

# dispute_case ORDER DESCRIPTION EXPECTED(empty = valid) DISPUTES_JSON — the attack reply (call 2) disputes rows.
dispute_case() {
  local order="$1" desc="$2" expect="$3"
  reset_mocks
  fixture 1 01-claude-initial-corrected "$order"
  gen_for "$order" 2 adversary "$(attack_reply NO ", \"disputes\": $4")"
  gen_for "$order" 3 primary '{"verdict": "REQUEST CHANGES", "agreement": "YES", "peer": "02-round0-codex-attack",
    "findings": [{"id": "CLAUDE-1", "title": "Kept"}], "blockers": ["CLAUDE-1"], "dispositions": ["CODEX-1: accepted — ok"]}'
  # shellcheck disable=SC2046
  run_gencr "dispute-$order" $(order_flags "$order")
  if [ -z "$expect" ]; then
    if [ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 3 ] && { [ -z "$5" ] || eval "$5"; }; then ok "$order-first: $desc"
    else not_ok "$order-first: $desc" "status=$STATUS calls=$(calls) err=$(printf '%s' "$ERR" | tail -n 2)"; fi
  elif [ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 2 ] && contains "$ERR" "$expect"; then ok "$order-first: $desc"
  else not_ok "$order-first: $desc" "status=$STATUS calls=$(calls) err=$(printf '%s' "$ERR" | tail -n 2)"; fi
}
for order in claude codex; do
  if [ "$order" = claude ]; then PP=CLAUDE A=Codex; else PP=CODEX A=Claude; fi
  ONLY="lists only disputes about a finding, one row per finding ID; observations go under '## Review notes'"
  dispute_case "$order" "a multiline dispute about a finding is one disputed item" "" \
    '["CLAUDE-2: the severity is disputed\n  - the panel is reachable from settings\n\n  - see CLAUDE-3 for the related path"]' \
    '[ "$(grep -c "^- ${PP}-2: the severity is disputed" "$PKG/summary.md")" -eq 1 ] && ! grep -q "^- the panel is reachable" "$PKG/summary.md" && ! grep -q "^- see ${PP}-3" "$PKG/summary.md" &&
     grep -qF -- "- ${PP}-2: the severity is disputed - the panel is reachable from settings - see ${PP}-3 for the related path (" "$PKG/summary.md" &&
     contains "$(block)" "${PP}-2: the severity is disputed" && contains "$(block)" "the panel is reachable from settings"'
  dispute_case "$order" "an 'Unresolved risks:' row is rejected" "$ONLY" '["Unresolved risks: the external schema is unverified."]'
  dispute_case "$order" "a 'Still unverified' row with nested items is rejected" "$ONLY" \
    '["Still unverified (not counted as defects):\n  - whether reused IDs purge old content"]'
  dispute_case "$order" "free prose in the section is rejected" "$ONLY" '["CLAUDE-1: ok\n**Summary**"]'
  dispute_case "$order" "a row about several findings is rejected" "one finding per row" '["CLAUDE-1, CLAUDE-2 — both are disputed"]'
  dispute_case "$order" "two rows about one finding are rejected" "more than one row for ${PP}-1" '["CLAUDE-1: one", "CLAUDE-1: two"]'
  dispute_case "$order" "an unknown finding ID is rejected" "${PP}-99 is not a finding of this review" '["CLAUDE-99: invented"]'
  dispute_case "$order" "an ID that only prefixes a known one is rejected" "${PP}-10 is not a finding of this review" '["CLAUDE-10: near miss"]'
  dispute_case "$order" "a row without content is rejected" "has no content" '["CLAUDE-1:"]'
  dispute_case "$order" "None together with a row is rejected" "$ONLY" '["None", "CLAUDE-1: x"]'
  dispute_case "$order" "a lower-case ID row is rejected" "$ONLY" '["claude-1: lower case"]'
done

# A dispute about an earlier version (defined only in an earlier report of the run) is valid and is not a definition.
for order in claude codex; do
  if [ "$order" = claude ]; then AP=CODEX a=codex; else AP=CLAUDE a=claude; fi
  reset_mocks
  gen_for "$order" 1 primary '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1"}], "blockers": ["CLAUDE-1"]}'
  gen_for "$order" 2 adversary '{"verdict": "REQUEST CHANGES", "agreement": "NO", "peer": "01-round0-claude-initial",
    "findings": [{"id": "CODEX-1"}, {"id": "CODEX-2", "title": "Dropped later"}], "dispositions": ["CLAUDE-1: accepted — ok"], "blockers": ["CODEX-1"]}'
  gen_for "$order" 3 primary '{"verdict": "REQUEST CHANGES", "agreement": "NO", "peer": "02-round0-codex-attack", "findings": [{"id": "CLAUDE-1"}],
    "dispositions": ["CODEX-1: accepted — ok", "CODEX-2: disputed — unclear"], "blockers": ["CLAUDE-1", "CODEX-1"], "disputes": ["CODEX-2: not demonstrated"]}'
  gen_for "$order" 4 adversary '{"verdict": "REQUEST CHANGES", "agreement": "YES", "peer": "03-round1-claude-reconcile", "findings": [{"id": "CODEX-1"}],
    "dispositions": ["CLAUDE-1: accepted — ok"], "blockers": ["CLAUDE-1", "CODEX-1"], "disputes": ["CODEX-2: withdrawn by me, recorded for the record"]}'
  # shellcheck disable=SC2046
  run_gencr "earlier-$order" $(order_flags "$order")
  check "$order-first: a dispute about a finding from an earlier report is valid and does not make it a current finding" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 4 ] && ! json_get "$PKG/findings.json" "[f[\"id\"] for f in d[\"final_findings\"]]" | grep -q "${AP}-2"'
done

# ── 4. Phases: reconciliation replies follow the same rules ──

for order in claude codex; do
  if [ "$order" = claude ]; then AP=CODEX p=claude a=codex; else AP=CLAUDE p=codex a=claude; fi
  reset_mocks
  gen_for "$order" 1 primary '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1"}], "blockers": ["CLAUDE-1"]}'
  gen_for "$order" 2 adversary '{"verdict": "REQUEST CHANGES", "agreement": "NO", "peer": "01-round0-claude-initial",
    "findings": [{"id": "CODEX-1"}], "dispositions": ["CLAUDE-1: disputed — unclear"], "blockers": ["CODEX-1"], "disputes": ["CLAUDE-1: reachable?"]}'
  gen_for "$order" 3 primary '{"verdict": "REQUEST CHANGES", "agreement": "NO", "peer": "02-round0-codex-attack", "findings": [{"id": "CLAUDE-1"}],
    "dispositions": ["CODEX-1: accepted — ok"], "blockers": ["CLAUDE-1", "CODEX-1"],
    "notes": {"Disproven claims": "the reachability concern: the guard runs first", "Unresolved risks": "live API shape"}}'
  gen_for "$order" 4 adversary '{"verdict": "REQUEST CHANGES", "agreement": "YES", "peer": "03-round1-claude-reconcile", "findings": [{"id": "CODEX-1"}],
    "dispositions": ["CLAUDE-1: accepted — ok"], "blockers": ["CLAUDE-1", "CODEX-1"]}'
  edit_reply 4 "s.replace('  - Fix: apply the fix\n', '  - Fix: apply the fix\nUnresolved risks:\n- none known\n', 1)"
  # shellcheck disable=SC2046
  run_gencr "phase-$order" $(order_flags "$order")
  check "$order-first: a reconcile reply with populated notes is valid; a respond reply with observations in Findings is not" \
    eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 4 ] && contains "$ERR" "$(rid 4 1 "$a" respond) is invalid" && grep -qF -- "- Disproven claims: the reachability concern" "$PKG/$(rid 3 1 "$p" reconcile).report.md"'
  check "$order-first: the respond and reconcile prompts carry the same notes instructions" \
    eval 'grep -qF "  - \"## Review notes\": the last section" "$MOCK_STATE/call-3.stdin" && grep -qF "  - \"## Review notes\": the last section" "$MOCK_STATE/call-4.stdin"'
done

# ── 5. Incremental reviews: notes come after the incremental sections; older baselines without notes still work ──

INC_DIR="$WORK/inc reports"
reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Open"}], "blockers": ["CLAUDE-1"]}'
gen 2 "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"YES\", \"peer\": \"$(rid 1 0 claude initial)\", \"dispositions\": [\"CLAUDE-1: accepted — ok\"], \"blockers\": [\"CLAUDE-1\"]}"
run_gencr inc --codex=attack --output-dir="$INC_DIR" --pr-number=9
BASE="$WORK/old baseline"
cp -R "$(ls -d "$INC_DIR"/review-*)" "$BASE"
# Make it an older package: no review_notes in findings.json and no notes in full-report.md (manifest re-hashed).
python3 - "$BASE" <<'EOF'
import hashlib, json, os, re, sys
d = sys.argv[1]
f = json.load(open(os.path.join(d, "findings.json"))); f.pop("review_notes", None)
data = json.dumps(f, indent=2) + "\n"; open(os.path.join(d, "findings.json"), "w").write(data)
full = open(os.path.join(d, "full-report.md")).read()
full = re.sub(r"### Review notes\n.*?\n\n", "", full, flags=re.S); open(os.path.join(d, "full-report.md"), "w").write(full)
m = json.load(open(os.path.join(d, "manifest.json")))
for name in ("findings.json", "full-report.md"):
    m["files"][name] = hashlib.sha256(open(os.path.join(d, name), "rb").read()).hexdigest()
open(os.path.join(d, "manifest.json"), "w").write(json.dumps(m, indent=2) + "\n")
EOF
check "incremental baseline: an older package without review notes" eval '! grep -q "review_notes" "$BASE/findings.json" && ! grep -q "### Review notes" "$BASE/full-report.md"'
echo '# follow-up' >> "$TARGET/app.py"
git -C "$TARGET" commit -qam "follow-up"
for order in claude codex; do
  reset_mocks
  if [ "$order" = claude ]; then fl="--claude=review"; else fl="--codex=review"; fi
  gen 1 '{"verdict": "APPROVED", "verification": ["CLAUDE-1: fixed — corrected"], "notes": {"Verified clean": "the follow-up only adds a comment"}}'
  run_gencr inc $fl --incremental --output-dir="$INC_DIR" --pr-number=9 --previous="$BASE"
  PKG="$(ls -td "$INC_DIR"/review-* | head -n 1)"
  check "$order-reviewed incremental: an older baseline without notes is accepted; notes follow the incremental sections" \
    eval '[ "$STATUS" -eq 0 ] && [ "$(sed -n "/^## /p" "$PKG"/01-round0-*-initial.report.md | tail -n 1)" = "## Review notes" ] && grep -qF "the follow-up only adds a comment" "$PKG/full-report.md"'
  reset_mocks
  gen 1 '{"verdict": "APPROVED", "verification": ["CLAUDE-1: fixed — corrected"]}'
  touch "$MOCK_STATE/no-auto-dup-1"
  python3 - "$MOCK_STATE/responses/1" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
head, notes = s.split("## Review notes", 1)
notes_block, tail = notes.split("\nVERDICT:", 1)
verification = head[head.index("## Previous findings verification"):]
head = head[:head.index("## Previous findings verification")]
open(p, "w").write(head + "## Review notes" + notes_block + "\n" + verification.rstrip("\n") + "\n\n## Duplication check\n- SUBJ-1: no duplicate found — searched: mock query for SUBJ-1; compared: none\n\nVERDICT:" + tail)
EOF
  run_gencr inc $fl --incremental --output-dir="$INC_DIR" --pr-number=9 --previous="$BASE"
  check "$order-reviewed incremental: notes before the incremental sections are rejected" \
    eval '[ "$STATUS" -eq 20 ] && contains "$ERR" "'"'"'## Review notes'"'"' must be the last section"'
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
