#!/usr/bin/env bash
# Peer-finding ownership tests for bin/gencr: a reviewer accepts, rejects or disputes the other reviewer's findings
# only by reference (## Disposition of peer findings, ## Merge blockers), never by restating them in its own
# ## Findings; references must name a finding of the assessed peer report, once; accepted peer findings keep their
# original ID, author and assessed version in findings.json, the full report and the GitHub summary.
# Replays a sanitized copy of a real failed reconciliation (tests/fixtures/peer-finding-id) in both reviewer orders.
# Mock reviewer CLIs; no network. Usage: bash tests/test_gencr_peer.sh
# shellcheck disable=SC2016,SC2034  # deferred eval checks

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO/tests/fixtures/peer-finding-id"
WORK="$(cd -P "$(mktemp -d)" && pwd)/gencr peer tests"
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

# ── 1. The real failure, replayed: still rejected, nothing renamed or repaired ──

for order in claude codex; do
  if [ "$order" = claude ]; then P=Claude PP=CLAUDE A=Codex AP=CODEX p=claude a=codex; else P=Codex PP=CODEX A=Claude AP=CLAUDE p=codex a=claude; fi
  reset_mocks
  fixture 1 01-claude-initial "$order"; fixture 2 02-codex-attack "$order"; fixture 3 03-claude-reconcile "$order"
  # shellcheck disable=SC2046
  run_gencr "replay-$order" $(order_flags "$order")
  R3="$PKG/$(rid 3 1 "$p" reconcile)"
  check "$order-first replay: the restated peer findings are rejected (exit 20, INCOMPLETE, 3 calls)" \
    eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 3 ] && [ "$(json_get "$PKG/metadata.json" "d[\"outcome\"]")" = INCOMPLETE ]'
  check "$order-first replay: the error names the original rule and the offending heading" \
    contains "$ERR" "${P}'s report $(rid 3 1 "$p" reconcile) is invalid: each finding must start with a bold ${PP}-<n> ID: - **${AP}-1 First sync can replace a file a concurrent import just added (accepted; tracked under ${A}'s ID)**"
  check "$order-first replay: the error says where a peer finding belongs instead" \
    contains "$ERR" "${AP}-1 is ${A}'s finding: evaluate ${A}'s findings only under '## Disposition of peer findings'"
  check "$order-first replay: the response is kept byte for byte; normalization does not repair it" \
    eval 'cmp -s "$R3.report.md" "$R3.report.original.md" && cmp -s "$R3.report.md" "$MOCK_STATE/responses/3" && [ "$(json_get "$R3.normalization.json" "d[\"result\"]")" = irreparable ]'
  check "$order-first replay: no peer finding is renamed into the primary's IDs" \
    eval '[ "$(json_get "$PKG/findings.json" "[f[\"id\"] + \":\" + f[\"reported_by\"] for f in d[\"final_findings\"] if \"concurrent\" in f[\"title\"]]")" = "['"'"'${AP}-1:$a'"'"']" ]'

  # The same reconciliation without the restated blocks passes and keeps every accepted peer finding.
  reset_mocks
  fixture 1 01-claude-initial "$order"; fixture 2 02-codex-attack "$order"; fixture 3 03-claude-reconcile "$order"
  drop_blocks 3 "$AP"
  # shellcheck disable=SC2046
  run_gencr "fixed-$order" $(order_flags "$order")
  R2ID="$(rid 2 0 "$a" attack)" R3ID="$(rid 3 1 "$p" reconcile)"
  check "$order-first corrected: the reconciliation is valid and the review ends agreed (exit 10, 3 calls)" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 3 ] && [ "$(json_get "$PKG/metadata.json" "d[\"end_reason\"]")" = "agreement: both reviewers request changes with materially aligned findings" ]'
  expected="$(printf '%s\n' "${PP}-1:$p:$R3ID:True" "${PP}-2:$p:$R3ID:True" "${PP}-3:$p:$R3ID:False" "${PP}-4:$p:$R3ID:False" \
    "${PP}-5:$p:$R3ID:False" "${PP}-7:$p:$R3ID:False" "${AP}-1:$a:$R2ID:True" "${AP}-2:$a:$R2ID:True" "${AP}-3:$a:$R2ID:True" \
    "${AP}-4:$a:$R2ID:False" "${AP}-5:$a:$R2ID:True" | sort)"
  check "$order-first corrected: findings.json keeps each peer finding once, under its author and assessed report" \
    eval '[ "$(finals)" = "$expected" ]'
  check "$order-first corrected: the canonical report gives the peer findings their original text and provenance" \
    eval 'grep -qxF -- "- **${AP}-4 The time budget does not bound a response in flight**" "$PKG/full-report.md" && grep -qxF -- "  - Provenance: defined by ${A} in report $R2ID" "$PKG/full-report.md" && ! grep -qF "tracked under" "$PKG/findings.json"'
  BLOCK="$(block)"
  check "$order-first corrected: the summary shows the accepted blocker with the primary's acceptance" \
    contains "$BLOCK" "**${AP}-1** First sync can overwrite a concurrently imported file (critical) — listed as a merge blocker by ${P} and ${A}; ${P}: accepted"
  check "$order-first corrected: the accepted non-blocking peer finding survives in the summary" \
    contains "$BLOCK" "**${AP}-4** The time budget does not bound a response in flight (medium) — reported by ${A}; ${P}: accepted"
  check "$order-first corrected: the disputed peer finding is shown as disputed" \
    contains "$BLOCK" "**${AP}-2** A failed handoff is reported as a successful sync (high) — listed as a merge blocker by ${A}; ${P}: disputed"

  # The generated instructions say where peer findings go (shared, role and handoff).
  check "$order-first prompts: no reviewer is asked for 'complete updated findings' or 'every finding you currently stand behind'" \
    eval '! grep -qF "complete updated findings" "$MOCK_STATE"/call-*.stdin && ! grep -qF "every finding you currently stand behind" "$MOCK_STATE"/call-*.stdin'
  check "$order-first prompts: the shared rules forbid restating a peer finding and say where acceptance goes" \
    eval 'grep -qF "never copy, restate, rename or renumber the other reviewer'"'"'s findings there, not even ones you accept" "$MOCK_STATE/call-1.stdin"'
  check "$order-first prompts: the reconcile handoff lists exactly the peer findings to evaluate" \
    eval 'grep -qxF -- "- ${A}'"'"'s findings to evaluate (one row each under '"'"'## Disposition of peer findings'"'"'; never copy them into '"'"'## Findings'"'"'): ${AP}-1, ${AP}-2, ${AP}-3, ${AP}-4, ${AP}-5" "$MOCK_STATE/call-3.stdin"'
  check "$order-first prompts: a fresh review lists no carried-forward findings and no own-finding row ban" \
    eval '! grep -qF "carries forward" "$MOCK_STATE"/call-*.stdin && ! grep -qF "for your own findings" "$MOCK_STATE"/call-*.stdin'
  check "$order-first prompts: the attack handoff lists the primary's findings" \
    eval 'grep -qF -- "- ${P}'"'"'s findings to evaluate (one row each under '"'"'## Disposition of peer findings'"'"'; never copy them into '"'"'## Findings'"'"'): ${PP}-1, ${PP}-2, ${PP}-3, ${PP}-4, ${PP}-5, ${PP}-6, ${PP}-7" "$MOCK_STATE/call-2.stdin"'
done

# ── 2. Peer-only REQUEST CHANGES; retention of accepted findings the author no longer lists ──

for order in claude codex; do
  if [ "$order" = claude ]; then P=Claude A=Codex AP=CODEX p=claude a=codex; else P=Codex A=Claude AP=CLAUDE p=codex a=claude; fi
  reset_mocks
  gen_for "$order" 1 primary '{"verdict": "APPROVED"}'
  gen_for "$order" 2 adversary "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"NO\", \"peer\": \"$(rid 1 0 claude initial)\",
    \"findings\": [{\"id\": \"CODEX-1\", \"title\": \"Peer blocker\"}], \"blockers\": [\"CODEX-1\"]}"
  gen_for "$order" 3 primary "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"YES\", \"peer\": \"$(rid 2 0 codex attack)\",
    \"dispositions\": [\"CODEX-1: accepted — confirmed in the code\"], \"blockers\": [\"CODEX-1\"]}"
  # shellcheck disable=SC2046
  run_gencr "peeronly-$order" $(order_flags "$order")
  check "$order-first: a primary with no findings of its own requests changes on an accepted peer finding (exit 10)" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(finals)" = "${AP}-1:$a:$(rid 2 0 "$a" attack):True" ]'

  # The author drops an accepted non-blocker in its final report: it is kept from the assessed report.
  retention_run() { # DEV CODEX2_IN_FINAL(no|changed) [EXTRA_BLOCKER] [ROW_ID]
    reset_mocks
    local final_findings='{"id": "CODEX-1", "title": "Peer blocker"}' blockers='"CLAUDE-1", "CODEX-1"' row="${4:-CODEX-2}"
    [ "$2" = changed ] && final_findings="$final_findings"', {"id": "CODEX-2", "title": "Peer non-blocker", "severity": "Medium", "fix": "a different fix"}'
    [ -z "$3" ] || blockers="$blockers, \"$3\""
    gen_for "$order" 1 primary '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Own blocker"}], "blockers": ["CLAUDE-1"]}'
    gen_for "$order" 2 adversary "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"NO\", \"peer\": \"$(rid 1 0 claude initial)\",
      \"findings\": [{\"id\": \"CODEX-1\", \"title\": \"Peer blocker\"}, {\"id\": \"CODEX-2\", \"title\": \"Peer non-blocker\", \"severity\": \"Medium\"}],
      \"dispositions\": [\"CLAUDE-1: accepted — confirmed\"], \"blockers\": [\"CLAUDE-1\", \"CODEX-1\"]}"
    gen_for "$order" 3 primary "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"NO\", \"peer\": \"$(rid 2 0 codex attack)\",
      \"findings\": [{\"id\": \"CLAUDE-1\", \"title\": \"Own blocker\"}],
      \"dispositions\": [\"CODEX-1: accepted — confirmed\", \"$row: accepted — confirmed, not blocking\"], \"blockers\": [$blockers]}"
    gen_for "$order" 4 adversary "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"YES\", \"peer\": \"$(rid 3 1 claude reconcile)\",
      \"findings\": [$final_findings], \"dispositions\": [\"CLAUDE-1: accepted — confirmed\"], \"blockers\": [\"CLAUDE-1\", \"CODEX-1\"]}"
    # shellcheck disable=SC2046
    run_gencr "$1" $(order_flags "$order")
  }
  retention_run "keep-$order" no
  R2ID="$(rid 2 0 "$a" attack)" R3ID="$(rid 3 1 "$p" reconcile)" R4ID="$(rid 4 1 "$a" respond)"
  check "$order-first: an accepted non-blocker the author no longer lists is kept from the assessed report" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 4 ] && finals | grep -qxF "${AP}-2:$a:$R2ID:False" && [ "$(finals | grep -c "^${AP}-2:")" -eq 1 ]'
  check "$order-first: its provenance names the author's report, the acceptance and the author's final report" \
    grep -qxF -- "  - Provenance: defined by ${A} in report $R2ID (accepted by ${P} in its final report $R3ID; not in ${A}'s final report $R4ID)" "$PKG/full-report.md"
  check "$order-first: the summary keeps it with the acceptance of that version" \
    contains "$(block)" "**${AP}-2** Peer non-blocker (medium) — reported by ${A}; ${P}: accepted"

  for row in codex-2 Codex-2; do
    retention_run "case-$order" no "" "$row"
    check "$order-first: a unique '$row' row is the same acceptance everywhere (validation, retention, provenance, summary)" \
      eval '[ "$STATUS" -eq 10 ] && finals | grep -qxF "${AP}-2:$a:$R2ID:False" && [ "$(json_get "$PKG/findings.json" "[f[\"accepted_by\"][\"agent\"] for f in d[\"final_findings\"] if f.get(\"accepted_by\")]")" = "['"'"'$p'"'"']" ] &&
            grep -qxF -- "  - Provenance: defined by ${A} in report $R2ID (accepted by ${P} in its final report $R3ID; not in ${A}'"'"'s final report $R4ID)" "$PKG/full-report.md" &&
            contains "$(block)" "**${AP}-2** Peer non-blocker (medium) — reported by ${A}; ${P}: accepted"'
  done

  retention_run "changed-$order" changed
  check "$order-first: a changed but still listed peer finding is not recovered; its label names the earlier version" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(finals | grep -c "^${AP}-2:")" -eq 1 ] && finals | grep -qxF "${AP}-2:$a:$R4ID:False" && contains "$(block)" "${P}: accepted an earlier version (report $R2ID)"'

  retention_run "overlap-$order" no CODEX-2
  check "$order-first: an accepted peer finding that is also a cited blocker is kept once" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(finals | grep -c "^${AP}-2:")" -eq 1 ] && finals | grep -qxF "${AP}-2:$a:$R2ID:True" && [ "$(grep -c "^- \*\*${AP}-2 " "$PKG/full-report.md")" -ge 1 ]'
