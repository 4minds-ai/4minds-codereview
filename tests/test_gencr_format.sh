#!/usr/bin/env bash
# Report grammar tests for bin/gencr: complete multiline field values, strict field boundaries, and deterministic
# format normalization (no reviewer call) with its independent proof. Mock reviewer CLIs; no network.
# Usage: bash tests/test_gencr_format.sh
# shellcheck disable=SC2016,SC2034  # deferred eval checks

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd -P "$(mktemp -d)" && pwd)/gencr format tests"
mkdir -p "$WORK"
trap 'rm -rf "$(dirname "$WORK")"' EXIT

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
not_ok() { FAIL=$((FAIL + 1)); echo "not ok - $1"; [ -z "$2" ] || printf '%s\n' "$2" | sed 's/^/    # /'; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else not_ok "$desc" "status=${STATUS:-} err=${ERR:-}"; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); exec("print(" + sys.argv[2] + ")")' "$1" "$2"; }
# grammar 'PYTHON' — runs Python with the report grammar module imported as g.
grammar() { local code="$1"; shift; python3 -B -c "import sys; sys.path.insert(0, '$REPO/bin'); import gencr_report as g; $code" "$@"; }

export HOME="$WORK/home"
mkdir -p "$HOME"
MOCK_BIN="$WORK/mock bin"
export MOCK_STATE="$WORK/mock state"
mkdir -p "$MOCK_BIN"
cp "$REPO/tests/mocks/mock_reviewer.py" "$MOCK_BIN/mock_reviewer.py"
ln -s mock_reviewer.py "$MOCK_BIN/claude"
ln -s mock_reviewer.py "$MOCK_BIN/codex"
export PATH="$MOCK_BIN:$PATH"
unset CODEREVIEW_BASE_BRANCH MOCK_VERDICT

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
mkdir -p "$TARGET/src"
printf 'def handler():\n    return 1\n' > "$TARGET/src/app.py"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm feature

reset_mocks() { rm -rf "$MOCK_STATE"; mkdir -p "$MOCK_STATE/responses"; }
calls() { cat "$MOCK_STATE/count" 2>/dev/null || echo 0; }
rid() { printf '%02d-round%d-%s-%s' "$1" "$2" "$3" "$4"; }
OUTDIR="$WORK/out"
run_gencr() {
  rm -rf "$OUTDIR"
  (cd "$TARGET" && "$REPO/bin/gencr" dev --output-dir="$OUTDIR" "$@") > "$WORK/stdout" 2> "$WORK/stderr"
  STATUS=$?; ERR="$(cat "$WORK/stderr")"
  PKG="$(ls -td "$OUTDIR"/review-* 2>/dev/null | head -n 1)"
}

