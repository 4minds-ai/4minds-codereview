#!/usr/bin/env bash
# GitHub-ready review comment tests for bin/gencr: one deterministic block in summary.md, printed locally between
# GITHUB REVIEW COMMENT markers and wrapped by the CI PR comment; blockers first and never silently omitted;
# finding-level assessments only; convergence and incomplete results stated; actions copied verbatim.
# Mock reviewer CLIs; no network. Usage: bash tests/test_gencr_summary.sh
# shellcheck disable=SC2016,SC2034  # deferred eval checks

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd -P "$(mktemp -d)" && pwd)/gencr summary tests"
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
printf 'def handler():\n    return 1\n' > "$TARGET/app.py"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm feature
HEAD_SHA="$(git -C "$TARGET" rev-parse HEAD)"

# Every scenario is an independent first review: no earlier package of the same developer may be its baseline.
reset_mocks() { rm -rf "$MOCK_STATE" "${HOME:?}/Documents/CodeReview"; mkdir -p "$MOCK_STATE/responses"; }
calls() { cat "$MOCK_STATE/count" 2>/dev/null || echo 0; }
rid() { printf '%02d-round%d-%s-%s' "$1" "$2" "$3" "$4"; }
run_gencr() { # [env assignments via env] ARGS...
  (cd "$TARGET" && "$REPO/bin/gencr" dev "$@") > "$WORK/stdout" 2> "$WORK/stderr"
  STATUS=$?; OUT="$(cat "$WORK/stdout")"; ERR="$(cat "$WORK/stderr")"
  PKG="$(ls -td "$HOME/Documents/CodeReview/dev"/review-* 2>/dev/null | head -n 1)"
}
# The copyable block printed between the terminal markers.
printed() { sed -n '/^========== GITHUB REVIEW COMMENT ==========$/,/^========== END REVIEW COMMENT ==========$/p' "$WORK/stdout" | sed '1d;$d'; }
saved() { python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import gencr_summary as g; sys.stdout.write(g.extract(open(sys.argv[2]).read()))' "$REPO/bin" "$PKG/summary.md"; }

# gen N JSON — a contract-v2 reviewer response from a spec: verdict, agreement, peer, findings [{id,title,severity,fix,
# evidence,introduced}], blockers [ids], dispositions {id: "status — evidence"} (accepted/disputed rows get the facets
# of a reviewer that agrees with the author's severity: introduced yes, the author's severity in the answered report,
# blocking as this reply's own blocker list says; a value that already has facets is written as given), withdrawn
# [lines], supplemental [lines], disputes [lines], verification [lines].
gen() {
  python3 -B - "$MOCK_STATE/responses/$1" "$2" "$MOCK_STATE/responses" <<'EOF'
import json, os, re, sys
path, spec, responses = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
def severity_of(fid):
    peer = spec.get("peer", "N/A")
    source = os.path.join(responses, str(int(peer[:2]))) if peer != "N/A" else ""
    text = open(source).read() if source and os.path.exists(source) else ""
    m = re.search(r"^- \*\*%s .*\n(?:  .*\n)*?  - Severity: (.*)$" % re.escape(fid), text, re.M)
    value = (m.group(1) if m else "high").lower()
    return "critical" if ("blocker" in value or "critical" in value) else next(
        (s for s in ("high", "medium", "low") if s in value), "high")
blockers = spec.get("blockers", [])
out = ["Report.", "", "## Findings"]
for f in spec.get("findings", []):
    out.append("- **%s %s**" % (f["id"], f.get("title", "A finding")))
    fix = f.get("fix", "apply the fix").split("\n")
    out += ["  - Severity: %s" % f.get("severity", "High"), "  - Introduced by this change: %s" % f.get("introduced", "yes"),
            "  - File: app.py:1", "  - Problem: problem text",
            "  - Evidence: %s" % f.get("evidence", "EVIDENCE-SENTINEL observed"), "  - Expected vs actual: x vs y",
            "  - Tests: none", "  - Fix: " + fix[0]] + ["    " + line if line else "" for line in fix[1:]]
if not spec.get("findings"):
    out.append("- None")
out += ["", "## Withdrawn findings"] + (["- " + w for w in spec.get("withdrawn", [])] or ["- None"])
rows = []
for k, v in spec.get("dispositions", {}).items():
    m = re.match(r"^(accepted|disputed)( (?:—|-) .*)$", v)
    if m:
        v = "%s; introduced: yes; severity: %s; blocking: %s%s" % (m.group(1), severity_of(k.upper()),
                                                                 "yes" if k.upper() in blockers else "no", m.group(2))
    rows.append("- %s: %s" % (k, v))
out += ["", "## Disposition of peer findings"] + (rows or ["- None"])
out += ["", "## Merge blockers"] + (["- " + b for b in blockers] or ["- None"])
out += ["", "## Supplemental objections"] + (["- " + s for s in spec.get("supplemental", [])] or ["- None"])
out += ["", "## Outstanding disputed findings"] + (["- " + d for d in spec.get("disputes", [])] or ["- None"])
if "verification" in spec:
    out += ["", "## Previous findings verification"] + ["- " + v for v in spec["verification"]]
out += ["", "## Review notes"] + ["- %s: None" % label for label in ("Verified clean", "Unresolved risks", "Disproven claims",
                                                                      "Test gaps", "Out-of-scope ownership changes",
                                                                      "Other observations")]
out += ["", "VERDICT: " + spec["verdict"], "PEER-AGREEMENT: " + spec.get("agreement", "N/A"),
        "PEER-REPORT: " + spec.get("peer", "N/A"), ""]
open(path, "w").write("\n".join(out))
EOF
}

# ── Local terminal output equals summary.md; brief; no local paths inside ──────

reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [
  {"id": "CLAUDE-1", "title": "High non-blocker", "severity": "High"},
  {"id": "CLAUDE-2", "title": "Low blocker", "severity": "Low", "fix": "add the missing test"},
  {"id": "CLAUDE-3", "title": "Medium blocker", "severity": "Medium", "fix": "validate input\nand reject empty values"}],
  "blockers": ["CLAUDE-2", "CLAUDE-3"]}'