done

# ── 3. Reference integrity: fabricated, stale and duplicate disposition rows fail before packaging ──

# ref_case ORDER DESCRIPTION EXPECTED-ERROR PYTHON-EDIT — edits the primary's corrected reconciliation (call 3).
ref_case() {
  local order="$1" desc="$2" expect="$3" AP
  if [ "$order" = claude ]; then AP=CODEX; else AP=CLAUDE; fi
  reset_mocks
  fixture 1 01-claude-initial "$order"; fixture 2 02-codex-attack "$order"; fixture 3 03-claude-reconcile "$order"
  drop_blocks 3 "$AP"
  edit_reply 3 "$4"
  # shellcheck disable=SC2046
  run_gencr "ref-$order" $(order_flags "$order")
  if [ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 3 ] && contains "$ERR" "$expect"; then ok "$order-first: $desc"
  else not_ok "$order-first: $desc" "status=$STATUS err=$(printf '%s' "$ERR" | tail -n 2)"; fi
}
for order in claude codex; do
  if [ "$order" = claude ]; then PP=CLAUDE AP=CODEX A=Codex; else PP=CODEX AP=CLAUDE A=Claude; fi
  R2ID="$(rid 2 0 "$( [ "$order" = claude ] && echo codex || echo claude)" attack)"
  anchor="- ${AP}-5: accepted"
  ref_case "$order" "an own-prefix fabricated acceptance is rejected" \
    "disposition row ${PP}-999 does not name a finding in ${A}'s report $R2ID" "s.replace('$anchor', '- ${PP}-999: accepted — checked\n$anchor')"
  ref_case "$order" "a fabricated peer ID is rejected" \
    "disposition row ${AP}-9 does not name a finding in ${A}'s report $R2ID" "s.replace('$anchor', '- ${AP}-9: accepted — checked\n$anchor')"
  ref_case "$order" "contradictory rows (accepted, then rejected) are rejected" \
    "duplicate disposition rows for ${AP}-4" "s.replace('$anchor', '- ${AP}-4: rejected — not reachable\n$anchor')"
  ref_case "$order" "contradictory rows (rejected, then accepted) are rejected" \
    "duplicate disposition rows for ${AP}-4" "s.replace('- ${AP}-4: accepted', '- ${AP}-4: rejected — not reachable\n- ${AP}-4: accepted')"
  ref_case "$order" "accepted and disputed rows for one finding are rejected" \
    "duplicate disposition rows for ${AP}-3" "s.replace('$anchor', '- ${AP}-3: disputed — partly\n$anchor')"
  ref_case "$order" "a repeated identical row is rejected" \
    "duplicate disposition rows for ${AP}-3" "s.replace('$anchor', '- ${AP}-3: accepted — again\n$anchor')"
  ref_case "$order" "a duplicate row in another letter case is rejected" \
    "duplicate disposition rows for ${AP}-3" "s.replace('$anchor', '- $(echo "$AP" | tr '[:upper:]' '[:lower:]')-3: rejected — no\n$anchor')"
  ref_case "$order" "the required-row rule still holds (a peer finding without a row)" \
    "has no '- ${AP}-4: accepted|rejected|disputed" "s.replace('- ${AP}-4: accepted — The deadline is checked only before requests. Medium, not blocking.\n', '')"

  # A row before any peer report exists (initial report) names nothing.
  reset_mocks
  fixture 1 01-claude-initial "$order"
  edit_reply 1 "s.replace('## Disposition of peer findings\n- None', '## Disposition of peer findings\n- ${AP}-1: accepted — seen')"
  # shellcheck disable=SC2046
  run_gencr "na-$order" $(order_flags "$order")
  check "$order-first: a disposition row in an initial report is rejected" \
    eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "disposition row ${AP}-1 does not name a finding in the other reviewer'"'"'s report (there is none yet)"'
