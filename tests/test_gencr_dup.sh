#!/usr/bin/env bash
# Tests for the INCREMENTAL duplication check (bin/gencr_duplicates.py and its gencr wiring), with real Git
# fixtures and the mock reviewer CLIs. Usage: bash tests/test_gencr_dup.sh
# shellcheck disable=SC2016,SC2012,SC2034  # deferred eval checks; fixture paths are known-safe

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd -P "$(mktemp -d)" && pwd)/gencr dup tests"
mkdir -p "$WORK"
trap 'rm -rf "$(dirname "$WORK")"' EXIT

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
not_ok() { FAIL=$((FAIL + 1)); echo "not ok - $1"; [ -z "$2" ] || printf '%s\n' "$2" | sed 's/^/    # /'; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else not_ok "$desc"; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
file_contains() { grep -qF -- "$2" "$1"; }
json_get() { python3 -B -c 'import json,sys; d=json.load(open(sys.argv[1])); exec("print(" + sys.argv[2] + ")")' "$1" "$2"; }

export HOME="$WORK/home"
mkdir -p "$HOME"
MOCKS="$WORK/mocks"
mkdir -p "$MOCKS"
cp "$REPO/tests/mocks/mock_reviewer.py" "$MOCKS/"
ln -s mock_reviewer.py "$MOCKS/claude"
ln -s mock_reviewer.py "$MOCKS/codex"
export PATH="$MOCKS:$PATH" MOCK_STATE="$WORK/mock state" CODEREVIEW_BASE_BRANCH=main
unset MOCK_VERDICT GENCR_DUP_LIMITS
GENCR="$REPO/bin/gencr"
OUT="$WORK/reports"

T="$WORK/app repo"
git init -q --bare "$WORK/origin.git"
git init -q "$T"
git -C "$T" config user.email t@example.com
git -C "$T" config user.name T
git -C "$T" checkout -q -b main
cat > "$T/util.py" <<'EOF'
def existing_helper(values):
    total = 0
    for value in values:
        total += value * 2
    return total
EOF
git -C "$T" add . && git -C "$T" commit -qm base
git -C "$T" remote add origin "$WORK/origin.git"
git -C "$T" push -q origin main
git -C "$T" checkout -q -b feature
cat > "$T/a.py" <<'EOF'
def normalize_name(raw_name):
    cleaned = raw_name.strip().lower()
    parts = [p for p in cleaned.split(" ") if p]
    joined = "-".join(parts)
    return joined.replace("--", "-")
EOF
git -C "$T" add . && git -C "$T" commit -qm "add normalize_name"
MERGE_BASE="$(git -C "$T" merge-base origin/main HEAD)"

reset_mocks() { rm -rf "$MOCK_STATE"; mkdir -p "$MOCK_STATE/responses"; }
calls() { cat "$MOCK_STATE/count" 2>/dev/null || echo 0; }
run_gencr() { (cd "$T" && "$GENCR" "$@") > "$WORK/out" 2> "$WORK/err"; STATUS=$?; OUTPUT="$(cat "$WORK/out")"; ERR="$(cat "$WORK/err")"; }
newest() { ls -td "$OUT"/review-* | head -n 1; }

# The approved fresh review of the PR's first commit: the baseline of every incremental case.
reset_mocks
run_gencr dev --codex=review --output-dir="$OUT"
BASELINE="$(newest)"
BASELINE_ID="$(json_get "$BASELINE/metadata.json" 'd["run_id"]')"
BASELINE_SHA="$(git -C "$T" rev-parse HEAD)"
check "the fresh review approving normalize_name() is complete and has no duplication check" \
  eval '[ "$STATUS" -eq 0 ] && ! grep -q "Duplication" "$BASELINE/full-report.md" && ! grep -q "Duplication check" "$BASELINE/00-shared-prompt.md"'

commit() { git -C "$T" add -A && git -C "$T" commit -qm "$1"; }
restore() { git -C "$T" reset -q --hard "$BASELINE_SHA"; git -C "$T" clean -qfd; }
inc_print() { reset_mocks; run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BASELINE" --print; }
# A single-reviewer incremental report with given Findings and Duplication check bodies (APPROVED).
dup_report() { # findings-file dupcheck-file
  {
    echo "Duplication review."
    echo
    echo "## Findings"
    cat "$1"
    echo
    echo "## Disposition of peer findings"
    echo "- None"
    echo
    echo "## Merge blockers"
    echo "- None"
    echo
    echo "## Outstanding disputed findings"
    echo "- None"
    echo
    echo "## Previous findings verification"
    echo "- None"
    echo
    echo "## Duplication check"
    cat "$2"
    echo
    echo "## Review notes"
    for label in "Verified clean" "Unresolved risks" "Disproven claims" "Test gaps" "Out-of-scope ownership changes" "Other observations"; do
      echo "- $label: None"
    done
    echo
    echo "VERDICT: APPROVED"
    echo "PEER-AGREEMENT: N/A"
    echo "PEER-REPORT: N/A"
  } > "$MOCK_STATE/responses/1"
}
finding() { # id file duplicate-of
  cat <<EOF
- **$1 Duplicates an existing implementation**
  - Severity: Medium
  - File: $2
  - Duplicate of: $3
  - Problem: the same slug normalization is implemented twice
  - Evidence: identical steps (strip, lower, split, join, collapse)
  - Expected vs actual: reuse of the existing helper; a second copy
  - Tests: none detect duplication
  - Fix: call the existing helper
EOF
}
inc_run() { run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BASELINE"; }

# ── Acceptance: a renamed copy of code approved in the previous review ─────────

cat > "$T/b.py" <<'EOF'
import os


def make_slug(title):
    cleaned = title.strip().lower()
    parts = [p for p in cleaned.split(" ") if p]
    joined = "-".join(parts)
    return joined.replace("--", "-")
EOF
commit "add make_slug"
inc_print
check "the incremental prompt lists the change subject" contains "$OUTPUT" "  - SUBJ-1 [added] b.py:1-8 (new file)"
check "a renamed copy of earlier-approved code is a textual candidate with both locations" \
  eval 'contains "$OUTPUT" "  - DUP-1 (renamed) for SUBJ-1: new b.py:4-8" && contains "$OUTPUT" "Existing code a.py:1-5"'
check "provenance states verified per-snapshot facts only" \
  contains "$OUTPUT" "(merge-base ${MERGE_BASE:0:12}: not found at this path; previous review $BASELINE_ID (${BASELINE_SHA:0:12}): exact region present at this path)"
check "both code snippets are shown as evidence" \
  eval 'contains "$OUTPUT" "      def make_slug(title):" && contains "$OUTPUT" "      def normalize_name(raw_name):"'
check "the incremental scope and diff are unchanged (only b.py), originals are evidence only" \
  eval 'contains "$OUTPUT" "  - A b.py" && ! contains "$OUTPUT" "  - A a.py" && contains "$OUTPUT" "previously approved code is not re-reviewed"'

reset_mocks
finding CODEX-2 b.py:4-8 a.py:1-5 > "$WORK/f"
printf '%s\n' "- SUBJ-1: duplicate (CODEX-2) — searched: strip().lower(), \"-\".join, replace(\"--\"; compared: a.py:1-5" \
  "- DUP-1: duplicate (CODEX-2) — same five steps as a.py:1-5 with renamed identifiers" > "$WORK/d"
dup_report "$WORK/f" "$WORK/d"
inc_run
DUP_PKG="$(newest)"
check "a valid duplicate finding with paired locations is accepted" eval '[ "$STATUS" -eq 0 ]'
check "findings.json keeps the candidate, the dispositions and the finding's Duplicate of" \
  eval '[ "$(json_get "$DUP_PKG/findings.json" "d[\"duplication\"][\"candidates\"][0][\"originals\"][0][\"path\"], d[\"final_findings\"][0][\"fields\"][\"Duplicate of\"], len(d[\"duplication\"][\"dispositions\"][\"codex\"])")" = "a.py a.py:1-5 2" ]'
LEGACY="$OUT/code-review-$(json_get "$DUP_PKG/metadata.json" 'd["run_id"]').md"
canonical() { sed -n '/^## Open findings (canonical)$/,/^## /p' "$1"; }
for f in "$DUP_PKG/full-report.md" "$LEGACY"; do
  check "$(basename "$f") renders the paired evidence in the canonical open findings and the duplication check" \
    eval 'contains "$(canonical "$f")" "  - Duplicate of: a.py:1-5" && contains "$(canonical "$f")" "  - File: b.py:4-8" && file_contains "$f" "- DUP-1 (renamed) for SUBJ-1: new b.py:4-8; existing a.py:1-5" && file_contains "$f" "- Duplication Index: complete"'
done
check "the duplication index status is in summary.md and metadata.json" \
  eval 'file_contains "$DUP_PKG/summary.md" "- Duplication Index: complete" && [ "$(json_get "$DUP_PKG/metadata.json" "d[\"duplication_index\"]")" = complete ]'

# The open duplication finding carries into the next incremental review with its evidence.
echo "# docs" > "$T/NOTES.md"
commit "notes"
reset_mocks
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$DUP_PKG" --print
check "the next incremental prompt carries the earlier duplication finding and its Duplicate of" \
  eval 'contains "$OUTPUT" "verify each one): CODEX-2" && contains "$OUTPUT" "  - Duplicate of: a.py:1-5"'
reset_mocks
finding CODEX-2 b.py:4-8 a.py:1-5 > "$WORK/f"
printf '%s\n' "- SUBJ-1: not applicable — documentation only (NOTES.md)" > "$WORK/d"
dup_report "$WORK/f" "$WORK/d"
python3 -B - "$MOCK_STATE/responses/1" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("## Previous findings verification\n- None\n",
              "## Previous findings verification\n- CODEX-2: not fixed — b.py still duplicates a.py:1-5\n")
open(p, "w").write(s)
EOF
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$DUP_PKG"
check "a carried duplication finding stays open with its paired evidence" \
  eval '[ "$STATUS" -eq 0 ] && file_contains "$(newest)/full-report.md" "  - Duplicate of: a.py:1-5"'
git -C "$T" reset -q --hard HEAD~1

# ── Contract violations are INCOMPLETE ─────────────────────────────────────────

dup_reject() { # description expected-error dupcheck-lines [finding args...]
  local desc="$1" expect="$2" lines="$3"
  shift 3
  reset_mocks
  if [ "$#" -gt 0 ]; then finding "$@" > "$WORK/f"; else echo "- None" > "$WORK/f"; fi
  printf '%s\n' "$lines" > "$WORK/d"
  dup_report "$WORK/f" "$WORK/d"
  inc_run
  if [ "$STATUS" -eq 20 ] && contains "$ERR" "$expect"; then ok "rejects $desc"; else not_ok "rejects $desc" "status=$STATUS $ERR"; fi
}
GOOD_SUBJ='- SUBJ-1: duplicate (CODEX-2) — searched: strip().lower(); compared: a.py:1-5'
dup_reject "a missing DUP line" "has no line for DUP-1" "$GOOD_SUBJ" CODEX-2 b.py:4-8 a.py:1-5
dup_reject "a missing SUBJ line" "has no line for SUBJ-1" "- DUP-1: not duplicate — different responsibility"
dup_reject "a subject without a searched: account" "SUBJ-1 needs a non-empty 'searched:' account" \
  "$(printf '%s\n%s' '- SUBJ-1: no duplicate found — compared: none' '- DUP-1: not duplicate — differs')"
dup_reject "a dismissal without evidence" "DUP-1 must be" "$(printf '%s\n%s' "$GOOD_SUBJ" '- DUP-1: common pattern —')" CODEX-2 b.py:4-8 a.py:1-5
dup_reject "a duplicate naming no defined finding" "finding CODEX-9 is not defined" \
  "$(printf '%s\n%s' "$GOOD_SUBJ" '- DUP-1: duplicate (CODEX-9) — copy')" CODEX-2 b.py:4-8 a.py:1-5
dup_reject "a finding without Duplicate of" "needs 'Duplicate of" "$(printf '%s\n%s' "$GOOD_SUBJ" '- DUP-1: duplicate (CODEX-2) — copy')" CODEX-2 b.py:4-8 ""
dup_reject "a Duplicate of written as a block below its label" "CODEX-2: Duplicate of must be a single line on its field line" \
  "$(printf '%s\n%s' "$GOOD_SUBJ" '- DUP-1: duplicate (CODEX-2) — copy')" CODEX-2 b.py:4-8 "$(printf '\n    a.py:1-5')"
dup_reject "a Duplicate of with a continuation line" "CODEX-2: Duplicate of must be a single line on its field line" \
  "$(printf '%s\n%s' "$GOOD_SUBJ" '- DUP-1: duplicate (CODEX-2) — copy')" CODEX-2 b.py:4-8 "$(printf 'a.py:1-5\n    and more')"
dup_reject "a finding whose File is not the new code" "needs 'File: b.py" "$(printf '%s\n%s' "$GOOD_SUBJ" '- DUP-1: duplicate (CODEX-2) — copy')" CODEX-2 util.py:1-5 a.py:1-5
dup_reject "a path-prefix collision (a.py.bak vs a.py)" "does not match the candidate's existing code" \
  "$(printf '%s\n%s' '- SUBJ-1: no duplicate found — searched: x; compared: none' '- DUP-1: duplicate (CODEX-2) — copy')" CODEX-2 b.py:4-8 a.py.bak:1-5
dup_reject "a Duplicate of range outside the candidate" "does not match the candidate's existing code" \
  "$(printf '%s\n%s' '- SUBJ-1: no duplicate found — searched: x; compared: none' '- DUP-1: duplicate (CODEX-2) — copy')" CODEX-2 b.py:4-8 a.py:40-50
dup_reject "a semantic duplicate naming a file that does not exist at HEAD" "util2.py, which is not a regular file" \
  "$(printf '%s\n%s' '- SUBJ-1: duplicate (CODEX-2) — searched: total += value; compared: util2.py' '- DUP-1: not duplicate — differs')" CODEX-2 b.py:4-8 util2.py:1-5
dup_reject "a semantic duplicate range past the end of the file" "range ends after line 5 of util.py" \
  "$(printf '%s\n%s' '- SUBJ-1: duplicate (CODEX-2) — searched: total; compared: util.py' '- DUP-1: not duplicate — differs')" CODEX-2 b.py:4-8 util.py:3-9
reset_mocks
touch "$MOCK_STATE/no-auto-dup-1"
inc_run
check "a report without the Duplication check section is INCOMPLETE" eval '[ "$STATUS" -eq 20 ] && contains "$ERR" "missing required section '"'"'## Duplication check'"'"'"'
reset_mocks
finding CODEX-2 b.py:4-8 util.py:1-5 > "$WORK/f"
printf '%s\n' '- SUBJ-1: duplicate (CODEX-2) — searched: total += value; compared: util.py:1-5' '- DUP-1: not duplicate — differs' > "$WORK/d"
dup_report "$WORK/f" "$WORK/d"
inc_run
check "a semantic duplicate of a real HEAD file range is accepted" eval '[ "$STATUS" -eq 0 ]'
restore

# Account fields are both required, and only no-code subjects may be "not applicable".
cat > "$T/b.py" <<'EOF'
import os


def make_slug(title):
    cleaned = title.strip().lower()
    parts = [p for p in cleaned.split(" ") if p]
    joined = "-".join(parts)
    return joined.replace("--", "-")
EOF
commit "add make_slug again"
dup_reject "a subject account without compared:" "SUBJ-1 needs a non-empty 'compared:' account" \
  "$(printf '%s\n%s' '- SUBJ-1: no duplicate found — searched: normalize' '- DUP-1: not duplicate — differs')"
dup_reject "an empty compared: account" "SUBJ-1 needs a non-empty 'compared:' account" \
  "$(printf '%s\n%s' '- SUBJ-1: no duplicate found — searched: normalize; compared:' '- DUP-1: not duplicate — differs')"
dup_reject "'not applicable' for a code subject" "SUBJ-1 (b.py) may contain code and cannot be 'not applicable'" \
  "$(printf '%s\n%s' '- SUBJ-1: not applicable — this added Python code does not need comparison' '- DUP-1: not duplicate — differs')"
restore

# A language without comment rules is still code: "not applicable" needs a no-code basis.
printf 'function slug(s)\n  return s:lower():gsub(" ", "-")\nend\n' > "$T/new.lua"
commit "lua code"
reset_mocks
echo "- None" > "$WORK/f"
printf '%s\n' "- SUBJ-1: not applicable — Lua does not need comparison" > "$WORK/d"
dup_report "$WORK/f" "$WORK/d"
inc_run
check "'not applicable' for a .lua code subject is rejected" eval '[ "$STATUS" -eq 20 ] && contains "$ERR" "may contain code"'
restore
na_case() { # file expected-status description
  local want="$2"
  printf 'x = 1\n' > "$T/$1"
  commit "add $1"
  reset_mocks
  echo "- None" > "$WORK/f"
  printf '%s\n' "- SUBJ-1: not applicable — documentation only" > "$WORK/d"
  dup_report "$WORK/f" "$WORK/d"
  inc_run
  check "$3" eval '[ "$STATUS" -eq "$want" ]'
  restore
}
na_case authors.py 20 "a source file named like a documentation file (authors.py) cannot be 'not applicable'"
na_case changelog.ts 20 "changelog.ts cannot be 'not applicable'"
na_case AUTHORS 0 "an extensionless AUTHORS file may be 'not applicable'"
na_case README 0 "an extensionless README may be 'not applicable'"
na_case GUIDE.md 0 "a Markdown document may be 'not applicable'"

# Same-file semantic duplicates: two new implementations in one new file can be reported; self-overlap cannot.
cat > "$T/new.py" <<'EOF'
def to_slug(text):
    words = text.strip().lower().split()
    return "-".join(words)


def as_slug(value):
    pieces = []
    for piece in value.strip().lower().split():
        pieces.append(piece)
    return "-".join(pieces)
EOF
commit "two equivalent routines"
semantic_case() { # description expected-status file duplicate-of [expected error]
  reset_mocks
  finding CODEX-2 "$3" "$4" > "$WORK/f"
  printf '%s\n' "- SUBJ-1: duplicate (CODEX-2) — searched: strip().lower().split(), \"-\".join; compared: new.py" > "$WORK/d"
  dup_report "$WORK/f" "$WORK/d"
  inc_run
  if [ "$STATUS" -eq "$2" ] && { [ -z "${5:-}" ] || contains "$ERR" "$5"; }; then ok "$1"; else not_ok "$1" "status=$STATUS $ERR"; fi
}
semantic_case "a same-file semantic duplicate between two new routines is accepted" 0 new.py:6-10 new.py:1-3
semantic_case "a same-file reference overlapping its own new code is rejected" 20 new.py:6-10 new.py:8-9 "overlaps its own new code"
restore

# A semantic original outside a partial index is still reportable (bounded HEAD lookup), symlinks are not.
cp "$T/util.py" "$T/zz_original.py"
ln -s util.py "$T/zz_link.py"
commit "originals outside the index"
reset_mocks
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BASELINE"
OUTSIDE_BASE="$(newest)"
cat > "$T/sum2.py" <<'EOF'
def doubled_sum(xs):
    return sum(x + x for x in xs)
EOF
commit "semantic copy of zz_original"
partial_case() { # description expected-status duplicate-of [expected error]
  reset_mocks
  finding CODEX-2 sum2.py:1-2 "$3" > "$WORK/f"
  printf '%s\n' "- SUBJ-1: duplicate (CODEX-2) — searched: sum(, * 2; compared: zz_original.py" > "$WORK/d"
  dup_report "$WORK/f" "$WORK/d"
  GENCR_DUP_LIMITS=files=1 run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$OUTSIDE_BASE"
  if [ "$STATUS" -eq "$2" ] && { [ -z "${4:-}" ] || contains "$ERR" "$4"; }; then ok "$1"; else not_ok "$1" "status=$STATUS $ERR"; fi
}
partial_case "with a partial index, a semantic original outside the indexed files is accepted" 0 zz_original.py:1-5
partial_case "a symlink as the semantic original is rejected" 20 zz_link.py:1-5 "which is not a regular file"
check "that run really used a partial index" file_contains "$(newest)/00-shared-prompt.md" "Textual index: partial (file limit (1) reached)"
restore

# Paths containing ';' and ' — ' are kept whole, quoted or not.
cp "$T/util.py" "$T/semi;colon.py"
commit "semicolon path"
reset_mocks
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BASELINE"
SEMI_BASE="$(newest)"
cp "$T/new.py" "$T/new2.py" 2>/dev/null || printf 'def double_all(xs):\n    return sum(2 * x for x in xs)\n' > "$T/new2.py"
printf 'def double_all(xs):\n    return sum(2 * x for x in xs)\n' > "$T/new2.py"
commit "semantic copy of semi;colon.py"
for loc in '`semi;colon.py:1-5`' 'semi;colon.py:1-5'; do
  reset_mocks
  finding CODEX-2 new2.py:1-2 "$loc" > "$WORK/f"
  printf '%s\n' "- SUBJ-1: duplicate (CODEX-2) — searched: sum(2 *; compared: semi;colon.py" > "$WORK/d"
  dup_report "$WORK/f" "$WORK/d"
  run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$SEMI_BASE"
  check "a Duplicate of path containing ';' is parsed whole ($loc)" eval '[ "$STATUS" -eq 0 ]'
done
restore

# Bounded reads and one shared deadline.
check "oversized blobs are never read for subjects or provenance; expired matching stops and reports partial" \
  python3 -B - "$REPO/bin" "$T" "$BASELINE_SHA" <<'EOF'
import sys, time
sys.path.insert(0, sys.argv[1]); import gencr_duplicates as g
repo, prev = sys.argv[2], sys.argv[3]
calls = []
real = g.git
def spy(r, args, deadline, data=None):
    calls.append(args)
    return real(r, args, deadline, data)
g.git = spy
g.LIMITS["file_bytes"] = 10
if g.read_regular(repo, prev, "a.py", time.time() + 10) is not None or any(a[0] == "cat-file" for a in calls):
    sys.exit("an oversized blob was read")
if g.provenance(repo, prev, "a.py", "x", time.time() + 10) != "unknown" or any(a[0] == "cat-file" for a in calls):
    sys.exit("provenance read an oversized blob")
g.LIMITS["file_bytes"] = 1024 * 1024
text = open(repo + "/a.py").read()
index, texts, scan = g.build_index(repo, prev, time.time() + 30)
cands, trunc, partial = g.find_candidates(repo, [{"id": "SUBJ-1", "path": "x.py", "start": 1, "end": 9}],
                                          {"x.py": set(range(1, 10))}, index, dict(texts, **{"x.py": text}),
                                          prev, prev, "id", time.time() - 1)
if not (cands == [] and partial and "time budget" in partial):
    sys.exit("expired matching still produced %r" % cands)
# Selection (sort/merge) also observes the shared deadline: pairs collected in time, selection after expiry.
g.collect_pairs = lambda added, index, texts, pairs, deadline: pairs.extend(
    [["exact", "x.py", 1, 4, "a.py", 1, 4]] * 5000)
cands, trunc, partial = g.find_candidates(repo, [{"id": "SUBJ-1", "path": "x.py", "start": 1, "end": 9}],
                                          {"x.py": set()}, index, texts, prev, prev, "id", time.time() - 1)
sys.exit(0 if cands == [] and partial and "candidate selection stopped" in partial else "selection ignored the deadline")
EOF
echo "# tweak" >> "$T/a.py"
commit "tweak a.py"
check "a modified file too large to diff is a whole-file subject and is never diffed" \
  python3 -B - "$REPO/bin" "$T" "$BASELINE_SHA" <<'EOF'
import sys, time
sys.path.insert(0, sys.argv[1]); import gencr_duplicates as g
repo, prev = sys.argv[2], sys.argv[3]
calls = []
real = g.git
def spy(r, args, deadline, data=None):
    calls.append(args)
    return real(r, args, deadline, data)
g.git = spy
g.LIMITS["file_bytes"] = 10
subjects, added = g.change_subjects(repo, prev, "HEAD", time.time() + 30)
diffs = [a for a in calls if a[0] == "diff" and "-U3" in a]
whole = [s for s in subjects if s["path"] == "a.py" and s["end"] is None and "not diffed" in s["label"]]
sys.exit(0 if whole and not diffs else "subjects=%r diffs=%r" % (subjects, diffs))
EOF
git -C "$T" reset -q --hard HEAD~1
cat > "$T/big_added.py" <<'EOF'
placeholder = 1
EOF
python3 -B -c 'import sys; open(sys.argv[1], "w").write("x = 1\n" * 300000)' "$T/big_added.py"
commit "oversized added file"
inc_print
check "an oversized added file is a whole-file subject that is not read for line counts" \
  contains "$OUTPUT" "[added] big_added.py (whole file) (new file (not indexed: too large or not a regular file))"
reset_mocks
GENCR_DUP_LIMITS=seconds=0 run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BASELINE"
check "a time budget exhausted while listing subjects is INCOMPLETE before any reviewer runs" \
  eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "could not list every change subject"'
restore

# ── Coverage paths without textual candidates ──────────────────────────────────

# Deletion-only change: removing a guard leaves a surviving routine; it is still a subject.
cat > "$T/c.py" <<'EOF'
def scaled_total(values, factor):
    if factor is None:
        raise ValueError("factor required")
    total = 0
    for value in values:
        total += value * factor
    return total
EOF
commit "add scaled_total"
BEFORE_DEL="$(git -C "$T" rev-parse HEAD)"
reset_mocks
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BASELINE"
DEL_BASE="$(newest)"
python3 -B - "$T/c.py" <<'EOF'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n")
open(p, "w").write("\n".join(lines[:1] + lines[3:]))
EOF
commit "drop the guard"
reset_mocks
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$DEL_BASE" --print
check "a deletion-only edit of a surviving routine is a subject anchored at HEAD" \
  eval 'contains "$OUTPUT" "  - SUBJ-1 [deletion-only] c.py:1-" && contains "$OUTPUT" "none found by the textual pre-search. This is NOT evidence"'
reset_mocks
touch "$MOCK_STATE/no-auto-dup-1"
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$DEL_BASE"
check "the deletion-only subject still requires a duplication account" eval '[ "$STATUS" -eq 20 ]'
restore

# Small/disjoint hunks and a semantic equivalent: subjects, no textual candidate.
cat > "$T/d.py" <<'EOF'
def sum_doubled(items):
    return sum(2 * item for item in items)
EOF
commit "semantic equivalent of existing_helper"
inc_print
check "a semantic equivalent with no matching windows still gets a subject and the semantic-search instruction" \
  eval 'contains "$OUTPUT" "  - SUBJ-1 [added] d.py:1-2" && ! contains "$OUTPUT" "  - DUP-1" && contains "$OUTPUT" "semantically equivalent"'
restore

# Two new copies of each other, a pure move, same-file sibling copy, overlapping self-windows.
cp "$T/a.py" "$T/e.py"
python3 -B -c 'import sys; open(sys.argv[1], "a").write("\n\ndef normalize_name_two(raw_name):\n    cleaned = raw_name.strip().lower()\n    parts = [p for p in cleaned.split(\" \") if p]\n    joined = \"-\".join(parts)\n    return joined.replace(\"--\", \"-\")\n")' "$T/a.py"
commit "copies"
inc_print
check "a same-file sibling copy of approved code is a candidate pointing at the original lines" \
  eval 'contains "$OUTPUT" "for SUBJ-1: new a.py:" && contains "$OUTPUT" "Existing code a.py:1-5"'
check "an exact copy in a new file is an exact candidate" contains "$OUTPUT" "(exact) for SUBJ-2: new e.py:1-5"
restore
git -C "$T" mv a.py moved.py
commit "pure move"
inc_print
check "a pure move (old copy gone) produces no textual candidate" eval '! contains "$OUTPUT" "  - DUP-1"'
restore
python3 -B -c 'import sys; open(sys.argv[1], "w").write("".join("value = compute(alpha, beta) + %d\n" % 1 for _ in range(10)))' "$T/repeat.py"
commit "repeated lines"
inc_print
check "overlapping windows of one new block never match themselves" eval '! contains "$OUTPUT" "  - DUP-1"'
restore
# Appending lines identical to existing ones: the new window must not match the existing lines it overlaps.
python3 -B -c 'import sys; open(sys.argv[1], "w").write("".join("value = compute(alpha, beta) + 1\n" for _ in range(4)))' "$T/rep.py"
commit "existing repeated lines"
reset_mocks
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BASELINE"
REP_BASE="$(newest)"
python3 -B -c 'import sys; open(sys.argv[1], "a").write("".join("value = compute(alpha, beta) + 1\n" for _ in range(3)))' "$T/rep.py"
commit "append repeated lines"
reset_mocks
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$REP_BASE" --print
check "a new window never matches existing lines it overlaps" eval '! contains "$OUTPUT" "Existing code rep.py:1-4"'
restore
cp "$T/a.py" "$T/new_a.py"
cp "$T/a.py" "$T/new_b.py"
commit "two new copies"
inc_print
check "two new copies of each other are both subjects for the semantic comparison of new code" \
  eval 'contains "$OUTPUT" "[added] new_a.py:1-5" && contains "$OUTPUT" "[added] new_b.py:1-5" && contains "$OUTPUT" "other new code in this change"'
restore

# Changed literals do not match; markers inside strings are not comments.
python3 -B -c 'import sys; s = open(sys.argv[1]).read().replace("\"-\"", "\"_\"").replace("normalize_name(raw_name)", "other(x)"); open(sys.argv[2], "w").write(s)' "$T/a.py" "$T/lit.py"
commit "changed literals"
inc_print
check "a copy with changed string literals is not a renamed candidate (literals are kept)" eval '! contains "$OUTPUT" "  - DUP-1"'
restore
check "comment stripping keeps comment markers inside strings and removes real comments" \
  python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import gencr_duplicates as g
py = g.strip_comments("url = \"http://x/#a\"  # note\ns = '"'"'a // b'"'"'\n", "hash")
c = g.strip_comments("u = \"http://x\"; // note\n/* block\n */ k = `a # b`;\n", "c")
ok = "#a\"" in py and "note" not in py and "a // b" in py and "http://x" in c and "note" not in c and "block" not in c and "`a # b`" in c and c.count("\n") == 3
sys.exit(0 if ok else 1)' "$REPO/bin"

# Candidate fairness: one subject with many copies cannot take every slot.
python3 -B - "$T/a.py" "$T/many.py" "$T/one.py" <<'EOF'
import sys
body = open(sys.argv[1]).read()
copies = [body.replace("normalize_name(raw_name)", "copy_%d(x%d)" % (i, i)) for i in range(5)]
open(sys.argv[2], "w").write("\n\n".join(copies))
open(sys.argv[3], "w").write(body.replace("normalize_name", "only_one"))
EOF
commit "many copies"
inc_print
check "at most 3 candidates per subject, other subjects still get theirs, truncation is stated" \
  eval '[ "$(printf "%s\n" "$OUTPUT" | grep -c "for SUBJ-1: new many.py")" -eq 3 ] && contains "$OUTPUT" "for SUBJ-2: new one.py" && contains "$OUTPUT" "more textual matches exist than are shown"'
restore

# ── Subject budget, partial index, resource safety ─────────────────────────────

python3 -B -c 'import sys; open(sys.argv[1], "w").write("".join("line_%04d = %d\n" % (i, i) for i in range(2100)))' "$T/big.py"
commit "big file"
reset_mocks
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BASELINE"
BIG_BASE="$(newest)"
python3 -B -c 'import sys
p = sys.argv[1]; lines = open(p).read().split("\n")
for i in range(0, 450, 10): lines[i] = lines[i] + "  # touched"
open(p, "w").write("\n".join(lines))' "$T/big.py"
commit "45 hunks"
reset_mocks
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BIG_BASE" --print
check "45 changed hunks are all listed as subjects (no truncation)" eval '[ "$(printf "%s\n" "$OUTPUT" | grep -c "^  - SUBJ-")" -eq 45 ]'
reset_mocks
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BIG_BASE"
check "every one of 45 subjects is accounted for in a valid report" eval '[ "$STATUS" -eq 0 ]'
reset_mocks
python3 -B - "$MOCK_STATE" <<'EOF'
import os, sys
open(os.path.join(sys.argv[1], "no-auto-dup-1"), "w").close()
lines = "\n".join("- SUBJ-%d: no duplicate found — searched: line_; compared: none" % i for i in range(1, 45))
open(os.path.join(sys.argv[1], "responses", "1"), "w").write("""r

## Findings
- None

## Disposition of peer findings
- None

## Merge blockers
- None

## Outstanding disputed findings
- None

## Previous findings verification
- None

## Duplication check
%s

## Review notes
- Verified clean: None
- Unresolved risks: None
- Disproven claims: None
- Test gaps: None
- Out-of-scope ownership changes: None
- Other observations: None

VERDICT: APPROVED
PEER-AGREEMENT: N/A
PEER-REPORT: N/A
""" % lines)
EOF
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BIG_BASE"
check "a report covering only the first 44 of 45 subjects is INCOMPLETE" eval '[ "$STATUS" -eq 20 ] && contains "$ERR" "has no line for SUBJ-45"'
git -C "$T" reset -q --hard HEAD~1
python3 -B -c 'import sys
p = sys.argv[1]; lines = open(p).read().split("\n")
for i in range(0, 2020, 10): lines[i] = lines[i] + "  # touched"
open(p, "w").write("\n".join(lines))' "$T/big.py"
commit "202 hunks"
reset_mocks
run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BIG_BASE"
check "more than 200 subjects: INCOMPLETE before any reviewer runs, package saved" \
  eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "too many changed hunks" && [ "$(json_get "$(newest)/metadata.json" "d[\"outcome\"]")" = INCOMPLETE ]'
restore

cp "$T/a.py" "$T/b.py"
commit "copy for partial index"
reset_mocks
GENCR_DUP_LIMITS=files=1 run_gencr dev --codex=review --incremental --output-dir="$OUT" --previous="$BASELINE"
PART="$(newest)"
check "a partial index is labelled everywhere and still requires every subject account" \
  eval '[ "$STATUS" -eq 0 ] && file_contains "$PART/summary.md" "- Duplication Index: partial (file limit (1) reached)" && file_contains "$PART/00-shared-prompt.md" "Textual index: partial (file limit (1) reached). Candidates below may be incomplete"'
restore

SENTINEL="$WORK/outside sentinel.py"
cp "$T/a.py" "$SENTINEL"
ln -s "$SENTINEL" "$T/link.py"
cp "$T/a.py" "$T/q\"uo te.py"
commit "symlink and unusual name"
inc_print
check "a tracked symlink to an external file is skipped, never read" \
  eval 'contains "$OUTPUT" "skipped: symlink 1" && ! contains "$OUTPUT" "Existing code link.py"'
check "unusual file names appear verbatim in subjects and candidates" contains "$OUTPUT" "new q\"uo te.py:1-5"
reset_mocks
finding CODEX-2 'q"uo te.py:1-5' a.py:1-5 > "$WORK/f"
SUBJ_LINES="$(printf '%s\n' "$OUTPUT" | sed -n 's/^  - \(SUBJ-[0-9]*\) .*/\1/p')"
{ for s in $SUBJ_LINES; do echo "- $s: no duplicate found — searched: x; compared: none"; done
  echo "- DUP-1: duplicate (CODEX-2) — exact copy"; } > "$WORK/d"
dup_report "$WORK/f" "$WORK/d"
inc_run
check "paired evidence with an unusual path validates exactly" eval '[ "$STATUS" -eq 0 ]'
restore

check "provenance facts cover present, not found and unknown for each snapshot" \
  python3 -B - "$REPO/bin" "$T" "$MERGE_BASE" "$BASELINE_SHA" <<'EOF'
import sys, time
sys.path.insert(0, sys.argv[1]); import gencr_duplicates as g
repo, mb, prev = sys.argv[2:5]; dl = time.time() + 30
region = open(repo + "/a.py").read().rstrip("\n")
cases = {
    (mb, "a.py"): "not found at this path", (prev, "a.py"): "exact region present at this path",
    ("0" * 40, "a.py"): "unknown", (prev, "util.py"): "not found at this path",
}
for (commit, path), want in cases.items():
    got = g.provenance(repo, commit, path, region, dl)
    if got != want:
        sys.exit("%s %s: %s != %s" % (commit[:7], path, got, want))
EOF

# ── Orchestration: both orders and reconciliation keep the check ───────────────

cp "$T/a.py" "$T/b.py"
commit "copy for adversarial runs"
for order in "--codex=attack" "--codex=review --claude=attack"; do
  reset_mocks
  # shellcheck disable=SC2086
  run_gencr dev $order --incremental --output-dir="$OUT" --previous="$BASELINE"
  check "adversarial incremental ($order): every invocation receives the subjects and candidates, reports validate" \
    eval '[ "$STATUS" -eq 0 ] && [ "$(grep -l "^  - DUP-1 (exact) for SUBJ-1" "$MOCK_STATE"/call-*.stdin | wc -l | tr -d " ")" -eq "$(calls)" ]'
done
reset_mocks
MOCK_VERDICT="REQUEST CHANGES" run_gencr dev --codex=attack --incremental --output-dir="$OUT" --previous="$BASELINE"
check "reconciliation rounds keep the duplication check in every invocation" \
  eval '[ "$(calls)" -ge 2 ] && [ "$(grep -l "^- Change subjects" "$MOCK_STATE"/call-*.stdin | wc -l | tr -d " ")" -eq "$(calls)" ]'
restore

# ── FRESH is unchanged ─────────────────────────────────────────────────────────

BASE_TREE="$WORK/baseline tree"
mkdir -p "$BASE_TREE/bin"
cp -R "$REPO/dotfiles" "$BASE_TREE/"
reset_mocks
(cd "$T" && "$GENCR" dev --codex=attack --output-dir="$OUT" --print) > "$WORK/fresh-now" 2>/dev/null
check "FRESH prompts contain no duplication check" eval '! grep -q "Duplication check\|SUBJ-\|DUP-" "$WORK/fresh-now"'
if [ -n "${GENCR_BASELINE_DIR:-}" ] && [ -f "$GENCR_BASELINE_DIR/gencr" ]; then
  cp "$GENCR_BASELINE_DIR/gencr" "$GENCR_BASELINE_DIR/gencr_support.py" "$BASE_TREE/bin/"
  chmod +x "$BASE_TREE/bin/gencr"
  reset_mocks
  (cd "$T" && "$BASE_TREE/bin/gencr" dev --codex=attack --output-dir="$OUT" --print) > "$WORK/fresh-before" 2>/dev/null
  (cd "$T" && "$GENCR" dev --codex=attack --output-dir="$OUT" --print) > "$WORK/fresh-after" 2>/dev/null
  check "the FRESH prompt is byte-identical to the previous implementation (install path normalized)" \
    python3 -B -c 'import sys; a = open(sys.argv[1]).read().replace(sys.argv[3], "ROOT"); b = open(sys.argv[2]).read().replace(sys.argv[4], "ROOT"); sys.exit(0 if a == b and a else 1)' \
    "$WORK/fresh-before" "$WORK/fresh-after" "$BASE_TREE" "$REPO"
fi
check "the review engine still contains no GitHub API or gh usage" \
  eval '! grep -nE "api\.github\.com|(^|[^a-z_])gh (api|pr|run)|GITHUB_" "$REPO/bin/gencr_duplicates.py"'
check "no duplication artifact is written inside the reviewed repository" \
  eval '[ -z "$(git -C "$T" status --porcelain --untracked-files=all)" ]'

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