ATTACK='"findings": [{"id": "CODEX-1", "title": "Codex blocker", "severity": "High"}], "blockers": ["CODEX-1", "CLAUDE-3"],
  "dispositions": {"CLAUDE-1": "accepted — confirmed", "CLAUDE-2": "rejected — the test exists", "CLAUDE-3": "disputed — not reachable"}'
PRIMARY_FINDINGS='{"id": "CLAUDE-1", "title": "High non-blocker", "severity": "High"},
  {"id": "CLAUDE-2", "title": "Low blocker", "severity": "Low", "fix": "add the missing test"},
  {"id": "CLAUDE-3", "title": "Medium blocker", "severity": "Medium", "fix": "validate input\nand reject empty values"}'
gen 2 "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"NO\", \"peer\": \"$(rid 1 0 claude initial)\", $ATTACK}"
# The primary accepts CODEX-1 as a blocker; both keep their positions on CLAUDE-2/3 to the cap; the primary's last report
# adds CLAUDE-4, which Codex therefore never assessed.
for n in 3 5 7 9; do
  case "$n" in 3) peer="$(rid 2 0 codex attack)" ;; 5) peer="$(rid 4 1 codex respond)" ;; 7) peer="$(rid 6 2 codex respond)" ;; 9) peer="$(rid 8 3 codex respond)" ;; esac
  late=""; [ "$n" -eq 9 ] && late=', {"id": "CLAUDE-4", "title": "Late finding", "severity": "High"}'
  gen "$n" "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"NO\", \"peer\": \"$peer\", \"findings\": [$PRIMARY_FINDINGS$late],
    \"blockers\": [\"CLAUDE-2\", \"CLAUDE-3\", \"CODEX-1\"], \"dispositions\": {\"CODEX-1\": \"accepted — confirmed\"}}"
done
for n in 4 6 8; do
  case "$n" in 4) peer="$(rid 3 1 claude reconcile)" ;; 6) peer="$(rid 5 1 claude reconcile)" ;; 8) peer="$(rid 7 2 claude reconcile)" ;; esac
  gen "$n" "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"NO\", \"peer\": \"$peer\", $ATTACK}"
done
run_gencr --codex=attack
BLOCK="$(printed)"
section() { printf '%s\n' "$BLOCK" | sed -n "/^### $1/,/^### /p" | sed '1d;/^### /d'; }
check "local run: the primary's REQUEST CHANGES applies after the cap (exit 10, 9 calls)" eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 9 ]'
check "local run: the terminal prints the block between the GITHUB REVIEW COMMENT markers" \
  eval 'contains "$OUT" "========== GITHUB REVIEW COMMENT ==========" && contains "$OUT" "========== END REVIEW COMMENT ==========" && contains "$BLOCK" "## Code review: REQUEST CHANGES"'
check "local run: the printed block is byte-identical to summary.md's block" eval '[ "$BLOCK" = "$(saved)" ]'
check "local run: the report path is printed after the END marker, not inside the block" \
  eval '[ "$(sed -n "/^========== END REVIEW COMMENT ==========$/,\$p" "$WORK/stdout" | sed -n 2p)" = "Complete report: $(ls "$HOME/Documents/CodeReview/dev"/code-review-*.md | tail -n 1)" ] &&
        ! contains "$BLOCK" "$HOME" && ! contains "$BLOCK" "$WORK" && ! contains "$BLOCK" "/Documents/"'
check "local run: the full report is not dumped (no file list, no Problem text; evidence only for attacker objections)" \
  eval '! contains "$OUT" "## Files examined" && ! contains "$OUT" "problem text" && contains "$(section "Attacker objections")" "EVIDENCE-SENTINEL" &&
        ! printf "%s\n" "$BLOCK" | sed -n "/^### Merge blockers (primary reviewer)/,\$p" | grep -q "EVIDENCE-SENTINEL" && [ "$(printf "%s\n" "$OUT" | wc -l)" -lt 120 ]'
check "local run: stderr keeps the final-verdict line, with the non-unanimous qualification" \
  eval 'contains "$ERR" "gencr: final verdict: ❌ REQUEST CHANGES by primary reviewer — NOT UNANIMOUS; 2 attacker objections remain; report:"'
check "minimal metadata: verdict, mode, reviewed SHA, actual models" \
  eval 'contains "$BLOCK" "- Mode: FRESH" && contains "$BLOCK" "- Reviewed commit: $HEAD_SHA" && contains "$BLOCK" "Claude: mock-claude-default; Codex: mock-codex-default" && ! contains "$BLOCK" "Run ID"'
check "verdict qualification, both verdicts and the objection count come first" \
  eval 'contains "$BLOCK" "- REQUEST CHANGES by primary reviewer — NOT UNANIMOUS; 2 attacker objections remain." && contains "$BLOCK" "- Verdicts: Claude (primary): REQUEST CHANGES; Codex (attacker): REQUEST CHANGES" && contains "$BLOCK" "- Attacker objections: 2"'
check "attacker objections are listed first, ranked by severity (medium before low)" \
  eval '[ "$(section "Attacker objections" | grep -oE "^- \*\*(CLAUDE|CODEX)-[0-9]+\*\*" | grep -oE "(CLAUDE|CODEX)-[0-9]+" | tr "\n" " ")" = "CLAUDE-3 CLAUDE-2 " ]'
check "the primary's merge blockers are ranked by severity, before other significant findings" \
  eval '[ "$(section "Merge blockers (primary reviewer)" | grep -oE "^- \*\*(CLAUDE|CODEX)-[0-9]+\*\*" | grep -oE "(CLAUDE|CODEX)-[0-9]+" | tr "\n" " ")" = "CODEX-1 CLAUDE-3 CLAUDE-2 " ] &&
        section "Other significant findings" | grep -q "CLAUDE-1"'