done

# A row for a finding defined only in an earlier peer report (not the assessed one) is rejected.
for order in claude codex; do
  if [ "$order" = claude ]; then AP=CODEX A=Codex a=codex; else AP=CLAUDE A=Claude a=claude; fi
  reset_mocks
  gen_for "$order" 1 primary '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1"}], "blockers": ["CLAUDE-1"]}'
  gen_for "$order" 2 adversary "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"NO\", \"peer\": \"$(rid 1 0 claude initial)\",
    \"findings\": [{\"id\": \"CODEX-1\"}, {\"id\": \"CODEX-2\"}], \"dispositions\": [\"CLAUDE-1: accepted — ok\"], \"blockers\": [\"CODEX-1\"]}"
  gen_for "$order" 3 primary "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"NO\", \"peer\": \"$(rid 2 0 codex attack)\",
    \"findings\": [{\"id\": \"CLAUDE-1\"}], \"dispositions\": [\"CODEX-1: disputed — unclear\", \"CODEX-2: disputed — unclear\"], \"blockers\": [\"CLAUDE-1\"]}"
  gen_for "$order" 4 adversary "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"NO\", \"peer\": \"$(rid 3 1 claude reconcile)\",
    \"findings\": [{\"id\": \"CODEX-1\"}], \"dispositions\": [\"CLAUDE-1: accepted — ok\"], \"blockers\": [\"CODEX-1\"]}"
  gen_for "$order" 5 primary "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"YES\", \"peer\": \"$(rid 4 1 codex respond)\",
    \"findings\": [{\"id\": \"CLAUDE-1\"}], \"dispositions\": [\"CODEX-1: accepted — ok\", \"CODEX-2: accepted — ok\"], \"blockers\": [\"CLAUDE-1\", \"CODEX-1\"]}"
  # shellcheck disable=SC2046
  run_gencr "stale-$order" $(order_flags "$order")
  check "$order-first: a row for a finding only in an earlier peer report is rejected" \
    eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 5 ] && contains "$ERR" "disposition row ${AP}-2 does not name a finding in ${A}'"'"'s report $(rid 4 1 "$a" respond)"'