# malformed PREFIX — the five malformed shapes of the real failing report (anonymized): a nested-only Fix with
# nested sub-items, qualified Evidence labels (nested numbered list, inline, other qualifier) and a nested-only
# Problem; trailing spaces and a backslash continuation in code evidence are payload.
malformed() {
  local p="$1"
  cat <<EOF
## Findings
- **${p}-1 Settings modal has no tests**
  - Severity: High
  - File: src/app.py:1
  - Problem: the modal component ships without tests
  - Evidence: no test file references the component
  - Expected vs actual: expected component tests; actual none
  - Tests: none
  - Fix:
    - Add a test file covering:
      - connected and disconnected status load
      - status-load error
    - Keep the existing fixtures
- **${p}-2 Imported config breaks the scheduled sync**
  - Severity: High
  - File: src/app.py:2
  - Problem: an empty config is accepted at import and rejected later
  - Evidence (traced, not executed):
    1. The client sends \`{"source_config": {}}\`.
    2. The import succeeds and stores \`enabled=True\`.
       \`\`\`python
       result = 1 + \\
           2
       \`\`\`
    3. The first scheduled run fails with 0 requests sent.
  - Expected vs actual: expected rejection at import; actual a later failure
  - Tests: none cover the scheduled path
  - Fix: validate at import
- **${p}-3 Status is reported as success**
  - Severity: Medium
  - File: src/app.py:2
  - Problem: the stored status says success before any run
  - Evidence (traced, not executed): import with the complete config, then read the status; it is "success" != "pending"
  - Expected vs actual: expected pending; actual success
  - Tests: none
  - Fix: store pending
- **${p}-5 Concurrent saves race**
  - Severity: Medium
  - File: src/app.py:1
  - Problem: two saves can interleave
  - Evidence (interleaving, not executed): save A reads, save B writes, save A writes stale data
  - Expected vs actual: expected serialized saves; actual lost update
  - Tests: none
  - Fix: lock the row
- **${p}-10 Downloads are unbounded**
  - Severity: High
  - File: src/app.py:1
  - Problem:
    - No size limit, so up to 256 MiB is read into memory.
    - The deadline is checked only between pages.

    - The client is not closed on error.
  - Evidence: code reading.
  - Expected vs actual: expected bounded reads; actual unbounded
  - Tests: none
  - Fix: add a bounded download
EOF
}
# report N AGENT VERDICT AGREEMENT PEER [BODY_FILE] — a queued response; findings from BODY_FILE (default: malformed).
report() {
  local n="$1" agent="$2" verdict="$3" agreement="$4" peer="$5" body="${6:-}" up peer_up blockers disposition
  up="$(echo "$agent" | tr '[:lower:]' '[:upper:]')"
  if [ "$up" = CLAUDE ]; then peer_up=CODEX; else peer_up=CLAUDE; fi
  blockers="- None"; [ "$verdict" = "REQUEST CHANGES" ] && blockers="- ${up}-1"
  disposition="- None"
  if [ "$peer" != N/A ]; then
    disposition="$(for k in 1 2 3 5 10; do printf -- '- %s-%s: disputed — needs evidence\n' "$peer_up" "$k"; done)"
  fi
  {
    echo "Report from ${agent}."
    echo
    if [ -n "$body" ]; then cat "$body"; else malformed "$up" | sed 's/1 + \\$/1 + \\ /'; fi
    printf '\n## Disposition of peer findings\n%s\n\n## Merge blockers\n%s\n\n## Outstanding disputed findings\n- None\n\n## Review notes\n- Verified clean: None\n- Unresolved risks: None\n- Disproven claims: None\n- Test gaps: None\n- Out-of-scope ownership changes: None\n- Other observations: None\n\n' \
      "$disposition" "$blockers"
    printf 'VERDICT: %s\nPEER-AGREEMENT: %s\nPEER-REPORT: %s\n' "$verdict" "$agreement" "$peer"
  } > "$MOCK_STATE/responses/$n"
}

# ── Grammar: complete values and strict boundaries ─────────────────────────────

# The trailing space after the backslash is payload (heredocs cannot carry it reliably, so it is added here).
malformed CLAUDE | sed 's/1 + \\$/1 + \\ /' > "$WORK/malformed.md"
grammar '
r = g.parse(open(sys.argv[1]).read(), repairable=True)
print(sorted((x["id"], x["label"], x["form"]) for x in r["repairs"]))
print(r["errors"])' "$WORK/malformed.md" > "$WORK/plan" 2>&1
check "the real failure shapes: block values are valid as written; only the three qualifiers are repairs" \
  eval 'grep -qxF "[('"'"'CLAUDE-2'"'"', '"'"'Evidence'"'"', '"'"'qualifier'"'"'), ('"'"'CLAUDE-3'"'"', '"'"'Evidence'"'"', '"'"'qualifier'"'"'), ('"'"'CLAUDE-5'"'"', '"'"'Evidence'"'"', '"'"'qualifier'"'"')]" "$WORK/plan" && grep -qxF "[]" "$WORK/plan"'

# value FILE ID LABEL — the parsed (strict) value of a field, exactly.
value() { grammar 'f = [x for x in g.parse(open(sys.argv[1]).read())["findings"] if x["id"] == sys.argv[2]][0]; sys.stdout.write(f["values"].get(sys.argv[3], "<missing>"))' "$@"; }
cat > "$WORK/multi.md" <<'EOF'
## Findings
- **CLAUDE-1 T**
  - Severity: High
  - File: a.py:1
  - Problem: first line  
    second line, deeper
      - nested child
  - Evidence: trailing space kept
    ```
    x = 1 + \
        2
    ```

    after an interior blank
  - Expected vs actual: e
  - Tests: covers it:
    ```
    - Evidence: this is Tests text, not a field
    ```
  - Fix: one
    two
## Merge blockers
- None
EOF
check "multiline Problem keeps every line and relative nesting" \
  eval '[ "$(value "$WORK/multi.md" CLAUDE-1 Problem)" = "first line  
second line, deeper
  - nested child" ]'
check "evidence payload is byte-exact (trailing spaces, backslash-space, interior blank line)" \
  eval '[ "$(value "$WORK/multi.md" CLAUDE-1 Evidence)" = "trailing space kept
\`\`\`
x = 1 + \\
    2
\`\`\`

after an interior blank" ]'
check "a fenced label lookalike is value text of its field, not a field" \
  eval '[ "$(value "$WORK/multi.md" CLAUDE-1 Tests)" = "covers it:
\`\`\`
- Evidence: this is Tests text, not a field
\`\`\`" ]'
check "multiline Fix keeps its continuation" eval '[ "$(value "$WORK/multi.md" CLAUDE-1 Fix)" = "one
two" ]'
grammar 'print(g.parse(open(sys.argv[1]).read())["errors"])' "$WORK/multi.md" > "$WORK/errs"
check "a well-formed multiline report has no structural errors" eval 'grep -qxF "[]" "$WORK/errs"'

# structural CASE — errors of a finding body (fields after the heading) in the strict grammar.
structural() {
  printf '## Findings\n- **CLAUDE-1 T**\n%s\n## Merge blockers\n- None\n' "$1" > "$WORK/case.md"
  grammar 'print("; ".join(g.parse(open(sys.argv[1]).read())["errors"]))' "$WORK/case.md"
}
FIELDS_OK='  - Severity: High
  - File: a.py:1
  - Problem: p
  - Evidence: e
  - Expected vs actual: x
  - Tests: t
  - Fix: f'
check "lookalike Evidence inside Tests does not satisfy a missing Evidence field" \
  eval 'contains "$(structural "  - Severity: High
  - File: a.py:1
  - Problem: p
  - Expected vs actual: x
  - Tests: this fixture contains:
    - Evidence: no failure observed
  - Fix: f")" "finding CLAUDE-1 has no Evidence field"'
check "a repeated field is an error" eval 'contains "$(structural "$FIELDS_OK
  - Fix: again")" "repeats the field Fix"'
check "an unknown field label is an error, not silently dropped" eval 'contains "$(structural "$FIELDS_OK
  - Notes: extra")" "unknown field label"'
check "text at field level that is not a field is an error" eval 'contains "$(structural "$FIELDS_OK
  plain text")" "outside any field"'
check "a line indented between the field and its value anchor is an error" eval 'contains "$(structural "$FIELDS_OK
   three spaces")" "outside any field"'
check "tab indentation is an error" eval 'contains "$(structural "$(printf "%s\n\t- tabbed" "$FIELDS_OK")")" "tab"'
printf '## Findings\n- None\n\n## Findings\n- **CLAUDE-1 T**\n%s\n## Merge blockers\n- None\n' "$FIELDS_OK" > "$WORK/dup.md"
check "a second '## Findings' section is an error, not silently ignored" \
  eval 'contains "$(grammar "print(g.parse(open(sys.argv[1]).read())[\"errors\"])" "$WORK/dup.md")" "more than one '"'"'## Findings'"'"' section"'
check "an empty field is an error" eval 'contains "$(structural "${FIELDS_OK/Fix: f/Fix:}")" "empty Fix field"'
check "an unfenced label lookalike inside a value is an error, even though the real field exists" \
  eval 'contains "$(structural "${FIELDS_OK/Tests: t/Tests: covers it:
    - Evidence: looks like a field}")" "inside the Tests value looks like a label (- Evidence: looks like a field)"'

# ── Normalization: only formatting moves; everything else is irreparable ───────

normalize() { # FILE -> NORMALIZED, RECORD, NSTATUS
  python3 -B "$REPO/bin/gencr_support.py" normalize-report --original "$1" --out "$WORK/normalized.md" \
    --record "$WORK/record.json" --canonical normalized.md > "$WORK/nout" 2> "$WORK/nerr"
  NSTATUS=$?
}
rm -f "$WORK/normalized.md"
normalize "$WORK/malformed.md"
check "the real failure shapes normalize and are proven formatting-only" \
  eval '[ "$NSTATUS" -eq 0 ] && [ "$(json_get "$WORK/record.json" "d[\"result\"]")" = normalized ]'
check "the normalized report passes the structural check" \
  eval 'python3 -B "$REPO/bin/gencr_support.py" check-report --report "$WORK/normalized.md"'
check "normalized values: lifted first item, qualifier at the start of the value, children and code exact" \
  eval '[ "$(value "$WORK/normalized.md" CLAUDE-1 Fix)" = "- Add a test file covering:
  - connected and disconnected status load
  - status-load error
- Keep the existing fixtures" ] && [ "$(value "$WORK/normalized.md" CLAUDE-3 Evidence)" = "(traced, not executed) import with the complete config, then read the status; it is \"success\" != \"pending\"" ] &&
  [ "$(value "$WORK/normalized.md" CLAUDE-2 Evidence | sed -n 5p)" = "   result = 1 + \\ " ] &&
  [ "$(value "$WORK/normalized.md" CLAUDE-10 Problem | sed -n 3p)" = "" ]'
check "normalization changes only the three qualified header lines; no line is moved or removed" \
  eval '[ "$(diff "$WORK/malformed.md" "$WORK/normalized.md" | grep -c "^<")" -eq 3 ] && [ "$(diff "$WORK/malformed.md" "$WORK/normalized.md" | grep -c "^>")" -eq 3 ] &&
        [ "$(wc -l < "$WORK/malformed.md")" = "$(wc -l < "$WORK/normalized.md")" ]'

irreparable() { # DESCRIPTION BODY EXPECTED-ERROR
  printf '## Findings\n- **CLAUDE-1 T**\n%s\n## Merge blockers\n- None\n' "$2" > "$WORK/irr.md"
  rm -f "$WORK/normalized.md"
  normalize "$WORK/irr.md"
  if [ "$NSTATUS" -eq 3 ] && [ ! -e "$WORK/normalized.md" ] && grep -qF -- "$3" "$WORK/record.json" \
      && [ "$(json_get "$WORK/record.json" "d[\"result\"]")" = irreparable ]; then ok "irreparable: $1"
  else not_ok "irreparable: $1" "$(cat "$WORK/nerr")"; fi
}
irreparable "a value that starts after a blank line" "${FIELDS_OK/Fix: f/Fix:

    - after a blank}" "must start on the line directly below its label"
check "a block whose first line is deeper than its anchor is valid (an indented code block)" \
  eval '[ -z "$(structural "${FIELDS_OK/Fix: f/Fix:
      deeper code line
    - then a bullet}")" ]'
irreparable "a missing field" "${FIELDS_OK/  - Evidence: e
/}" "has no Evidence field"
irreparable "a lookalike-only Evidence" "  - Severity: High
  - File: a.py:1
  - Problem: p
  - Expected vs actual: x
  - Tests: t:
    - Evidence: lookalike
  - Fix:
    - f" "has no Evidence field"
irreparable "an empty field with nothing nested" "${FIELDS_OK/Fix: f/Fix:}" "empty Fix field"
irreparable "a qualifier with parentheses" "${FIELDS_OK/Evidence: e/Evidence (a (b)):}" "unknown field label"
printf '## Findings\n- **CLAUDE-1 T**\n%s\n## Merge blockers\n- None\n' "$FIELDS_OK" > "$WORK/valid.md"
normalize "$WORK/valid.md"
check "a report with no repairable formatting problem is not 'normalized'" \
  eval '[ "$NSTATUS" -eq 3 ] && contains "$(cat "$WORK/nerr")" "no repairable formatting problem"'

# normalize-report refuses a transformer result that the independent proof rejects.
python3 -B - "$REPO/bin" "$WORK/malformed.md" "$WORK/forced.md" "$WORK/forced.json" > "$WORK/forced.out" 2> "$WORK/forced.err" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import gencr_report, gencr_support
real = gencr_report.normalize
def tampered(text):
    normalized, repairs, errors = real(text)
    return normalized.replace("with 0 requests", "with 8 requests"), repairs, errors
gencr_report.normalize = tampered
class Args: original, out, record, canonical = sys.argv[2], sys.argv[3], sys.argv[4], "forced.md"
sys.exit(gencr_support.cmd_normalize_report(Args))
EOF
FSTATUS=$?
check "normalize-report refuses a transformer output that the proof rejects" \
  eval '[ "$FSTATUS" -eq 3 ] && [ ! -e "$WORK/forced.md" ] && [ "$(json_get "$WORK/forced.json" "d[\"result\"]")" = irreparable ] && grep -qF "could not be proven formatting-only" "$WORK/forced.json"'

# ── Proof gate: an altered "normalized" report is rejected (independent of the transformer) ──

rm -f "$WORK/normalized.md"
normalize "$WORK/malformed.md"
cp "$WORK/normalized.md" "$WORK/good.md"
tamper() { # DESCRIPTION SED-OR-PYTHON-EXPRESSION (python: s -> s)
  # The mutation must apply, and prove() must run and report a problem (an import error is not a rejection).
  grammar 's0 = open(sys.argv[1]).read(); s = s0; s = '"$2"'; assert s != s0, "mutation did not apply"
print("; ".join(g.prove(open(sys.argv[2]).read(), s)) or "ACCEPTED")' "$WORK/good.md" "$WORK/malformed.md" > "$WORK/proof" 2>&1
  if [ $? -eq 0 ] && [ -s "$WORK/proof" ] && ! grep -qx ACCEPTED "$WORK/proof"; then ok "proof rejects: $1"; else not_ok "proof rejects: $1" "$(cat "$WORK/proof")"; fi
}
check "proof accepts the deterministic normalization" \
  eval '[ "$(grammar "print(g.prove(open(sys.argv[1]).read(), open(sys.argv[2]).read()))" "$WORK/malformed.md" "$WORK/good.md")" = "[]" ]'
tamper "a dropped finding" 's[:s.index("- **CLAUDE-3")] + s[s.index("- **CLAUDE-5"):]'
tamper "a dropped short negation" 's.replace("an empty config is accepted", "an empty config is not accepted")'
tamper "a fabricated number" 's.replace("with 0 requests", "with 8 requests")'
tamper "swapped Evidence and Tests values" 's.replace("  - Evidence: code reading.\n", "  - Evidence: none\n").replace("  - Tests: none\n  - Fix: add a bounded", "  - Tests: code reading.\n  - Fix: add a bounded")'
tamper "a sentence moved into another field" 's.replace("  - Tests: none cover the scheduled path\n", "  - Tests: none cover the scheduled path validate at import\n")'
tamper "!= changed to ==" 's.replace("\"success\" != \"pending\"", "\"success\" == \"pending\"")'
tamper "a removed trailing space in code evidence" 's.replace("1 + \\ \n", "1 + \\\n")'
tamper "text added outside the findings" 's.replace("## Findings\n", "## Findings\nInjected note.\n")'
tamper "a reordered word" 's.replace("validate at import", "import at validate")'
tamper "a lost nesting level" 's.replace("      - connected", "    - connected")'
printf 'x\n%s\n\n## Disposition of peer findings\n- CODEX-1: accepted — confirmed\n  - also seen in the logs\n\n## Merge blockers\n- None\n\nVERDICT: APPROVED\nPEER-AGREEMENT: YES\nPEER-REPORT: 01-round0-codex-initial\n' \
  "$(malformed CLAUDE | sed 's/1 + \\$/1 + \\ /')" > "$WORK/peer-orig.md"
rm -f "$WORK/normalized.md"
normalize "$WORK/peer-orig.md"
check "a report with control lines normalizes" eval '[ "$NSTATUS" -eq 0 ]'
cp "$WORK/normalized.md" "$WORK/peer-good.md"
for change in 's.replace("PEER-REPORT: 01-round0-codex-initial", "PEER-REPORT: 03-round1-codex-respond")' \
              's.replace("  - also seen in the logs", "    - also seen in the logs")' \
              's.replace("VERDICT: APPROVED", "VERDICT: REQUEST CHANGES")' 's.replace("- None", "- CLAUDE-1")'; do
  grammar 's0 = open(sys.argv[1]).read(); s = s0; s = '"$change"'; assert s != s0
print(g.prove(open(sys.argv[2]).read(), s))' "$WORK/peer-good.md" "$WORK/peer-orig.md" > "$WORK/proof" || echo "[]" > "$WORK/proof"
  check "proof rejects a control-line change: ${change:10:40}" eval '! grep -qx "\[\]" "$WORK/proof"'
done

# Incremental sections are outside the finding fields: lineage, verification and duplication accounts stay exact.
{ printf 'x\n%s\n\n## Previous findings verification\n- CLAUDE-7: not fixed — still unbounded\n\n' "$(malformed CLAUDE | sed 's/1 + \\$/1 + \\ /')"
  printf '## Duplication check\n- SUBJ-1: no duplicate found — searched: handler; compared: src/app.py:1-2\n- DUP-1: not duplicate — different responsibility\n\n## Merge blockers\n- None\n'; } > "$WORK/inc-orig.md"
rm -f "$WORK/normalized.md"
normalize "$WORK/inc-orig.md"
check "a report with incremental sections normalizes" eval '[ "$NSTATUS" -eq 0 ]'
cp "$WORK/normalized.md" "$WORK/inc-good.md"
for change in 's.replace("CLAUDE-7: not fixed", "CLAUDE-7: fixed")' 's.replace("SUBJ-1: no duplicate found", "SUBJ-1: not applicable")' \
              's.replace("DUP-1: not duplicate", "DUP-1: common pattern")'; do
  grammar 's0 = open(sys.argv[1]).read(); s = s0; s = '"$change"'; assert s != s0
print(g.prove(open(sys.argv[2]).read(), s))' "$WORK/inc-good.md" "$WORK/inc-orig.md" > "$WORK/proof" || echo "[]" > "$WORK/proof"
  check "proof rejects an incremental-section change: ${change:10:44}" eval '! grep -qx "\[\]" "$WORK/proof"'
done
sed -n '/^## Previous findings verification/,$p' "$WORK/inc-orig.md" > "$WORK/inc-tail-orig"
sed -n '/^## Previous findings verification/,$p' "$WORK/inc-good.md" > "$WORK/inc-tail-good"
check "incremental sections are untouched by normalization" eval '[ -s "$WORK/inc-tail-orig" ] && cmp -s "$WORK/inc-tail-orig" "$WORK/inc-tail-good"'

# ── End to end: no extra reviewer call, both workflow orders, final round ──────

for order in claude codex; do
  if [ "$order" = claude ]; then p=claude a=codex flags="--codex=attack"; else p=codex a=claude flags="--codex=review --claude=attack"; fi
  reset_mocks
  report 1 "$p" "REQUEST CHANGES" N/A N/A
  report 2 "$a" "REQUEST CHANGES" YES "$(rid 1 0 "$p" initial)"
  # shellcheck disable=SC2086
  run_gencr $flags
  first="$(rid 1 0 "$p" initial)" second="$(rid 2 0 "$a" attack)"
  check "$p-first: malformed reports are normalized and the review completes with no extra invocation" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 2 ] && contains "$ERR" "format normalized"'
  check "$p-first: both reviewers' originals are kept byte-exact, normalized reports are consumed" \
    eval 'cmp -s "$PKG/$first.report.original.md" "$MOCK_STATE/responses/1" && cmp -s "$PKG/$second.report.original.md" "$MOCK_STATE/responses/2" &&
          ! cmp -s "$PKG/$first.report.md" "$PKG/$first.report.original.md" &&
          python3 -B "$REPO/bin/gencr_support.py" check-report --report "$PKG/$first.report.md"'
  check "$p-first: the adversary received the normalized primary report" \
    eval 'grep -qxF -- "  - Fix:" "$MOCK_STATE/call-2.stdin" && grep -qxF -- "    - Add a test file covering:" "$MOCK_STATE/call-2.stdin" && ! grep -qF -- "- Fix: - Add" "$MOCK_STATE/call-2.stdin"'
  check "$p-first: metadata records each normalization; rounds unchanged" \
    eval '[ "$(json_get "$PKG/metadata.json" "[i[\"format_normalization\"][\"result\"] for i in d[\"invocations\"]]")" = "['"'"'normalized'"'"', '"'"'normalized'"'"']" ] &&
          [ "$(json_get "$PKG/metadata.json" "d[\"rounds\"]")" = 0 ] &&
          [ "$(json_get "$PKG/metadata.json" "len(d[\"invocations\"][0][\"format_normalization\"][\"repairs\"])")" = 3 ]'
  check "$p-first: findings.json and the full report carry complete multiline values" \
    eval '[ "$(json_get "$PKG/findings.json" "[f for f in d[\"final_findings\"] if f[\"id\"].endswith(\"-10\")][0][\"fields\"][\"Problem\"].count(chr(10))")" = 3 ] &&
          grep -qF "    - The client is not closed on error." "$PKG/full-report.md" && grep -qF "Format: $first: format normalized by gencr" "$PKG/full-report.md"'
  check "$p-first: the summary renders the complete multiline Fix" \
    eval 'grep -qF "      - connected and disconnected status load" "$PKG/summary.md" && grep -qF "    - Keep the existing fixtures" "$PKG/summary.md"'
  check "$p-first: reconciliation lists the normalization" eval 'grep -qF "Format: $second: format normalized by gencr" "$PKG/reconciliation.md"'
done

# The final permitted round: a malformed report in round 3 is normalized, not an extra round.
reset_mocks
n=1
for step in "claude APPROVED N/A N/A" "codex REQUEST\ CHANGES NO $(rid 1 0 claude initial)" \
            "claude APPROVED NO $(rid 2 0 codex attack)" "codex REQUEST\ CHANGES NO $(rid 3 1 claude reconcile)" \
            "claude APPROVED NO $(rid 4 1 codex respond)" "codex REQUEST\ CHANGES NO $(rid 5 1 claude reconcile)" \
            "claude APPROVED NO $(rid 6 2 codex respond)" "codex REQUEST\ CHANGES NO $(rid 7 2 claude reconcile)" \
            "claude APPROVED NO $(rid 8 3 codex respond)" "codex REQUEST\ CHANGES NO $(rid 9 3 claude reconcile)"; do
  eval "set -- $step"
  report "$n" "$@"
  n=$((n + 1))
done
run_gencr --codex=attack
check "final round: every malformed report is normalized; still exactly 9 invocations and 3 rounds" \
  eval '[ "$STATUS" -eq 11 ] && [ "$(calls)" -eq 9 ] && [ "$(json_get "$PKG/metadata.json" "d[\"rounds\"]")" = 3 ] &&
        [ "$(ls "$PKG"/*.report.original.md | wc -l | tr -d " ")" -eq 9 ] && [ -f "$PKG/$(rid 9 3 claude reconcile).normalization.json" ]'

# Irreparable: INCOMPLETE, original kept as the report, the peer is never launched.
printf '## Findings\n- **CLAUDE-1 T**\n  - Severity: High\n  - File: src/app.py:1\n  - Problem: p\n  - Expected vs actual: x\n  - Tests: t:\n    - Evidence: lookalike\n  - Fix:\n    - f\n' > "$WORK/lookalike.md"
reset_mocks
report 1 claude "REQUEST CHANGES" N/A N/A "$WORK/lookalike.md"
run_gencr --codex=attack
check "irreparable report: INCOMPLETE, Codex never launched, original preserved, record says irreparable" \
  eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "format normalization cannot repair it" &&
        cmp -s "$PKG/$(rid 1 0 claude initial).report.md" "$MOCK_STATE/responses/1" &&
        cmp -s "$PKG/$(rid 1 0 claude initial).report.original.md" "$MOCK_STATE/responses/1" &&
        [ "$(json_get "$PKG/$(rid 1 0 claude initial).normalization.json" "d[\"result\"]")" = irreparable ]'
check "a lookalike-only Evidence passes the legacy validator alone, so the structural check is what stops it" \
  eval 'contains "$ERR" "has no Evidence field"'

# A report the legacy validator accepts (lookalike Evidence, every field line filled) is stopped by the structural check.
printf '## Findings\n- **CLAUDE-1 T**\n  - Severity: High\n  - File: src/app.py:1\n  - Problem: p\n  - Expected vs actual: x\n  - Tests: t:\n    - Evidence: lookalike\n  - Fix: f\n' > "$WORK/lookalike-valid.md"
reset_mocks
report 1 claude "REQUEST CHANGES" N/A N/A "$WORK/lookalike-valid.md"
run_gencr --codex=attack
check "legacy-valid report without a real Evidence field: INCOMPLETE via the structural check" \
  eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "has no Evidence field"'

# Normalized but still invalid (a control-line defect): INCOMPLETE with both responses.
reset_mocks
report 1 claude "REQUEST CHANGES" N/A N/A
report 2 codex "REQUEST CHANGES" YES "99-round0-claude-initial"
run_gencr --codex=attack
check "normalized but still invalid: INCOMPLETE, both files kept, record says rejected-validation" \
  eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 2 ] && contains "$ERR" "still invalid" &&
        [ "$(json_get "$PKG/$(rid 2 0 codex attack).normalization.json" "d[\"result\"]")" = rejected-validation ] &&
        cmp -s "$PKG/$(rid 2 0 codex attack).report.md" "$MOCK_STATE/responses/2"'

# A valid report is never normalized.
reset_mocks
run_gencr
check "a valid report leaves no normalization files" \
  eval '[ "$STATUS" -eq 0 ] && ! ls "$PKG"/*.report.original.md >/dev/null 2>&1 && ! ls "$PKG"/*.normalization.json >/dev/null 2>&1'

# Dispositions keep their continuation lines.
cat > "$WORK/disp-body.md" <<'EOF'
## Findings
- None
EOF
reset_mocks
report 1 claude "REQUEST CHANGES" N/A N/A
cat > "$MOCK_STATE/responses/2" <<EOF
## Findings
- None

## Disposition of peer findings
- CLAUDE-1: rejected — the test exists:
  - see tests/test_app.py:12
  - it asserts both states
- CLAUDE-2: accepted — confirmed
- CLAUDE-3: accepted — confirmed
- CLAUDE-5: accepted — confirmed
- CLAUDE-10: accepted — confirmed

## Merge blockers
- CLAUDE-2

## Outstanding disputed findings
- None

## Review notes
- Verified clean: None
- Unresolved risks: None
- Disproven claims: None
- Test gaps: None
- Out-of-scope ownership changes: None
- Other observations: None

VERDICT: REQUEST CHANGES
PEER-AGREEMENT: YES
PEER-REPORT: $(rid 1 0 claude initial)
EOF
run_gencr --codex=attack
check "disposition evidence keeps its continuation lines in findings.json" \
  eval '[ "$STATUS" -eq 10 ] && [ "$(json_get "$PKG/findings.json" "d[\"dispositions\"][\"codex\"][0][\"evidence\"]")" = "the test exists:
- see tests/test_app.py:12
- it asserts both states" ]'

# The shared prompt states the field schema for every reviewer.
reset_mocks
(cd "$TARGET" && "$REPO/bin/gencr" dev --codex=attack --print) > "$WORK/prompt" 2>/dev/null
check "the prompt states the value grammar (single-line scalars, blocks directly below) and qualifiers in the value" \
  eval 'grep -qF "Severity, File and Duplicate of are each one line of text on the field line, with nothing below it." "$WORK/prompt" && grep -qF "in a block of lines directly below it (no blank line before the first one)" "$WORK/prompt" && ! grep -qF "Never leave a field line empty" "$WORK/prompt" && grep -qF "\"- Evidence: (traced, not executed) ...\", not \"- Evidence (traced, not executed):\"" "$WORK/prompt"'

# ── Revision 1 (codex FMT-I1..I3, C1): lossless bytes, tab-only lines, complete disposition evidence ──

# raw_report N AGENT PYTHON-BYTES-EXPR — a queued response written as exact bytes (the mock passes them through).
raw_report() { python3 -B -c 'import sys; open(sys.argv[1], "wb").write(eval(sys.argv[2]))' "$MOCK_STATE/responses/$1" "$3"; }
FIELDS_BYTES='b"## Findings\n- **CODEX-1 T**\n  - Severity: High\n  - File: src/app.py:1\n  - Problem: p\n  - Expected vs actual: x\n  - Tests: t\n"'
TAIL_BYTES='b"\n## Disposition of peer findings\n- None\n\n## Merge blockers\n- CODEX-1\n\n## Outstanding disputed findings\n- None\n\n## Review notes\n- Verified clean: None\n- Unresolved risks: None\n- Disproven claims: None\n- Test gaps: None\n- Out-of-scope ownership changes: None\n- Other observations: None\n\nVERDICT: REQUEST CHANGES\nPEER-AGREEMENT: N/A\nPEER-REPORT: N/A\n"'

# FMT-I1: a carriage return in evidence is payload; it survives normalization, validation and packaging.
reset_mocks
raw_report 1 codex "$FIELDS_BYTES"' + b"  - Evidence: line ends in CR\r\n    next\n  - Fix:\n    - f\n" + '"$TAIL_BYTES"
run_gencr --codex=review
check "CR payload: a block Fix is valid as written, review completes without normalization" eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 1 ] && [ ! -e "$PKG/$(rid 1 0 codex initial).report.original.md" ]'
check "CR payload: the canonical report and findings.json keep the carriage return" \
  eval '[ "$(tr -cd "\r" < "$PKG/$(rid 1 0 codex initial).report.md" | wc -c | tr -d " ")" = 1 ] &&
        [ "$(json_get "$PKG/findings.json" "repr(d[\"final_findings\"][0][\"fields\"][\"Evidence\"])")" = "'"'"'line ends in CR\\r\\nnext'"'"'" ]'
reset_mocks
raw_report 1 codex "$FIELDS_BYTES"' + b"  - Evidence: already valid, ends in CR\r\n  - Fix: f\n" + '"$TAIL_BYTES"
run_gencr --codex=review
check "CR payload in an already-valid report is packaged unchanged" \
  eval '[ "$STATUS" -eq 10 ] && [ "$(json_get "$PKG/findings.json" "repr(d[\"final_findings\"][0][\"fields\"][\"Evidence\"])")" = "'"'"'already valid, ends in CR\\r'"'"'" ] && [ "$(grep -c $'"'"'ends in CR\r$'"'"' "$PKG/full-report.md")" -eq 2 ]'
# Invalid UTF-8 is never replaced: the structural check rejects it and normalization refuses it.
reset_mocks
raw_report 1 codex "$FIELDS_BYTES"' + b"  - Evidence: bad byte \xff here\n  - Fix:\n    - f\n" + '"$TAIL_BYTES"
run_gencr --codex=review
check "invalid UTF-8: INCOMPLETE, nothing replaced, original kept" \
  eval '[ "$STATUS" -eq 20 ] && contains "$ERR" "not valid UTF-8" && cmp -s "$PKG/$(rid 1 0 codex initial).report.md" "$MOCK_STATE/responses/1" &&
        [ "$(json_get "$PKG/$(rid 1 0 codex initial).normalization.json" "d[\"result\"]")" = irreparable ]'
reset_mocks
raw_report 1 codex "$FIELDS_BYTES"' + b"  - Evidence: bad byte \xff here\n  - Fix: f\n" + '"$TAIL_BYTES"
run_gencr --codex=review
check "invalid UTF-8 in an otherwise valid report: INCOMPLETE via the structural check" \
  eval '[ "$STATUS" -eq 20 ] && contains "$ERR" "not valid UTF-8"'

# FMT-I2: a whitespace-only line with a tab inside a finding is a structural error (strict and repairable).
printf '## Findings\n- **CLAUDE-1 T**\n  - Severity: High\n  - File: a.py:1\n  - Problem: p\n  - Evidence: before\n\t\n    after\n  - Expected vs actual: x\n  - Tests: t\n  - Fix:\n    - f\n## Merge blockers\n- None\n' > "$WORK/tabline.md"
check "a tab-only line inside a finding is a structural error" \
  eval 'contains "$(grammar "print(g.parse(open(sys.argv[1]).read())[\"errors\"])" "$WORK/tabline.md")" "tab"'
rm -f "$WORK/normalized.md"
normalize "$WORK/tabline.md"
check "a report with a tab-only line is irreparable" eval '[ "$NSTATUS" -eq 3 ] && [ ! -e "$WORK/normalized.md" ]'
check "the proof rejects erasing a tab-only line (the codex collision)" \
  eval '[ "$(grammar "s = open(sys.argv[1]).read(); t = s.replace(\"\\n\\t\\n\", \"\\n\\n\").replace(\"  - Fix:\\n    - f\", \"  - Fix: - f\"); print(bool(g.prove(s, t)))" "$WORK/tabline.md")" = True ]'
# Whitespace-only lines inside a value keep any non-space whitespace (only the anchor spaces are container).
printf '## Findings\n- **CLAUDE-1 T**\n  - Severity: High\n  - File: a.py:1\n  - Problem: p\n  - Evidence: before\n\r\n    after\n  - Expected vs actual: x\n  - Tests: t\n  - Fix: f\n## Merge blockers\n- None\n' > "$WORK/crline.md"
check "a CR-only line inside a value is kept" \
  eval '[ "$(grammar "print(repr([f for f in g.parse(open(sys.argv[1], newline=\"\").read())[\"findings\"]][0][\"values\"][\"Evidence\"]))" "$WORK/crline.md")" = "'"'"'before\\n\\r\\nafter'"'"'" ]'

# FMT-I3: disposition and verification evidence keeps signs, backticks and interior blank lines.
reset_mocks
report 1 claude "REQUEST CHANGES" N/A N/A
cat > "$MOCK_STATE/responses/2" <<EOF
## Findings
- None

## Disposition of peer findings
- CLAUDE-1: accepted — -1 is the observed return value
  first continuation

  last continuation
- CLAUDE-2: rejected — \`module.py:1\` already validates
- CLAUDE-3: disputed: needs a test
- CLAUDE-5: accepted - plain hyphen delimiter
- CLAUDE-10: accepted —confirmed

## Merge blockers
- CLAUDE-1

## Outstanding disputed findings
- None

## Review notes
- Verified clean: None
- Unresolved risks: None
- Disproven claims: None
- Test gaps: None
- Out-of-scope ownership changes: None
- Other observations: None

VERDICT: REQUEST CHANGES
PEER-AGREEMENT: YES
PEER-REPORT: $(rid 1 0 claude initial)
EOF
run_gencr --codex=attack
check "disposition evidence: sign, paragraph break and continuation exact" \
  eval '[ "$STATUS" -eq 10 ] && [ "$(json_get "$PKG/findings.json" "repr(d[\"dispositions\"][\"codex\"][0][\"evidence\"])")" = "'"'"'-1 is the observed return value\\nfirst continuation\\n\\nlast continuation'"'"'" ]'
check "disposition evidence: opening backtick, colon and hyphen delimiters" \
  eval '[ "$(json_get "$PKG/findings.json" "[e[\"evidence\"] for e in d[\"dispositions\"][\"codex\"][1:]]")" = "['"'"'\`module.py:1\` already validates'"'"', '"'"'needs a test'"'"', '"'"'plain hyphen delimiter'"'"', '"'"'confirmed'"'"']" ]'
check "previous-verification entries use the same parser" \
  eval '[ "$(python3 -B -c "import sys; sys.path.insert(0, sys.argv[1]); import gencr_support as s; print(repr(s.parse_dispositions([\"- CLAUDE-3: fixed — \`module.py:1\` returns -1\", \"\", \"  after a blank\"], \"not fixed|fixed|obsolete\")[0][\"evidence\"]))" "$REPO/bin")" = "'"'"'\`module.py:1\` returns -1\\n\\nafter a blank'"'"'" ]'

# FMT-C1: the record names the saved canonical report, with its hash.
reset_mocks
report 1 claude APPROVED N/A N/A
run_gencr
check "the normalization record names the saved canonical report and its hash matches" \
  eval 'r="$PKG/$(rid 1 0 claude initial).normalization.json"; n="$(json_get "$r" "d[\"normalized\"]")"; [ -f "$PKG/$n" ] &&
        [ "$(json_get "$r" "d[\"normalized_sha256\"]")" = "$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], \"rb\").read()).hexdigest())" "$PKG/$n")" ]'

# ── Revision 2 (codex FMT-I1-R1, FMT-I3-R1) ────────────────────────────────────

# FMT-I1-R1: Claude's JSON envelope is decoded strictly; invalid UTF-8 is a reviewer failure, never replaced evidence.
reset_mocks
python3 -B - "$MOCK_STATE/raw-stdout-1" <<'EOF'
import json, sys
report = ("## Findings\n- **CLAUDE-1 T**\n  - Severity: High\n  - File: src/app.py:1\n  - Problem: p\n"
          "  - Evidence: observed BADBYTE failure\n  - Expected vs actual: x\n  - Tests: t\n  - Fix:\n    - f\n\n"
          "## Disposition of peer findings\n- None\n\n## Merge blockers\n- CLAUDE-1\n\n"
          "## Outstanding disputed findings\n- None\n\n## Review notes\n- Verified clean: None\n- Unresolved risks: None\n- Disproven claims: None\n- Test gaps: None\n- Out-of-scope ownership changes: None\n- Other observations: None\n\nVERDICT: REQUEST CHANGES\nPEER-AGREEMENT: N/A\nPEER-REPORT: N/A\n")
envelope = json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": report}).encode()
open(sys.argv[1], "wb").write(envelope.replace(b"BADBYTE", b"\xff"))
EOF
run_gencr
check "Claude envelope with invalid UTF-8: reviewer failure, no report, no normalization, no replacement character" \
  eval '[ "$STATUS" -eq 21 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "not valid UTF-8" &&
        [ ! -s "$PKG/$(rid 1 0 claude initial).report.md" ] && [ ! -e "$PKG/$(rid 1 0 claude initial).normalization.json" ] &&
        ! grep -rq $'"'"'\xef\xbf\xbd'"'"' "$PKG"'
reset_mocks
python3 -B -c 'import json,sys; open(sys.argv[1], "wb").write(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": open(sys.argv[2]).read().replace("ends in CR", "ends in CR\r")}).encode())' \
  "$MOCK_STATE/raw-stdout-1" /dev/stdin <<EOF
$(printf '## Findings\n- **CLAUDE-1 T**\n  - Severity: High\n  - File: src/app.py:1\n  - Problem: p\n  - Evidence: ends in CR\n  - Expected vs actual: x\n  - Tests: t\n  - Fix: f\n\n## Disposition of peer findings\n- None\n\n## Merge blockers\n- None\n\n## Outstanding disputed findings\n- None\n\n## Review notes\n- Verified clean: None\n- Unresolved risks: None\n- Disproven claims: None\n- Test gaps: None\n- Out-of-scope ownership changes: None\n- Other observations: None\n\nVERDICT: APPROVED\nPEER-AGREEMENT: N/A\nPEER-REPORT: N/A')
EOF
run_gencr
check "a valid Claude envelope with an escaped CR still works and keeps the CR" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(json_get "$PKG/findings.json" "repr(d[\"final_findings\"][0][\"fields\"][\"Evidence\"])")" = "'"'"'ends in CR\\r'"'"'" ]'

# FMT-I3-R1: only spaces delimit; a CR (or other whitespace) after the separator is evidence payload.
reset_mocks
report 1 claude "REQUEST CHANGES" N/A N/A
python3 -B - "$MOCK_STATE/responses/2" "$(rid 1 0 claude initial)" <<'EOF'
import sys
body = ("## Findings\n- None\n\n## Disposition of peer findings\n"
        "- CLAUDE-1: accepted — \r-1 is the observed return value\n- CLAUDE-2: accepted —  kept\n"
        "- CLAUDE-3: accepted — confirmed\n- CLAUDE-5: accepted — confirmed\n- CLAUDE-10: accepted — confirmed\n\n"
        "## Merge blockers\n- CLAUDE-1\n\n## Outstanding disputed findings\n- None\n\n"
        "## Review notes\n- Verified clean: None\n- Unresolved risks: None\n- Disproven claims: None\n- Test gaps: None\n- Out-of-scope ownership changes: None\n- Other observations: None\n\n"
        "VERDICT: REQUEST CHANGES\nPEER-AGREEMENT: YES\nPEER-REPORT: %s\n" % sys.argv[2])
open(sys.argv[1], "w", encoding="utf-8", newline="").write(body)
EOF
run_gencr --codex=attack
check "disposition evidence keeps a CR and a U+2028 that follow the separator" \
  eval '[ "$STATUS" -eq 10 ] && [ "$(json_get "$PKG/findings.json" "[e[\"evidence\"] for e in d[\"dispositions\"][\"codex\"][:2]] == [chr(13) + \"-1 is the observed return value\", chr(0x2028) + \"kept\"]")" = True ]'
check "previous verification keeps a CR after the separator" \
  eval '[ "$(python3 -B -c "import sys; sys.path.insert(0, sys.argv[1]); import gencr_support as s; print(s.parse_dispositions([\"- CLAUDE-3: fixed — \r\`a.py\`\"], \"not fixed|fixed|obsolete\")[0][\"evidence\"] == chr(13) + \"\`a.py\`\")" "$REPO/bin")" = True ]'

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