check "every primary blocker is counted with the total" eval 'contains "$BLOCK" "- Merge blockers (primary reviewer): 3" && ! contains "$BLOCK" "this summary lists"'
check "blocker attribution is per reviewer, never 'confirmed'" \
  eval 'contains "$BLOCK" "**CLAUDE-3** Medium blocker (medium) — listed as a merge blocker by Claude and Codex" && ! contains "$BLOCK" "onfirmed"'
check "finding-level assessments: rejected and disputed are shown, with resolve-or-settle wording" \
  eval 'contains "$BLOCK" "**CLAUDE-2** Low blocker (low) — listed as a merge blocker by Claude; Codex: rejected — resolve before merge: fix it or settle the dispute" &&
        contains "$BLOCK" "Codex: disputed — resolve before merge" && contains "$BLOCK" "**CLAUDE-1** High non-blocker (high) — reported by Claude; Codex: accepted"'
check "a finding the other reviewer never saw is 'not assessed', never agreed" \
  eval 'contains "$BLOCK" "**CLAUDE-4** Late finding (high) — reported by Claude; not assessed by Codex" && contains "$BLOCK" "- Not reassessed: 1 findings"'
check "the recommended fix is complete and verbatim, including continuation lines (fenced)" \
  python3 -B -c 'import sys; sys.exit(0 if "  - Recommended fix:\n\n    ```\n    validate input\n    and reject empty values\n    ```\n" in sys.argv[1] else 1)' "$BLOCK"
check "the attacker's position on each objection is explicit (existence, blocking) with the primary's response" \
  eval 'contains "$(section "Attacker objections")" "blocks merge — Claude: yes, Codex: —" && contains "$(section "Attacker objections")" "exists — Claude: asserted, Codex: rejected (opposed)"'

# ── Assessments tied to the assessed version; unresolved reconciliation (9 calls, 3 rounds) ──

limit_run() { # FINAL_CLAUDE_FIX — claude-first, both REQUEST CHANGES, agreement NO, to the round limit
  reset_mocks
  local n peer
  for n in 1 2 3 4 5 6 7 8 9; do
    if [ $((n % 2)) -eq 1 ]; then
      case "$n" in 1) peer=N/A ;; 3) peer="$(rid 2 0 codex attack)" ;; 5) peer="$(rid 4 1 codex respond)" ;;
        7) peer="$(rid 6 2 codex respond)" ;; 9) peer="$(rid 8 3 codex respond)" ;; esac
      fix="preserve existing records and validate input"; [ "$n" -eq 9 ] && fix="$1"
      gen "$n" "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"$([ "$n" -eq 1 ] && echo N/A || echo NO)\", \"peer\": \"$peer\",
        \"findings\": [{\"id\": \"CLAUDE-1\", \"title\": \"Records\", \"fix\": \"$fix\"}], \"blockers\": [\"CLAUDE-1\"],
        \"dispositions\": $([ "$n" -eq 1 ] && echo '{}' || echo '{"CODEX-1": "disputed — unclear"}')}"
    else
      case "$n" in 2) peer="$(rid 1 0 claude initial)" ;; 4) peer="$(rid 3 1 claude reconcile)" ;;
        6) peer="$(rid 5 1 claude reconcile)" ;; 8) peer="$(rid 7 2 claude reconcile)" ;; esac
      gen "$n" "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"NO\", \"peer\": \"$peer\",
        \"findings\": [{\"id\": \"CODEX-1\", \"title\": \"Codex view\"}], \"blockers\": [\"CODEX-1\"],
        \"dispositions\": {\"CLAUDE-1\": \"accepted — agreed\"}}"
    fi
  done
  run_gencr --codex=attack
  BLOCK="$(printed)"
}
limit_run "remove the stored records before validation"
check "limit run: still REQUEST CHANGES, exit 10, 9 calls, 3 rounds" \
  eval '[ "$STATUS" -eq 10 ] && [ "$(calls)" -eq 9 ] && [ "$(json_get "$PKG/metadata.json" "d[\"rounds\"]")" = 3 ]'
check "limit run: the remaining disagreement is stated (not unanimous) even though no disputed rows were written" \
  eval 'contains "$BLOCK" "- REQUEST CHANGES by primary reviewer — NOT UNANIMOUS; 2 attacker objections remain."'
check "a changed finding: the peer's acceptance is labelled as of the earlier version" \
  eval 'contains "$BLOCK" "Codex: accepted an earlier version (report $(rid 7 2 claude reconcile)); the current version was not assessed by Codex"'
limit_run "preserve existing records and validate input"
check "an unchanged finding keeps the peer's acceptance" \
  eval 'contains "$BLOCK" "**CLAUDE-1** Records (high) — listed as a merge blocker by Claude; Codex: accepted" && ! contains "$BLOCK" "earlier version"'

# ── Other outcomes ─────────────────────────────────────────────────────────────

reset_mocks
gen 1 '{"verdict": "APPROVED"}'
gen 2 "{\"verdict\": \"APPROVED\", \"agreement\": \"YES\", \"peer\": \"$(rid 1 0 claude initial)\"}"
run_gencr --codex=attack
BLOCK="$(printed)"
check "APPROVED by both: unanimous approval wording, no blockers, exit 0" \
  eval '[ "$STATUS" -eq 0 ] && contains "$BLOCK" "## Code review: APPROVED" && contains "$BLOCK" "- APPROVED — unanimous: both reviewers approve and agree on every finding." &&
        contains "$BLOCK" "No merge blockers were reported." && contains "$BLOCK" "- Merge blockers (primary reviewer): 0" && ! contains "$BLOCK" "NOT UNANIMOUS"'

