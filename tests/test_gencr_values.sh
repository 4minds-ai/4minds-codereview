#!/usr/bin/env bash
# Field-value tests for bin/gencr: finding fields and "## Review notes" entries share one value grammar — text on the
# label line, a block of lines directly below it (indented at least two spaces deeper), or both — kept byte for byte
# (nested bullets, code, interior blank lines). Severity, File and Duplicate of are single lines. Outside a fenced code
# block no value line may look like report structure, so indented text can never stand for or swallow a field, finding,
# section or control line. Nothing is moved, dropped or invented. Replays a sanitized copy of a real failed review
# (tests/fixtures/multiline-values) in both reviewer orders. Mock reviewer CLIs; no network.
# Usage: bash tests/test_gencr_values.sh
# shellcheck disable=SC2016,SC2034  # deferred eval checks

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO/tests/fixtures/multiline-values"
WORK="$(cd -P "$(mktemp -d)" && pwd)/gencr values tests"
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


field_of() { json_get "$PKG/findings.json" "[f for f in d[\"final_findings\"] if f[\"id\"] == \"$1\" and f[\"reported_by\"] == \"$2\"][0][\"$3\"][\"$4\"]"; }
# A complete attack reply accepting the fixture's CLAUDE-1..6 (claude-first names).
attack_reply() {
  echo "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"YES\", \"peer\": \"01-round0-claude-initial\", \"blockers\": [\"CLAUDE-1\"],
    \"dispositions\": [\"CLAUDE-1: accepted — ok\", \"CLAUDE-2: accepted — ok\", \"CLAUDE-3: accepted — ok\", \"CLAUDE-4: accepted — ok\",
                       \"CLAUDE-5: accepted — ok\", \"CLAUDE-6: accepted — ok\"]}"
}
# value_case ORDER DESCRIPTION EXPECTED(empty = valid) PYTHON-EDIT [EXTRA-CHECK] — edits the initial fixture (single reviewer).
value_case() {
  local order="$1" desc="$2" expect="$3"
  reset_mocks
  fixture 1 01-claude-initial "$order"
  edit_reply 1 "$4"
  # shellcheck disable=SC2046
  run_gencr "case-$order" $( [ "$order" = claude ] && echo --claude=review || echo --codex=review )
  if [ -z "$expect" ]; then
    if [ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 1 ] && { [ -z "$5" ] || eval "$5"; }; then ok "$order-first: $desc"
    else not_ok "$order-first: $desc" "status=$STATUS err=$(printf '%s' "$ERR" | tail -n 2)"; fi
  elif [ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "$expect" &&
       cmp -s "$PKG/01-round0-$order-initial.report.md" "$MOCK_STATE/responses/1"; then ok "$order-first: $desc"
  else not_ok "$order-first: $desc" "status=$STATUS err=$(printf '%s' "$ERR" | tail -n 2)"; fi
}

# ── 1. The real failure, replayed: valid as written, nothing moved, everything kept ──

FIX1='- Add a test file for the form, mirroring the sibling form'"'"'s tests.
- Add a case for the new source to the panel test.
- Add backend tests for the download path: missing connection gives 404, a bad config gives 400, success returns one file.'
for order in claude codex; do
  if [ "$order" = claude ]; then P=Claude PP=CLAUDE p=claude a=codex; else P=Codex PP=CODEX p=codex a=claude; fi
  reset_mocks
  fixture 1 01-claude-initial "$order"
  gen_for "$order" 2 adversary "$(attack_reply)"
  # shellcheck disable=SC2046
  run_gencr "replay-$order" $(order_flags "$order")
  R1="$PKG/$(rid 1 0 "$p" initial)"
  check "$order-first replay: the report with block values is valid (exit 10, 2 calls) and needs no normalization" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 2 ] && cmp -s "$R1.report.md" "$MOCK_STATE/responses/1" && [ ! -e "$R1.report.original.md" ] && [ ! -e "$R1.normalization.json" ]'
  check "$order-first replay: findings.json keeps the three Fix actions byte for byte, with the block layout" \
    eval '[ "$(field_of "${PP}-1" "$p" fields Fix)" = "$FIX1" ] && [ "$(field_of "${PP}-1" "$p" layouts Fix)" = block ] && [ "$(field_of "${PP}-1" "$p" layouts Problem)" = inline+block ]'
  check "$order-first replay: the canonical full report shows the Fix as written (label, then the actions below it)" \
    eval 'awk "/^## Open findings/{f=1} f" "$PKG/full-report.md" | grep -A3 -xF -- "  - Fix:" | grep -qxF -- "    - Add a case for the new source to the panel test."'
  check "$order-first replay: the review comment shows every Fix action" \
    eval 'contains "$(block)" "Add a test file for the form" && contains "$(block)" "Add a case for the new source to the panel test." && contains "$(block)" "success returns one file."'
  check "$order-first replay: the notes keep their block values" \
    eval '[ "$(json_get "$PKG/findings.json" "d[\"review_notes\"][\"$p\"][\"Verified clean\"]")" = "- The API key never appears in client errors.