done

# ── 4. Continued acceptance of a finding its author no longer lists (source-qualified rows) ──

# later_run ORDER DEV SPEC... — the claude-first conversation below, then extra replies "N:role:json" (mirrored).
# 1 primary CLAUDE-1; 2 adversary CODEX-1 (blocker) + CODEX-2 (non-blocker); 3 primary accepts both (NO);
# 4 adversary omits CODEX-2 (NO). Calls 5+ come from the arguments.
later_run() {
  local order="$1" dev="$2" item n role spec
  shift 2
  reset_mocks
  gen_for "$order" 1 primary '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Own blocker"}], "blockers": ["CLAUDE-1"]}'
  gen_for "$order" 2 adversary '{"verdict": "REQUEST CHANGES", "agreement": "NO", "peer": "01-round0-claude-initial",
    "findings": [{"id": "CODEX-1", "title": "Peer blocker"}, {"id": "CODEX-2", "title": "Still accepted nonblocker", "severity": "Medium"}],
    "dispositions": ["CLAUDE-1: accepted — checked"], "blockers": ["CLAUDE-1", "CODEX-1"]}'
  gen_for "$order" 3 primary '{"verdict": "REQUEST CHANGES", "agreement": "NO", "peer": "02-round0-codex-attack",
    "findings": [{"id": "CLAUDE-1", "title": "Own blocker"}], "blockers": ["CLAUDE-1", "CODEX-1"],
    "dispositions": ["CODEX-1: accepted — checked", "CODEX-2: accepted — a valid nonblocking defect"]}'
  gen_for "$order" 4 adversary '{"verdict": "REQUEST CHANGES", "agreement": "NO", "peer": "03-round1-claude-reconcile",
    "findings": [{"id": "CODEX-1", "title": "Peer blocker"}], "dispositions": ["CLAUDE-1: accepted — checked"], "blockers": ["CLAUDE-1", "CODEX-1"]}'
  for item in "$@"; do
    n="${item%%:*}" item="${item#*:}" role="${item%%:*}" spec="${item#*:}"
    gen_for "$order" "$n" "$role" "$spec"
  done
  # shellcheck disable=SC2046
  run_gencr "$dev" $(order_flags "$order")
}
# A primary reply to report $1 (claude-first names) with agreement $2 and extra disposition rows $3 (JSON strings).
primary_reply() { echo "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"$2\", \"peer\": \"$1\", \"findings\": [{\"id\": \"CLAUDE-1\", \"title\": \"Own blocker\"}],
  \"blockers\": [\"CLAUDE-1\", \"CODEX-1\"], \"dispositions\": [\"CODEX-1: accepted — checked\"$3]}"; }