reset_mocks
n=1
for step in "claude APPROVED N/A N/A" "codex RC NO $(rid 1 0 claude initial)" "claude APPROVED NO $(rid 2 0 codex attack)" \
            "codex RC NO $(rid 3 1 claude reconcile)" "claude APPROVED NO $(rid 4 1 codex respond)" "codex RC NO $(rid 5 1 claude reconcile)" \
            "claude APPROVED NO $(rid 6 2 codex respond)" "codex RC NO $(rid 7 2 claude reconcile)" "claude APPROVED NO $(rid 8 3 codex respond)"; do
  set -- $step
  verdict="$2"; [ "$verdict" = RC ] && verdict="REQUEST CHANGES"
  if [ "$1" = codex ]; then
    gen "$n" "{\"verdict\": \"$verdict\", \"agreement\": \"$3\", \"peer\": \"$4\", \"findings\": [{\"id\": \"CODEX-1\", \"title\": \"Blocker\"}], \"blockers\": [\"CODEX-1\"], \"disputes\": [\"CODEX-1 is disputed by Claude\"]}"
  else
    gen "$n" "{\"verdict\": \"$verdict\", \"agreement\": \"$3\", \"peer\": \"$4\", \"dispositions\": $([ "$n" -eq 1 ] && echo '{}' || echo '{"CODEX-1": "rejected — not a defect"}')}"
  fi
  n=$((n + 1))
done
run_gencr --codex=attack
BLOCK="$(printed)"
check "primary APPROVED, attacker REQUEST CHANGES at the cap: APPROVED (exit 0), never unanimous, both verdicts shown" \
  eval '[ "$STATUS" -eq 0 ] && contains "$BLOCK" "## Code review: APPROVED" && contains "$BLOCK" "- APPROVED by primary reviewer — NOT UNANIMOUS; 1 attacker objections remain." &&
        contains "$BLOCK" "- Verdicts: Claude (primary): APPROVED; Codex (attacker): REQUEST CHANGES" && ! contains "$BLOCK" "unanimous: both" && ! contains "$BLOCK" "No merge blockers were reported"'
check "primary APPROVED with objections: the attacker's finding, its evidence and the primary's response are shown" \
  eval 'contains "$BLOCK" "### Attacker objections" && contains "$BLOCK" "**CODEX-1** Blocker (Codex'"'"'s finding)" && contains "$BLOCK" "EVIDENCE-SENTINEL" &&
        contains "$BLOCK" "Primary response (Claude, report $(rid 9 3 claude reconcile)): not a defect" &&
        contains "$BLOCK" "Codex'"'"'s latest statement (report $(rid 8 3 codex respond); answered later by Claude in report $(rid 9 3 claude reconcile)): is disputed by Claude"'

reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Solo"}], "blockers": ["CLAUDE-1"]}'
run_gencr --claude=review
BLOCK="$(printed)"
check "single reviewer: no second assessment is claimed" \
  eval '[ "$STATUS" -eq 10 ] && contains "$BLOCK" "- Single reviewer (Claude); there was no second assessment." && contains "$BLOCK" "listed as a merge blocker by Claude; single reviewer"'

reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Kept"}], "blockers": ["CLAUDE-1"]}'
printf 'not a report\n' > "$MOCK_STATE/responses/2"
run_gencr --codex=attack
BLOCK="$(printed)"
check "INCOMPLETE: exit 20, no valid approval or rejection, no findings presented as results" \
  eval '[ "$STATUS" -eq 20 ] && contains "$BLOCK" "## Code review: INCOMPLETE — no valid approval or rejection was produced" && contains "$BLOCK" "- Reason: " &&
        contains "$BLOCK" "- 1 findings were reported before the review stopped" && ! contains "$BLOCK" "### Merge blockers" && ! contains "$BLOCK" "**CLAUDE-1**"'

reset_mocks
gen 1 '{"verdict": "APPROVED"}'
(cd "$TARGET" && GENCR_REVIEW_COMMENT=off "$REPO/bin/gencr" dev --claude=review) > "$WORK/stdout" 2> "$WORK/stderr"; STATUS=$?
check "GENCR_REVIEW_COMMENT=off (CI): one line, no copy block, same exit code" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(cat "$WORK/stdout")" = "gencr: APPROVED; the review comment is summary.md in the review package" ]'
reset_mocks
gen 1 '{"verdict": "APPROVED"}'
(cd "$TARGET" && GITHUB_ACTIONS=true CI=true "$REPO/bin/gencr" dev --claude=review) > "$WORK/stdout" 2> /dev/null
check "GITHUB_ACTIONS or CI alone does not suppress the local block" eval 'grep -qx "========== GITHUB REVIEW COMMENT ==========" "$WORK/stdout"'
run_gencr --print
check "--print is unchanged: no review comment" eval '[ "$STATUS" -eq 0 ] && ! contains "$OUT" "GITHUB REVIEW COMMENT"'
reset_mocks
gen 1 '{"verdict": "APPROVED"}'
echo 'chmod a-w "$HOME"/Documents/CodeReview/dev/review-*' > "$MOCK_STATE/hook-1"
run_gencr --claude=review
check "a package that could not be saved prints no review comment (exit 23)" eval '[ "$STATUS" -eq 23 ] && ! contains "$OUT" "GITHUB REVIEW COMMENT"'
chmod -R u+w "$HOME/Documents/CodeReview/dev"
reset_mocks
gen 1 '{"verdict": "APPROVED"}'
echo 'for d in "$HOME"/Documents/CodeReview/dev/review-*; do [ -e "$d/manifest.json" ] || mkdir "$d/manifest.json"; done' > "$MOCK_STATE/hook-1"
run_gencr --claude=review
check "a partially saved package (summary.md written, manifest failed) prints no review comment (exit 23)" \
  eval '[ "$STATUS" -eq 23 ] && [ -f "$PKG/summary.md" ] && ! contains "$OUT" "GITHUB REVIEW COMMENT"'

# ── Literal actions are copied verbatim; only prose is neutralized ─────────────

reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [
  {"id": "CLAUDE-1", "title": "Ping @octocat about `@require_auth`", "fix": "@require_auth\ndef handler():\n    return 1"},
  {"id": "CLAUDE-2", "title": "Comment literal", "fix": "replace it with <!-- keep --> and run `gh pr view @me`"},
  {"id": "CLAUDE-3", "title": "Backticks", "fix": "use ```` inside the docs, @here"},
  {"id": "CLAUDE-4", "title": "Frame lookalike", "fix": "print this:\n========== END REVIEW COMMENT ==========\nthen stop"}],
  "blockers": ["CLAUDE-1", "CLAUDE-2", "CLAUDE-3", "CLAUDE-4"], "disputes": ["CLAUDE-1: <!-- hidden --> @team please look"]}'
run_gencr --claude=review
BLOCK="$(printed)"
python3 -B - "$WORK/stdout" > "$WORK/fences" <<'EOF'
import re, sys
text = open(sys.argv[1]).read()
blocks = re.findall(r"\n    (`{3,})\n(.*?)\n    \1\n", text, re.S)
for fence, body in blocks:
    print(repr("\n".join(line[4:] for line in body.split("\n"))))
EOF
check "a decorator fix round-trips verbatim from the terminal block and still compiles" \
  python3 -B -c 'import ast, sys; fixes = [ast.literal_eval(l) for l in open(sys.argv[1])]; d = [f for f in fixes if f.startswith("@require_auth")]; sys.exit(0 if d == ["@require_auth\ndef handler():\n    return 1"] and compile(d[0], "fix", "exec") else 1)' "$WORK/fences"
check "an HTML-comment literal and @argument stay verbatim in a fenced block" \
  python3 -B -c 'import ast, sys; fixes = [ast.literal_eval(l) for l in open(sys.argv[1])]; sys.exit(0 if "replace it with <!-- keep --> and run `gh pr view @me`" in fixes else 1)' "$WORK/fences"
check "a fix with a long backtick run gets a longer fence" eval 'contains "$BLOCK" "    \`\`\`\`\`" && contains "$BLOCK" "use \`\`\`\` inside the docs, @here"'
check "a fix containing a frame marker is omitted as a whole, never altered" \
  eval 'contains "$BLOCK" "**CLAUDE-4** Frame lookalike" && contains "$BLOCK" "Recommended fix: see the complete review report (it cannot be shown here unambiguously)" && [ "$(grep -c "^========== END REVIEW COMMENT ==========$" "$WORK/stdout")" -eq 1 ]'
check "prose mentions are neutralized; a title with code is a literal code span (mentions inert there)" \
  eval 'contains "$BLOCK" "\`\` Ping @octocat about \`@require_auth\` \`\`" && contains "$BLOCK" "&lt;!-- hidden --&gt; @​team please look"'
check "the printed block still equals summary.md with literals present" eval '[ "$BLOCK" = "$(saved)" ]'

# ── Overflow and size boundaries (renderer; the same block feeds terminal and CI) ──

python3 -B - "$REPO/bin" <<'EOF' > "$WORK/overflow" 2>&1
import importlib.machinery, importlib.util, json, re, sys
sys.path.insert(0, sys.argv[1])
import gencr_summary as g
loader = importlib.machinery.SourceFileLoader("gencr_ci", sys.argv[1] + "/gencr-ci")
spec = importlib.util.spec_from_loader("gencr_ci", loader); ci = importlib.util.module_from_spec(spec); loader.exec_module(ci)

def data(n, title="Blocker title", fix="fix it", others=0, label="Codex: accepted"):
    findings = [{"id": "CLAUDE-%d" % (i + 1), "title": title, "severity": "high", "file": "app.py:%d" % (i + 1),
                 "fixes": [("claude", fix)], "blocker": True, "reporters": ["claude"], "listed_by": ["claude"],
                 "assessment": label, "contested": False} for i in range(n)]
    findings += [{"id": "CODEX-%d" % (i + 1), "title": "Other", "severity": "medium", "file": "b.py:1",
                  "fixes": [("codex", "x")], "blocker": False, "reporters": ["codex"], "listed_by": [],
                  "assessment": "not assessed by Claude", "contested": False} for i in range(others)]
    return {"final_verdict": "REQUEST CHANGES", "outcome": "REQUEST CHANGES", "convergence": "agreed", "error": None,
            "max_rounds": 3, "agents": ["claude", "codex"], "verdicts": {"claude": "REQUEST CHANGES", "codex": "REQUEST CHANGES"},
            "review_mode": "FRESH", "approval_scope_label": "Full PR", "head_sha": "a" * 40,
            "models": {"claude": "opus", "codex": "gpt"}, "findings": findings, "disputes": [], "surviving_findings": n}

def facts(block, n):
    shown = re.findall(r"^- \*\*(CLAUDE-\d+)\*\*", block, re.M)
    more = re.search(r"^- \+(\d+) more merge blockers(?:: (.*)|.*)$", block, re.M)
    hidden = int(more.group(1)) if more else 0
    listed = more.group(2).split(", ") if more and more.group(2) else []
    return shown, hidden, listed

result = {}
block = g.render(data(5000))
shown, hidden, listed = facts(block, 5000)
ids = {"CLAUDE-%d" % (i + 1) for i in range(5000)}
result["huge"] = (len(block) <= g.BUDGET and len(shown) + hidden == 5000 and set(shown) <= ids
                  and set(listed) <= ids and not set(listed) & set(shown) and
                  ("- Merge blockers: 5000 — this summary lists %d of 5000; the other %d are not shown here"
                   % (len(shown), 5000 - len(shown))) in block and "### Other" not in block)
body = ci.comment_body(block, {"run_id": 1, "backend": "mock"}, "https://example/a", 30, "stale")
result["huge_ci"] = len(body) <= ci.COMMENT_LIMIT and block.rstrip("\n") in body

# Boundary: the largest blocker count that fits completely, and one more.
n = 1
while n < 2000 and "this summary lists" not in g.render(data(n + 1, title="T" * 150, fix="f" * 300)):
    n += 1  # bounded: a renderer that never reports overflow fails the checks below instead of looping