- The host is fixed and redirects are off.
- Pagination caps and cursor-cycle detection hold." ]'
  check "$order-first prompts: both reviewers get the same value rule, naming the three single-line fields" \
    eval 'grep -qF "Severity, File and Duplicate of are each one line of text on the field line, with nothing below it." "$MOCK_STATE/call-1.stdin" &&
          [ "$(sed "/^===== YOUR ROLE =====\$/,\$d" "$MOCK_STATE/call-1.stdin")" = "$(sed "/^===== YOUR ROLE =====\$/,\$d" "$MOCK_STATE/call-2.stdin")" ]'
done

# ── 2. Reconciliation rounds: the same values in reconcile and respond replies ──

RICH='Fix:
    - Guard the call:
      ```python
      if not key:

          raise ValueError("empty")
      ```

    - Add the test.'
for order in claude codex; do
  if [ "$order" = claude ]; then AP=CODEX PP=CLAUDE p=claude a=codex; else AP=CLAUDE PP=CODEX p=codex a=claude; fi
  reset_mocks
  gen_for "$order" 1 primary '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1"}], "blockers": ["CLAUDE-1"]}'
  gen_for "$order" 2 adversary '{"verdict": "REQUEST CHANGES", "agreement": "NO", "peer": "01-round0-claude-initial",
    "findings": [{"id": "CODEX-1"}], "dispositions": ["CLAUDE-1: accepted — ok"], "blockers": ["CLAUDE-1", "CODEX-1"]}'
  gen_for "$order" 3 primary '{"verdict": "REQUEST CHANGES", "agreement": "NO", "peer": "02-round0-codex-attack", "findings": [{"id": "CLAUDE-1"}],
    "dispositions": ["CODEX-1: accepted — ok"], "blockers": ["CLAUDE-1", "CODEX-1"]}'
  gen_for "$order" 4 adversary '{"verdict": "REQUEST CHANGES", "agreement": "YES", "peer": "03-round1-claude-reconcile", "findings": [{"id": "CODEX-1"}],
    "dispositions": ["CLAUDE-1: accepted — ok"], "blockers": ["CLAUDE-1", "CODEX-1"]}'
  # The reconcile reply's Fix and the respond reply's Evidence become rich blocks; their notes become blocks too.
  edit_reply 3 "s.replace('  - Fix: apply the fix', '  - ' + '''$RICH''', 1).replace('- Unresolved risks: None', '- Unresolved risks:\n  - café — unverified\r\n  - second', 1)"
  edit_reply 4 "s.replace('  - Evidence: evidence text', '  - Evidence:\n        deeper first line (an indented code block)\n    - then a bullet', 1)"
  # shellcheck disable=SC2046
  run_gencr "rounds-$order" $(order_flags "$order")
  check "$order-first rounds: block values in reconcile and respond replies are valid (exit 10, 4 calls)" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 4 ] && [ ! -e "$PKG/$(rid 3 1 "$p" reconcile).normalization.json" ]'
  check "$order-first rounds: a fenced code block with blank lines is kept exactly in findings.json and the summary" \
    eval '[ "$(field_of "${PP}-1" "$p" fields Fix)" = "- Guard the call:
  \`\`\`python
  if not key:

      raise ValueError(\"empty\")
  \`\`\`

- Add the test." ] && contains "$(block)" "raise ValueError(\"empty\")" && contains "$(block)" "- Add the test."'
  check "$order-first rounds: a deeper first block line and CR/Unicode note payload are kept" \
    eval '[ "$(field_of "${AP}-1" "$a" fields Evidence)" = "    deeper first line (an indented code block)
- then a bullet" ] && json_get "$PKG/findings.json" "repr(d[\"review_notes\"][\"$p\"][\"Unresolved risks\"])" | grep -qF "café — unverified\\r"'
done

# ── 3. Strict rejections (the report is kept byte for byte; nothing is repaired or moved) ──

for order in claude codex; do
  if [ "$order" = claude ]; then PP=CLAUDE; else PP=CODEX; fi
  value_case "$order" "a field with nothing on its line and nothing below is empty" "${PP}-3 has an empty Fix field" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix:', 1)"
  value_case "$order" "a block after a blank line is rejected" "the Fix value must start on the line directly below its label" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix:\n\n    - late action', 1)"
  value_case "$order" "inline text, a blank line, then a block is rejected" "the Fix value must start on the line directly below its label" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix: synthetic fix 3\n\n    - late action', 1)"
  value_case "$order" "a block Severity is rejected" "${PP}-3: Severity must be a single line on its field line" \
    "s.replace('  - Severity: Medium\n  - File: app.py:3', '  - Severity:\n    Medium\n  - File: app.py:3', 1)"
  value_case "$order" "a File with a continuation is rejected" "${PP}-3: File must be a single line on its field line" \
    "s.replace('  - File: app.py:3', '  - File: app.py:3\n    and app.py:4', 1)"
  value_case "$order" "a line between the field and its block anchor is rejected" "is outside any field" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix:\n   - three spaces', 1)"
  value_case "$order" "an unknown field label is rejected" "has an unknown field label" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix: synthetic fix 3\n  - Notes: extra', 1)"
  value_case "$order" "a repeated field is rejected" "repeats the field Fix" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix: synthetic fix 3\n  - Fix: again', 1)"
  value_case "$order" "a missing field is rejected" "is missing the field(s): Tests" \
    "s.replace('  - Tests: none detect it\n  - Fix: synthetic fix 3', '  - Fix: synthetic fix 3', 1)"
  value_case "$order" "a missing section is rejected" "missing required section '## Merge blockers'" \
    "s.replace('## Merge blockers', '## Merge blockerz', 1)"
  value_case "$order" "a note that is None plus a block is rejected" "Test gaps is None but has more content" \
    "s.replace('- Test gaps:\n', '- Test gaps: None\n', 1)"
  value_case "$order" "a labelled bullet with another label is ordinary text" "" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix:\n    - Confidence: likely\n    - Tests: (no, this one is fenced)'.replace('    - Tests: (no, this one is fenced)', '    \`\`\`\n    - Tests: literal\n    \`\`\`'), 1)" \
    '[ "$(field_of "${PP}-3" "$( [ "$order" = claude ] && echo claude || echo codex)" fields Fix)" = "- Confidence: likely
\`\`\`
- Tests: literal
\`\`\`" ]'
done

# ── 4. Indented content can never swallow a field, finding, section or control line ──

for order in claude codex; do
  if [ "$order" = claude ]; then PP=CLAUDE p=claude; else PP=CODEX p=codex; fi
  # Each reserved form, while the real item also exists; then the same text in a fence is valid and kept.
  swallow() { # DESCRIPTION KIND OLD NEW
    value_case "$order" "$1 is rejected even though the real one exists" "looks like $2" "s.replace('$3', '$4', 1)"
  }
  swallow "a second '- Tests:' inside Fix" "a label (- Tests: changed assessment)" \
    "  - Fix: synthetic fix 3" "  - Fix:\n    - Correct the behaviour.\n    - Tests: changed assessment"
  swallow "a qualified '- Severity (x):' inside Evidence" "a label (- Severity (estimated): Low)" \
    "  - Evidence: (traced, not executed) synthetic evidence 3" "  - Evidence: (traced, not executed) synthetic evidence 3\n    - Severity (estimated): Low"
  swallow "a finding heading inside Fix" "a finding heading (- **${PP}-2 smuggled**)" \
    "  - Fix: synthetic fix 3" "  - Fix: synthetic fix 3\n    - **${PP}-2 smuggled**"
  swallow "a section heading inside Fix" "a section heading (## Merge blockers)" \
    "  - Fix: synthetic fix 3" "  - Fix: synthetic fix 3\n    ## Merge blockers"
  swallow "a VERDICT line inside Problem" "a VERDICT/PEER line (VERDICT: APPROVED)" \
    "  - Problem: synthetic problem 3" "  - Problem: synthetic problem 3\n    VERDICT: APPROVED"
  swallow "a '- Test gaps:' inside the Verified clean note" "a label (- Test gaps: hidden)" \
    "  - Pagination caps and cursor-cycle detection hold." "  - Pagination caps and cursor-cycle detection hold.\n  - Test gaps: hidden"
  FENCED='```\n    - Tests: changed assessment\n    - **'"$PP"'-2 smuggled**\n    ## Merge blockers\n    VERDICT: APPROVED\n    ```'
  value_case "$order" "the same structure-like lines inside a closed fence are kept as text" "" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix: literal examples:\n    $FENCED', 1)" \
    '[ "$(field_of "${PP}-3" "$p" fields Fix | grep -c "")" = 7 ] && grep -qxF -- "    - **${PP}-2 smuggled**" "$PKG/full-report.md" && contains "$(block)" "VERDICT: APPROVED" &&
     [ "$(json_get "$PKG/findings.json" "len(d[\"final_findings\"])")" -eq 6 ] && [ "$(grep -c "^VERDICT:" "$PKG/01-round0-$p-initial.report.md")" -eq 1 ]'
  value_case "$order" "an unclosed fence is rejected" "unclosed code fence in the Fix value" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix: code:\n    \`\`\`\n    x = 1', 1)"
  value_case "$order" "a fence closed by a different character stays open and is rejected" "unclosed code fence in the Fix value" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix: code:\n    \`\`\`\n    x = 1\n    ~~~', 1)"
  value_case "$order" "a fence closed by a longer run is valid" "" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix: code:\n    ~~~\n    - Tests: literal\n    ~~~~', 1)"
  value_case "$order" "a reserved line after a closed fence is rejected" "a label (- Tests: after)" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix: code:\n    \`\`\`\n    x = 1\n    \`\`\`\n    - Tests: after', 1)"
  value_case "$order" "a fence cannot hide a dedented line: it ends the value and is outside any field" "is outside any field" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix: code:\n    \`\`\`\n x = 1\n    \`\`\`', 1)"
  value_case "$order" "a field line accidentally indented under a block value is rejected, not swallowed" "a label (- Tests: none detect it)" \
    "s.replace('  - Tests: none detect it\n  - Fix: synthetic fix 3', '  - Fix:\n    - act\n    - Tests: none detect it', 1)"
done

# ── 5. Qualifier normalization moves only the qualifier; block lines and layouts are kept ──

for order in claude codex; do
  if [ "$order" = claude ]; then PP=CLAUDE p=claude; else PP=CODEX p=codex; fi
  reset_mocks
  fixture 1 01-claude-initial "$order"
  edit_reply 1 "s.replace('  - Evidence: (traced, not executed)\n', '  - Evidence (traced, not executed):\n', 1).replace('  - Severity: Low', '  - Severity (estimated): Low', 1)"
  # shellcheck disable=SC2046
  run_gencr "qual-$order" $( [ "$order" = claude ] && echo --claude=review || echo --codex=review )
  R1="$PKG/01-round0-$p-initial"
  check "$order-first: a qualified block-only field is normalized: only its label line changes, every body line kept" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(json_get "$R1.normalization.json" "d[\"result\"]")" = normalized ] &&
          [ "$(diff "$R1.report.original.md" "$R1.report.md" | grep -c "^[<>]")" -eq 4 ] && [ "$(wc -l < "$R1.report.md")" = "$(wc -l < "$R1.report.original.md")" ] &&
          [ "$(field_of "${PP}-1" "$p" fields Evidence)" = "(traced, not executed)
- No test file matches the form'"'"'s name.
- The panel test has no case for the new source.
- The backend tests call the renderer directly, never the provider." ] && [ "$(field_of "${PP}-1" "$p" layouts Evidence)" = inline+block ] &&
          [ "$(field_of "${PP}-6" "$p" fields Severity)" = "(estimated) Low" ]'
  value_case "$order" "a qualified scalar written as a block is still rejected" "File must be a single line on its field line" \
    "s.replace('  - File: app.py:3', '  - File (approx):\n    app.py:3', 1)"
done

# ── 6. Revision 1 (codex MLV-I1..I3): header whitespace stays on its line, every "## " is reserved, the proof
#       compares layouts ──

# round_trip FILE — renders every finding field the way the canonical report does and parses it again: no errors and
# identical values and layouts.
round_trip() {
  python3 -B - "$REPO/bin" "$1" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import gencr_report as g, gencr_support as s
parsed = g.parse(open(sys.argv[2], encoding="utf-8", newline="").read())
assert not parsed["errors"], parsed["errors"]
out = ["## Findings"]
for f in parsed["findings"]:
    out.append(f["heading"])
    for field in f["fields"]:
        out += s.field_lines("  ", field["label"], "\n".join(field["lines"]), field["layout"])
again = g.parse("\n".join(out) + "\n")
assert not again["errors"], again["errors"]
assert [(f["id"], f["values"], f["layouts"]) for f in again["findings"]] == \
       [(f["id"], f["values"], f["layouts"]) for f in parsed["findings"]], "values or layouts changed"
print("round trip ok")
EOF
}
for order in claude codex; do
  if [ "$order" = claude ]; then PP=CLAUDE p=claude; else PP=CODEX p=codex; fi
  for ws in '\r' '\t' '\u00a0'; do  # CR, tab and no-break space (escapes decoded by Python)
    value_case "$order" "a header ending in $ws before a block keeps it on the header line (inline+block)" "" \
      "s.replace('  - Fix: synthetic fix 3', '  - Fix:$ws\n    - First action\n    - Second action', 1)" \
      '[ "$(field_of "${PP}-3" "$p" layouts Fix)" = inline+block ] && round_trip "$PKG/01-round0-$p-initial.report.md" | grep -qx "round trip ok" &&
       python3 -c "import sys; l = open(sys.argv[1], encoding=\"utf-8\", newline=\"\").read().split(\"\n\"); i = l.index(\"  - Fix: \" + sys.argv[2].encode(\"utf-8\", \"surrogateescape\").decode(\"utf-8\")); sys.exit(0 if l[i + 1] == \"    - First action\" else 1)" "$PKG/full-report.md" "$(python3 -c "import codecs, sys; sys.stdout.write(codecs.decode(sys.argv[1], \"unicode_escape\"))" "$ws")"'
    value_case "$order" "a header with only $ws and nothing below is empty" "${PP}-3 has an empty Fix field" \
      "s.replace('  - Fix: synthetic fix 3', '  - Fix:$ws', 1)"
  done
  value_case "$order" "a notes label ending in a CR before a block keeps it on the label line" "" \
    "s.replace('- Verified clean:\n', '- Verified clean:\r\n', 1)" \
    'json_get "$PKG/findings.json" "repr(d[\"review_notes\"][\"$p\"][\"Verified clean\"][:3])" | grep -qxF "'"'"'\\r\\n-'"'"'"'
  for heading in '##  Merge blockers' '## \tMerge blockers' '##   Unknown section'; do
    value_case "$order" "'$heading' inside Fix is reserved like any '## ' heading" "a section heading" \
      "s.replace('  - Fix: synthetic fix 3', '  - Fix: synthetic fix 3\n    $heading', 1)"
    value_case "$order" "'$heading' inside a note is reserved" "a section heading" \
      "s.replace('  - Pagination caps and cursor-cycle detection hold.', '  - Pagination caps and cursor-cycle detection hold.\n  $heading', 1)"
    value_case "$order" "'$heading' inside a fence is literal text" "" \
      "s.replace('  - Fix: synthetic fix 3', '  - Fix: example:\n    \`\`\`\n    $heading\n    \`\`\`', 1)"
  done
  value_case "$order" "a fence 'closed' by a line with a trailing tab stays open (spaces only)" "unclosed code fence in the Fix value" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix: code:\n    \`\`\`\n    x = 1\n    \`\`\`\t', 1)"
  value_case "$order" "a fence closed by a line with trailing spaces is closed" "" \
    "s.replace('  - Fix: synthetic fix 3', '  - Fix: code:\n    \`\`\`\n    x = 1\n    \`\`\`   ', 1)"
done

# The independent proof rejects any change of a value's layout other than the authorized qualifier move, and the
# real normalize-report gate refuses such a candidate (fault injection).
proof_case() { # ORIGINAL-EDIT CANDIDATE-EDIT
  python3 -B - "$REPO/bin" "$FIXTURES/01-claude-initial.md" "$1" "$2" <<'EOF'
import argparse, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import gencr_report as g, gencr_support as s
base = open(sys.argv[2]).read()
original = eval(sys.argv[3], {"s": base})
candidate = eval(sys.argv[4], {"s": g.normalize(original)[0]})
problems = g.prove(original, candidate)
real = g.normalize
g.normalize = lambda text: (candidate, real(text)[1], [])
work = tempfile.mkdtemp()
src = os.path.join(work, "orig.md")
open(src, "w").write(original)
args = argparse.Namespace(original=src, out=os.path.join(work, "out.md"), record=os.path.join(work, "rec.json"),
                          canonical="out.md")
code = s.cmd_normalize_report(args)
print("rejected" if problems and code == 3 and not os.path.exists(args.out) else "accepted: %r %r" % (problems, code))
EOF
}
QUAL="s.replace('  - Evidence: (traced, not executed)\n', '  - Evidence (traced, not executed):\n', 1)"
check "proof: an unsolicited lift of a block Fix onto its label line is rejected (normalize-report refuses it)" \
  eval '[ "$(proof_case "$QUAL" "s.replace(\"  - Fix:\n    - Add a test file\", \"  - Fix: - Add a test file\", 1)" 2>/dev/null)" = rejected ]'
check "proof: the reverse move (inline text pushed into a block) is rejected" \
  eval '[ "$(proof_case "$QUAL" "s.replace(\"  - Fix: synthetic fix 3\", \"  - Fix:\n    synthetic fix 3\", 1)" 2>/dev/null)" = rejected ]'
check "proof: the authorized qualifier move alone is accepted" \
  eval 'python3 -B -c "import sys; sys.path.insert(0, sys.argv[1]); import gencr_report as g; o = open(sys.argv[2]).read().replace(\"  - Evidence: (traced, not executed)\n\", \"  - Evidence (traced, not executed):\n\", 1); n = g.normalize(o)[0]; sys.exit(0 if n and not g.prove(o, n) else 1)" "$REPO/bin" "$FIXTURES/01-claude-initial.md"'

# ── 7. Layouts survive into the next incremental review; older baselines without layouts still work ──

INC_DIR="$WORK/inc reports"
reset_mocks
fixture 1 01-claude-initial claude
run_gencr inc --claude=review --output-dir="$INC_DIR" --pr-number=11
FRESH="$(ls -d "$INC_DIR"/review-*)"
check "incremental baseline: a fresh review whose CLAUDE-1 Fix is a block" eval '[ "$STATUS" -eq 10 ] && grep -qxF -- "  - Fix:" "$FRESH/full-report.md"'
OLD="$WORK/old baseline"
cp -R "$FRESH" "$OLD"
python3 - "$OLD" <<'EOF'
import hashlib, json, os, sys
d = sys.argv[1]
f = json.load(open(os.path.join(d, "findings.json")))
for finding in f["final_findings"]:
    finding.pop("layouts", None)
data = json.dumps(f, indent=2) + "\n"; open(os.path.join(d, "findings.json"), "w").write(data)
m = json.load(open(os.path.join(d, "manifest.json"))); m["files"]["findings.json"] = hashlib.sha256(data.encode()).hexdigest()
open(os.path.join(d, "manifest.json"), "w").write(json.dumps(m, indent=2) + "\n")
EOF
echo '# follow-up' >> "$TARGET/app.py"
git -C "$TARGET" commit -qam "follow-up"
for base in "$FRESH" "$OLD"; do
  reset_mocks
  gen 1 '{"verdict": "APPROVED", "verification": ["CLAUDE-1: fixed — tests added", "CLAUDE-2: fixed — panel registered", "CLAUDE-3: fixed — x", "CLAUDE-4: fixed — x", "CLAUDE-5: fixed — x", "CLAUDE-6: fixed — x"]}'
  run_gencr inc --claude=review --incremental --output-dir="$INC_DIR" --pr-number=11 --previous="$base"
  name="$( [ "$base" = "$OLD" ] && echo "an older baseline without layouts" || echo "the baseline")"
  check "incremental from $name: the prompt shows the previous Fix as written, never lifted" \
    eval '[ "$STATUS" -eq 0 ] && grep -qxF -- "  - Fix:" "$MOCK_STATE/call-1.stdin" && grep -qxF -- "    - Add a case for the new source to the panel test." "$MOCK_STATE/call-1.stdin" && ! grep -qF -- "- Fix: - Add" "$MOCK_STATE/call-1.stdin"'
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