adversary_reply() { # PEER AGREEMENT [EXTRA_FINDING_JSON]
  echo "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"$2\", \"peer\": \"$1\", \"findings\": [{\"id\": \"CODEX-1\", \"title\": \"Peer blocker\"}$3],
  \"dispositions\": [\"CLAUDE-1: accepted — checked\"], \"blockers\": [\"CLAUDE-1\", \"CODEX-1\"]}"; }
KEEP=', "CODEX-2 (report 02-round0-codex-attack): accepted — still a valid nonblocking defect"'

for order in claude codex; do
  if [ "$order" = claude ]; then P=Claude A=Codex p=claude a=codex PP=CLAUDE AP=CODEX; else P=Codex A=Claude p=codex a=claude PP=CODEX AP=CLAUDE; fi
  R2ID="$(rid 2 0 "$a" attack)" R4ID="$(rid 4 1 "$a" respond)" R6ID="$(rid 6 2 "$a" respond)"
  HANDOFF_KEEP="- Findings you accepted that ${A}'s report %s no longer lists (to keep accepting one, write its row as shown, with your evidence; leave it out to withdraw your acceptance): - ${AP}-2 (report $R2ID): accepted — <evidence>"

  later_run "$order" "keep-$order" "5:primary:$(primary_reply 04-round1-codex-respond YES "$KEEP")"
  R5ID="$(rid 5 1 "$p" reconcile)"
  check "$order-first: the handoff tells the primary how to keep accepting the omitted finding" \
    grep -qxF -- "$(printf -- "$HANDOFF_KEEP" "$R4ID")" "$MOCK_STATE/call-5.stdin"
  check "$order-first: a source-qualified acceptance keeps the omitted finding, from its source report" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 5 ] && finals | grep -qxF "${AP}-2:$a:$R2ID:False" &&
          grep -qxF -- "  - Provenance: defined by ${A} in report $R2ID (accepted by ${P} in its final report $R5ID; not in ${A}'"'"'s final report $R4ID)" "$PKG/full-report.md" &&
          [ "$(json_get "$PKG/findings.json" "[(f[\"accepted_by\"][\"agent\"], f[\"accepted_by\"][\"report_id\"]) for f in d[\"final_findings\"] if f.get(\"accepted_by\")]")" = "[('"'"'$p'"'"', '"'"'$R5ID'"'"')]" ] &&
          contains "$(block)" "**${AP}-2** Still accepted nonblocker (medium) — reported by ${A}; ${P}: accepted"'

  later_run "$order" "keep2-$order" "5:primary:$(primary_reply 04-round1-codex-respond NO "$KEEP")" \
    "6:adversary:$(adversary_reply 05-round1-claude-reconcile NO)" "7:primary:$(primary_reply 06-round2-codex-respond YES "$KEEP")"
  R7ID="$(rid 7 2 "$p" reconcile)"
  check "$order-first: across repeated omissions the recorded source stays the original report" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 7 ] && grep -qxF -- "$(printf -- "$HANDOFF_KEEP" "$R6ID")" "$MOCK_STATE/call-7.stdin" &&
          finals | grep -qxF "${AP}-2:$a:$R2ID:False" && grep -qF "(accepted by ${P} in its final report $R7ID; not in ${A}'"'"'s final report $R6ID)" "$PKG/full-report.md"'

  later_run "$order" "withdraw-$order" "5:primary:$(primary_reply 04-round1-codex-respond NO "$KEEP")" \
    "6:adversary:$(adversary_reply 05-round1-claude-reconcile NO)" "7:primary:$(primary_reply 06-round2-codex-respond YES "")"
  check "$order-first: leaving the qualified row out withdraws the acceptance (the finding is gone)" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 7 ] && ! finals | grep -q "^${AP}-2:" && ! grep -qF "${AP}-2" "$PKG/findings.json"'

  later_run "$order" "relist-$order" "5:primary:$(primary_reply 04-round1-codex-respond NO "$KEEP")" \
    "6:adversary:$(adversary_reply 05-round1-claude-reconcile YES ', {"id": "CODEX-2", "title": "Still accepted nonblocker", "severity": "Medium", "fix": "a revised fix"}')"
  check "$order-first: a re-listed changed finding is the author's version; the earlier qualified acceptance is labelled as such" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 6 ] && finals | grep -qxF "${AP}-2:$a:$R6ID:False" && contains "$(block)" "${P}: accepted an earlier version (report $R2ID)"'

  later_run "$order" "relist2-$order" "5:primary:$(primary_reply 04-round1-codex-respond NO "$KEEP")" \
    "6:adversary:$(adversary_reply 05-round1-claude-reconcile NO ', {"id": "CODEX-2", "title": "Still accepted nonblocker", "severity": "Medium", "fix": "a revised fix"}')" \
    "7:primary:$(primary_reply 06-round2-codex-respond YES "$KEEP")"
  check "$order-first: once re-listed, the next reply must assess the current version (qualified row rejected)" \
    eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 7 ] && contains "$ERR" "${AP}-2 is in ${A}'"'"'s report $R6ID: assess its current version with a plain '"'"'- ${AP}-2: <status> — <evidence>'"'"' row"'

  # A failing acceptance-history helper stops the review before the next reviewer is launched (fail closed).
  # Forwards to the interpreter itself (sys.executable), never to a launcher shim that could resolve back to this wrapper.
  mkdir -p "$WORK/fault bin"
  cat > "$WORK/fault bin/python3" <<FAULT