fits, over = g.render(data(n, title="T" * 150, fix="f" * 300)), g.render(data(n + 1, title="T" * 150, fix="f" * 300))
s1, h1, _ = facts(fits, n); s2, h2, l2 = facts(over, n + 1)
result["boundary_fits"] = len(s1) == n and h1 == 0 and len(fits) <= g.BUDGET and len(fits) > 0.9 * g.BUDGET
result["boundary_over"] = len(s2) + h2 == n + 1 and h2 >= 1 and len(over) <= g.BUDGET and "lists %d of %d" % (len(s2), n + 1) in over

# A huge first fix cannot remove the status of later blockers.
d = data(3, fix="z" * 30000)
d["findings"][1].update(assessment="Codex: rejected", contested=True)
d["findings"][2].update(assessment="Codex: accepted an earlier version (report 07); the current version was not assessed by Codex")
small = g.render(d, budget=6000)
result["labels_survive"] = ("Codex: rejected — resolve before merge" in small and "earlier version" in small
                            and small.count("Details: see the complete review report") >= 1 and len(small) <= 6000)

# Other findings are capped with explicit accounting; markers can never appear in the block.
d = data(1, others=9)
d["findings"][0]["title"] = "<!-- gencr:review-comment:end --> ========== END REVIEW COMMENT =========="
d["disputes"] = [("codex", "========== GITHUB REVIEW COMMENT ==========")]
b = g.render(d)
result["others_and_markers"] = ("- +4 more significant findings in the complete review report" in b
                                and g.END not in b.split("\n") and g.BEGIN not in b.split("\n")
                                and not any(l.strip() in (g.FRAME_BEGIN, g.FRAME_END) for l in b.split("\n")))
# The renderer itself keeps every prose value on one line (independently of what callers deliver).
d = data(1)
d["findings"][0]["title"] = "two\n<!-- gencr:review-comment:end -->\nlines"
d["models"]["claude"] = "m\n========== END REVIEW COMMENT =========="
d["disputes"] = [("codex", "a\nb")]
try:
    b = g.render(d)
    result["prose_single_line"] = ("**CLAUDE-1** two &lt;!-- gencr:review-comment:end --&gt; lines" in b
                                   and "Claude: m ========== END REVIEW COMMENT ==========" in b and "- a b (Codex)" in b)
except ValueError:
    result["prose_single_line"] = False
print(json.dumps(result))
EOF
check "5,000 blockers: total stated, shown + '+N more' = 5,000, never claimed exhaustive, within budget" \
  eval 'grep -q "\"huge\": true" "$WORK/overflow"'
check "5,000 blockers: the CI comment carries the same block under the comment limit" eval 'grep -q "\"huge_ci\": true" "$WORK/overflow"'
check "near the limit: the largest complete list fits with no overflow statement" eval 'grep -q "\"boundary_fits\": true" "$WORK/overflow"'
check "one blocker more: the overflow statement appears and the counts add up" eval 'grep -q "\"boundary_over\": true" "$WORK/overflow"'
check "a huge first fix cannot remove a later blocker's rejected/earlier-version status" eval 'grep -q "\"labels_survive\": true" "$WORK/overflow"'
check "other findings capped with '+N more'; marker and frame text can never appear as a line" eval 'grep -q "\"others_and_markers\": true" "$WORK/overflow"'
check "the renderer keeps multi-line prose values on one line (no marker line, no fallback)" eval 'grep -q "\"prose_single_line\": true" "$WORK/overflow"'
[ "$FAIL" -eq 0 ] || cat "$WORK/overflow"

# ── Revision 1 (codex SUM-I1..I5) ──────────────────────────────────────────────