#!/bin/sh
case "\$*" in *kept-acceptances*$(rid 3 1 "$p" reconcile)*) echo "gencr: error: injected kept-acceptances failure" >&2; exit 7 ;; esac
exec $(printf '%s' "$REAL_PYTHON" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/") "\$@"
FAULT
  chmod +x "$WORK/fault bin/python3"
  PATH="$WORK/fault bin:$PATH" later_run "$order" "fault-$order" "5:primary:$(primary_reply 04-round1-codex-respond YES "$KEEP")"
  check "$order-first: a failed acceptance-history helper makes the review INCOMPLETE before call 5 (exit 20)" \
    eval '[ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 4 ] && contains "$ERR" "injected kept-acceptances failure" && contains "$ERR" "${P} was not launched" &&
          [ "$(json_get "$PKG/metadata.json" "d[\"outcome\"]")" = INCOMPLETE ] && cmp -s "$PKG/$(rid 3 1 "$p" reconcile).report.md" "$MOCK_STATE/responses/3"'

  # Invalid qualified rows fail before packaging (call 5 answers report 04, which omits CODEX-2).
  qualified_case() { # DESCRIPTION EXPECTED ROWS_JSON
    later_run "$order" "qual-$order" "5:primary:$(primary_reply 04-round1-codex-respond YES "$3")"
    if [ "$STATUS" -eq 20 ] && [ "$(calls)" -eq 5 ] && contains "$ERR" "$2"; then ok "$order-first: $1"
    else not_ok "$order-first: $1" "status=$STATUS calls=$(calls) err=$(printf '%s' "$ERR" | tail -n 2)"; fi
  }
  qualified_case "a qualified row naming the reviewer's own report is rejected" "report $(rid 3 1 "$p" reconcile) is not a valid earlier report by ${A} in this review" \
    ', "CODEX-2 (report 03-round1-claude-reconcile): accepted — mine"'
  qualified_case "a qualified row naming an unknown report is rejected" "report 99-round9-$a-respond is not a valid earlier report by ${A} in this review" \
    ', "CODEX-2 (report 99-round9-codex-respond): accepted — invented"'
  qualified_case "a qualified row naming the assessed report itself is rejected" "report $R4ID is not a valid earlier report by ${A} in this review" \
    ', "CODEX-2 (report 04-round1-codex-respond): accepted — current"'
  qualified_case "a qualified row whose source does not define the finding is rejected" "${AP}-7 is not defined in ${A}'s report $R2ID" \
    ', "CODEX-2 (report 02-round0-codex-attack): accepted — ok", "CODEX-7 (report 02-round0-codex-attack): accepted — invented"'
  qualified_case "a qualified row for a finding the assessed report lists is rejected" "${AP}-1 is in ${A}'s report $R4ID: assess its current version" \
    ', "CODEX-1 (report 02-round0-codex-attack): accepted — again"'
  qualified_case "a qualified rejected row is rejected (only acceptance can be kept)" "only 'accepted' can be kept from an earlier report" \
    ', "CODEX-2 (report 02-round0-codex-attack): rejected — not a defect"'
  qualified_case "a qualified disputed row is rejected" "only 'accepted' can be kept from an earlier report" \
    ', "CODEX-2 (report 02-round0-codex-attack): disputed — unsure"'
  qualified_case "a qualified row without evidence is rejected" "malformed source-qualified disposition row" \
    ', "CODEX-2 (report 02-round0-codex-attack): accepted —"'
  qualified_case "a malformed source qualifier is rejected, not read as prose" "malformed source-qualified disposition row" \
    ', "CODEX-2 (report): accepted — which one"'
  qualified_case "a duplicate qualified row (other letter case) is rejected" "duplicate disposition rows for ${AP}-2" \
    "$KEEP"', "codex-2 (report 02-round0-codex-attack): accepted — again"'
  qualified_case "an unqualified row for the omitted finding is still rejected" "disposition row ${AP}-2 does not name a finding in ${A}'s report $R4ID" \
    ', "CODEX-2: accepted — still holds"'
done

# ── 5. Incremental reviews: carried-forward findings keep their original IDs across prefixes ──

INC_DIR="$WORK/inc reports"
reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Claude original"}], "blockers": ["CLAUDE-1"]}'
gen 2 "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"YES\", \"peer\": \"$(rid 1 0 claude initial)\",
  \"findings\": [{\"id\": \"CODEX-1\", \"title\": \"Codex original\"}], \"dispositions\": [\"CLAUDE-1: accepted — ok\"], \"blockers\": [\"CLAUDE-1\", \"CODEX-1\"]}"
run_gencr inc --codex=attack --output-dir="$INC_DIR" --pr-number=7
FRESH_PKG="$(ls -d "$INC_DIR"/review-*)"
check "incremental baseline: a fresh review with open CLAUDE-1 and CODEX-1" eval '[ "$STATUS" -eq 10 ] && [ -f "$FRESH_PKG/manifest.json" ]'
echo '# touched' >> "$TARGET/app.py"
git -C "$TARGET" commit -qam "follow-up"

for order in claude codex; do
  if [ "$order" = claude ]; then P=Claude A=Codex p=claude a=codex PP=CLAUDE AP=CODEX; else P=Codex A=Claude p=codex a=claude PP=CODEX AP=CLAUDE; fi
  # The primary carries the peer-prefixed previous finding (not fixed); the adversary assesses it by its original ID.
  inc_run() { # EXTRA_ADVERSARY_FINDING(json or empty) [omit: the adversary drops the carried definition]
    reset_mocks
    local extra="" own="" carried="{\"id\": \"${AP}-1\", \"title\": \"${A} original\"}"
    [ "$2" != omit ] || carried=""
    [ -z "$1" ] || { extra=", $1"; own=", {\"id\": \"${PP}-5\", \"title\": \"Restated new finding\"}"; }
    gen 1 "{\"verdict\": \"REQUEST CHANGES\", \"findings\": [{\"id\": \"${AP}-1\", \"title\": \"${A} original\"}$own], \"blockers\": [\"${AP}-1\"],
      \"verification\": [\"${AP}-1: not fixed — still present\", \"${PP}-1: fixed — corrected\"]}"
    gen 2 "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"YES\", \"peer\": \"$(rid 1 0 "$p" initial)\",
      \"findings\": [$carried$extra], \"dispositions\": [\"${AP}-1: accepted — still present\"],
      \"blockers\": [\"${AP}-1\"], \"verification\": [\"${AP}-1: not fixed — still present\", \"${PP}-1: fixed — confirmed\"]}"
    # shellcheck disable=SC2046
    run_gencr inc $(order_flags "$order") --incremental --output-dir="$INC_DIR" --pr-number=7 --previous="$FRESH_PKG"
    PKG="$(ls -td "$INC_DIR"/review-* | head -n 1)"
  }
  inc_run ""
  check "$order-first incremental: a cross-prefix carried finding is defined and assessed under its original ID" \
    eval '[ "$STATUS" -eq 10 ] && [ "$(json_get "$PKG/findings.json" "sorted({f[\"id\"] for f in d[\"final_findings\"]})")" = "['"'"'${AP}-1'"'"']" ]'
  check "$order-first incremental: the adversary's handoff lists the carried finding as carried forward, not as reference-only" \
    eval 'grep -qxF -- "- Previous findings that ${P}'"'"'s report carries forward (one row each under '"'"'## Disposition of peer findings'"'"'; if you verify one as not fixed, it must also stay in your '"'"'## Findings'"'"' under its original ID): ${AP}-1" "$MOCK_STATE/call-2.stdin" &&
          grep -qxF -- "- ${P}'"'"'s findings to evaluate (one row each under '"'"'## Disposition of peer findings'"'"'; never copy them into '"'"'## Findings'"'"'): none" "$MOCK_STATE/call-2.stdin"'
  check "$order-first incremental: no instruction forbids keeping or assessing the carried finding" \
    eval '! grep -qF "for your own findings" "$MOCK_STATE/call-2.stdin" && ! grep -qF "never copy them into '"'"'## Findings'"'"'): ${AP}-1" "$MOCK_STATE/call-2.stdin"'
  # A reply that assesses the carried finding but drops its required definition is still rejected.
  inc_run "" omit
  check "$order-first incremental: assessing the carried finding without keeping its definition is still rejected" \
    eval '[ "$STATUS" -eq 20 ] && contains "$ERR" "previous finding ${AP}-1 is not fixed but is missing from '"'"'## Findings'"'"'"'
  check "$order-first incremental: the first prompt never says to write None while a carried finding is still open" \
    eval '! grep -qF "When none of the findings you stand behind are your own" "$MOCK_STATE/call-1.stdin" &&
          grep -qF "Write \"- None\" under \"## Findings\" only when you have no findings of your own and no previous findings to carry forward as not fixed" "$MOCK_STATE/call-1.stdin"'
  check "$order-first incremental: the prompt states the carried-forward exception" \
    grep -qF 'the only case in which "## Findings" may hold an ID with the other reviewer'"'"'s prefix' "$MOCK_STATE/call-1.stdin"
  # Restating a finding the peer defined in this run (not a previous finding) is still rejected.
  inc_run "{\"id\": \"${PP}-5\", \"title\": \"Restated new finding\"}"
  check "$order-first incremental: restating a current-run peer finding is still rejected" \
    eval '[ "$STATUS" -eq 20 ] && contains "$ERR" "each finding must start with a bold ${AP}-<n> ID: - **${PP}-5 Restated new finding**"'
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