# SUM-I1: a closed stdout never changes the review's exit status or its saved package.
reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Piped"}], "blockers": ["CLAUDE-1"]}'
CLOSED="$(cd "$TARGET" && python3 -B -c 'import os, subprocess, sys
r, w = os.pipe(); os.close(r)
print(subprocess.run(sys.argv[1:], stdout=w, stderr=subprocess.DEVNULL).returncode)' "$REPO/bin/gencr" dev --claude=review)"
PKG="$(ls -td "$HOME/Documents/CodeReview/dev"/review-* | head -n 1)"
check "closed stdout: exit 10 (not SIGPIPE), complete package saved" eval '[ "$CLOSED" = 10 ] && [ -f "$PKG/manifest.json" ]'
reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Piped"}], "blockers": ["CLAUDE-1"]}'
(cd "$TARGET" && GENCR_REVIEW_COMMENT=off python3 -B -c 'import os, subprocess, sys
r, w = os.pipe(); os.close(r)
print(subprocess.run(sys.argv[1:], stdout=w, stderr=subprocess.DEVNULL).returncode)' "$REPO/bin/gencr" dev --claude=review) > "$WORK/closed-off"
check "closed stdout with the CI opt-out: exit 10" eval '[ "$(cat "$WORK/closed-off")" = 10 ]'

# SUM-I2: an unfixed prior finding repeated by both reviewers is one blocker, with both provenances.
INC_OUT="$WORK/inc-out"
incremental_pair() { # CODEX_FIX
  rm -rf "$INC_OUT"; git -C "$TARGET" checkout -q feature; git -C "$TARGET" reset -q --hard "$HEAD_SHA"
  reset_mocks
  gen 1 '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Carried", "fix": "validate input"}], "blockers": ["CLAUDE-1"]}'
  gen 2 "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"YES\", \"peer\": \"$(rid 1 0 claude initial)\", \"blockers\": [\"CLAUDE-1\"], \"dispositions\": {\"CLAUDE-1\": \"accepted — confirmed\"}}"
  (cd "$TARGET" && "$REPO/bin/gencr" dev --codex=attack --output-dir="$INC_OUT") > /dev/null 2>&1
  printf 'x = 2\n' > "$TARGET/second.py"; git -C "$TARGET" add . && git -C "$TARGET" commit -qm second
  reset_mocks
  gen 1 '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Carried", "fix": "validate input"}], "blockers": ["CLAUDE-1"], "verification": ["CLAUDE-1: not fixed — still unvalidated"]}'
  gen 2 "{\"verdict\": \"REQUEST CHANGES\", \"agreement\": \"YES\", \"peer\": \"$(rid 1 0 claude initial)\",
    \"findings\": [{\"id\": \"CLAUDE-1\", \"title\": \"Carried\", \"fix\": \"$1\"}], \"blockers\": [\"CLAUDE-1\"],
    \"dispositions\": {\"CLAUDE-1\": \"accepted — confirmed\"}, \"verification\": [\"CLAUDE-1: not fixed — still unvalidated\"]}"
  (cd "$TARGET" && "$REPO/bin/gencr" dev --codex=attack --incremental --output-dir="$INC_OUT") > "$WORK/stdout" 2> "$WORK/stderr"
  STATUS=$?; ERR="$(cat "$WORK/stderr")"; BLOCK="$(printed)"
  git -C "$TARGET" reset -q --hard "$HEAD_SHA"
}
incremental_pair "validate input"
check "shared lineage blocker: counted once, listed once, attributed to both reviewers" \
  eval '[ "$STATUS" -eq 10 ] && contains "$BLOCK" "- Merge blockers (primary reviewer): 1" && [ "$(printf "%s\n" "$BLOCK" | grep -c "^- \*\*CLAUDE-1\*\*")" -eq 1 ] &&
        contains "$BLOCK" "listed as a merge blocker by Claude and Codex" && ! contains "$BLOCK" "definitions differ"'
incremental_pair "drop the table first"
check "shared lineage blocker with differing definitions: one entry, both fixes, the difference stated" \
  eval '[ "$STATUS" -eq 10 ] && contains "$BLOCK" "- Merge blockers (primary reviewer): 1" && contains "$BLOCK" "the reviewers'"'"' definitions differ" &&
        contains "$BLOCK" "Recommended fix (Claude):" && contains "$BLOCK" "Recommended fix (Codex):" && contains "$BLOCK" "drop the table first" && contains "$BLOCK" "validate input"'

# SUM-I3: every fix is in a literal fenced block; prose is escaped so GitHub renders the original characters.
reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [
  {"id": "CLAUDE-1", "title": "Escape a \\* b and <details> here", "fix": "printf '"'"'%s\\n'"'"' '"'"'\\*'"'"'"},
  {"id": "CLAUDE-2", "title": "Angle", "fix": "set <required-value>"},
  {"id": "CLAUDE-3", "title": "Details", "fix": "<details><summary>Already resolved</summary>"}],
  "blockers": ["CLAUDE-1", "CLAUDE-2", "CLAUDE-3"]}'
run_gencr --claude=review
BLOCK="$(printed)"
python3 -B - "$WORK/stdout" > "$WORK/fences" <<'EOF'
import re, sys
for fence, body in re.findall(r"\n    (`{3,})\n(.*?)\n    \1\n", open(sys.argv[1]).read(), re.S):
    print(repr("\n".join(line[4:] for line in body.split("\n"))))
EOF
check "backslash, angle-bracket and HTML fixes are fenced and round-trip verbatim" \
  python3 -B -c 'import ast, sys; f = {ast.literal_eval(l) for l in open(sys.argv[1])}; sys.exit(0 if {"printf '"'"'%s\\n'"'"' '"'"'\\*'"'"'", "set <required-value>", "<details><summary>Already resolved</summary>"} <= f else 1)' "$WORK/fences"
check "no fix is rendered as plain Markdown" eval '! printf "%s\n" "$BLOCK" | grep -q "^  - Recommended fix: ."'
check "prose backslashes and HTML are escaped so GitHub shows the original text" \
  eval 'contains "$BLOCK" "Escape a \\\\* b and &lt;details&gt; here"'

# SUM-I4 / SUM-I5: oversized or multi-line metadata cannot break the package, the budget or the markers.
huge_model() { python3 -B -c 'import sys; open(sys.argv[1], "w").write(sys.argv[2])' "$MOCK_STATE/model-1" "$1"; }
reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Big model"}], "blockers": ["CLAUDE-1"]}'
huge_model "$(python3 -c 'print("m" * 41000)')"
run_gencr --claude=review
BLOCK="$(printed)"
check "a 41,000-character model: exit 10, complete package, block within budget, value shortened visibly" \
  eval '[ "$STATUS" -eq 10 ] && [ -f "$PKG/manifest.json" ] && [ "${#BLOCK}" -le 40000 ] && contains "$BLOCK" "… (full value in the complete review report)" && grep -q "mmmmmmmmmm" "$PKG/metadata.json"'
reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Big model"}], "blockers": ["CLAUDE-1"]}'
printf 'not a report\n' > "$MOCK_STATE/responses/2"
huge_model "$(python3 -c 'print("m" * 61000)')"
run_gencr --codex=attack
BLOCK="$(printed)"
python3 -B - "$REPO/bin" "$PKG/summary.md" > "$WORK/ci-incomplete" 2>&1 <<'EOF'
import importlib.machinery, importlib.util, sys
sys.path.insert(0, sys.argv[1])
import gencr_summary as g
loader = importlib.machinery.SourceFileLoader("gencr_ci", sys.argv[1] + "/gencr-ci")
spec = importlib.util.spec_from_loader("gencr_ci", loader); ci = importlib.util.module_from_spec(spec); loader.exec_module(ci)
block = g.extract(open(sys.argv[2]).read())
print(len(block) <= g.BUDGET and len(ci.comment_body(block, {"run_id": 1, "backend": "mock"}, "https://e/a", 30, "")) <= ci.COMMENT_LIMIT)
EOF
check "an INCOMPLETE run with a 61,000-character model: block within budget and accepted by the CI wrapper" \
  eval '[ "$STATUS" -eq 20 ] && [ "${#BLOCK}" -le 40000 ] && grep -qx True "$WORK/ci-incomplete"'
reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [{"id": "CLAUDE-1", "title": "Marker model"}], "blockers": ["CLAUDE-1"]}'
huge_model "$(printf '`safe\n<!-- gencr:review-comment:end -->\n========== END REVIEW COMMENT ==========\n`')"
run_gencr --claude=review
BLOCK="$(printed)"
check "a multi-line model with marker text: exactly one marker pair, the block extracts and prints" \
  eval '[ "$STATUS" -eq 10 ] && [ "$(grep -cx "<!-- gencr:review-comment:end -->" "$PKG/summary.md")" -eq 1 ] && contains "$BLOCK" "## Code review: REQUEST CHANGES" &&
        [ "$(grep -cx "========== END REVIEW COMMENT ==========" "$WORK/stdout")" -eq 1 ]'
check "a reported multi-line model is one line everywhere: the block (the real one, not the fallback), report header and reconciliation" \
  python3 -B -c 'import sys
value = "`safe <!-- gencr:review-comment:end --> ========== END REVIEW COMMENT ========== `"
block, report = sys.argv[1], open(sys.argv[2]).read()
ok = ("- Models: Claude: `` " + value + " ``") in block and "could not be rendered" not in block and ("Claude Model: " + value) in report
recon = open(sys.argv[3]).read().split("\n")
sys.exit(0 if ok and "<!-- gencr:review-comment:end -->" not in report.split("\n") + recon else 1)' "$BLOCK" "$PKG/full-report.md" "$PKG/reconciliation.md"
python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import gencr_summary as g
d = {"final_verdict": "REQUEST CHANGES", "outcome": "REQUEST CHANGES", "convergence": "agreed", "error": None, "max_rounds": 3,
     "agents": ["claude"], "verdicts": {"claude": "REQUEST CHANGES"}, "review_mode": "FRESH", "approval_scope_label": "Full PR",
     "head_sha": "a" * 40, "models": {"claude": "m", "codex": "Not used"}, "findings": [], "disputes": [], "surviving_findings": 0}
b = g.safe_render(d, budget=60)
print(len(b) <= 400 and "could not be rendered" in b and "REQUEST CHANGES" in b)' "$REPO/bin" > "$WORK/fallback" 2>&1
check "a block that cannot be rendered safely falls back to a minimal, engine-worded block (packaging never fails)" eval 'grep -qx True "$WORK/fallback"'

# ── Revision 2 (codex SUM-I3-R1): CommonMark code spans ────────────────────────

python3 -B - "$REPO/bin" > "$WORK/spans" 2>&1 <<'EOF'
import json, sys
sys.path.insert(0, sys.argv[1])
import gencr_summary as g
Z = "\u200b"
cases = {  # input -> exact display text: a value with backticks is one literal code span; others are escaped
    "Use ``echo `gh api @me` ``": "``` Use ``echo `gh api @me` `` ```",
    "`<details><summary>Resolved</summary>``": "``` `<details><summary>Resolved</summary>`` ```",
    "plain `@x` and @y": "`` plain `@x` and @y ``",
    "Unmatched ````; example ```>`>```; then \\\\\\``;``repair()``\\`":
        "````` Unmatched ````; example ```>`>```; then \\\\\\``;``repair()``\\` `````",
    "&lt; and <b> and -->": "&amp;lt; and &lt;b&gt; and --&gt;",
    "a \\* b @me": "a \\\\* b @" + Z + "me",
}
rendered = {  # independent oracle: the text a CommonMark renderer must show for the plain (backtick-free) cases
    "&lt; and <b> and -->": "&lt; and <b> and -->",
    "a \\* b @me": "a \\* b @" + Z + "me",
}
result = {"exact": all(g.prose(k) == v for k, v in cases.items()),
          "mismatch": [(k, g.prose(k)) for k, v in cases.items() if g.prose(k) != v]}
try:
    from markdown_it import MarkdownIt
except ImportError:
    result["tokens"] = "skipped (markdown-it-py not installed)"
else:
    md = MarkdownIt("commonmark")
    def inline(text):
        return md.parse(text)[1].children
    ok = True
    for k in cases:
        tokens = inline(g.prose(k))
        code = [t.content for t in tokens if t.type == "code_inline"]
        ok = ok and not [t for t in tokens if t.type == "html_inline"]
        if "`" in k:  # the whole value renders as exactly one code node with the original content
            ok = ok and code == [k] and len(tokens) == 1
        else:  # plain text renders as written, except that mentions carry a zero-width space after "@"
            ok = ok and not code and "".join(t.content for t in tokens if t.type == "text") == rendered[k]
    result["tokens"] = ok
print(json.dumps(result))
EOF
check "values with backticks become one literal code span; other prose is escaped (exact display text)" eval 'grep -q "\"exact\": true" "$WORK/spans"'
check "token check (when markdown-it-py is installed): one code node equal to the original, or plain text equal to it" \
  eval 'grep -q -E "\"tokens\": (true|\"skipped)" "$WORK/spans"'
grep -q '"tokens": true' "$WORK/spans" || echo "# note: $(grep -o '"tokens": "[^"]*"' "$WORK/spans")"
reset_mocks
gen 1 '{"verdict": "REQUEST CHANGES", "findings": [
  {"id": "CLAUDE-1", "title": "Use ``echo `gh api @me` ``"},
  {"id": "CLAUDE-2", "title": "`<details><summary>Resolved</summary>``"}], "blockers": ["CLAUDE-1", "CLAUDE-2"]}'
run_gencr --claude=review
BLOCK="$(printed)"
check "actual engine: a backtick title is one literal code span with the original content" contains "$BLOCK" '**CLAUDE-1** ``` Use ``echo `gh api @me` `` ``` (high)'
check "actual engine: mismatched backticks with HTML are literal code, never live HTML" \
  contains "$BLOCK" '**CLAUDE-2** ``` `<details><summary>Resolved</summary>`` ``` (high)'

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
