#!/usr/bin/env bash
# Automatic review-mode tests for bin/gencr: `gencr <dev>` is INCREMENTAL from the latest compatible completed review of
# this branch and FRESH when there is none; --incremental never falls back to FRESH; a previous review that already
# covers HEAD launches nothing; ambiguous history and an UNRESOLVED DISAGREEMENT stop for the user's decision; explicit
# --fresh asks on the controlling terminal (15 s, default yes; tested through a pseudo-terminal). Mock reviewer CLIs;
# no network. Usage: bash tests/test_gencr_auto.sh
# shellcheck disable=SC2016,SC2034  # deferred eval checks

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd -P "$(mktemp -d)" && pwd)/gencr auto tests"
mkdir -p "$WORK"
trap 'chmod -R u+w "$(dirname "$WORK")" 2>/dev/null; rm -rf "$(dirname "$WORK")"' EXIT

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
not_ok() { FAIL=$((FAIL + 1)); echo "not ok - $1"; [ -z "$2" ] || printf '%s\n' "$2" | sed 's/^/    # /'; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else not_ok "$desc" "status=${STATUS:-} $(printf '%s' "${ERR:-}" | tail -n 3)"; fi; }
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
git -C "$TARGET" push -q origin staging:other-base
git -C "$TARGET" fetch -q origin
git -C "$TARGET" checkout -q -b feature
printf 'def sync():\n    return 1\n' > "$TARGET/app.py"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm feature

reset_mocks() { rm -rf "$MOCK_STATE"; mkdir -p "$MOCK_STATE/responses"; }
calls() { cat "$MOCK_STATE/count" 2>/dev/null || echo 0; }
commit() { echo "$1" >> "$TARGET/app.py"; git -C "$TARGET" commit -qam "$1"; }
commit_file() { echo "$1" > "$TARGET/$1.py"; git -C "$TARGET" add -- "$1.py" && git -C "$TARGET" commit -qm "$1"; }
head_sha() { git -C "$TARGET" rev-parse HEAD; }
reports() { echo "$HOME/Documents/CodeReview/$1"; }
newest() { ls -td "$(reports "$1")"/review-* 2>/dev/null | head -n 1; }
count_pkgs() { local n=0 d; for d in "$(reports "$1")"/review-*; do [ -d "$d" ] && n=$((n + 1)); done; echo "$n"; }
run_id() { json_get "$1/metadata.json" 'd["run_id"]'; }
# run_gencr DEV ARGS... — gencr without a controlling terminal (a new session), as in CI or a script.
run_gencr() {
  reset_mocks
  (cd "$TARGET" && python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$REPO/bin/gencr" "$@") \
    > "$WORK/stdout" 2> "$WORK/stderr" < /dev/null
  STATUS=$?; OUT="$(cat "$WORK/stdout")"; ERR="$(cat "$WORK/stderr")"
}
review() { MOCK_VERDICT="$1" run_gencr "${@:2}"; }   # review VERDICT DEV ARGS...
# retouch PKG PYTHON — edits metadata (m), findings (f) or manifest (x) of a package and re-hashes its manifest.
retouch() {
  python3 - "$1" "$2" <<'EOF'
import hashlib, json, os, sys
d, code = sys.argv[1], sys.argv[2]
load = lambda n: json.load(open(os.path.join(d, n)))
m, f, x = load("metadata.json"), load("findings.json"), load("manifest.json")
exec(code)
for name, value in (("metadata.json", m), ("findings.json", f)):
    data = json.dumps(value, indent=2) + "\n"
    open(os.path.join(d, name), "w").write(data)
    x["files"][name] = hashlib.sha256(data.encode()).hexdigest()
open(os.path.join(d, "manifest.json"), "w").write(json.dumps(x, indent=2) + "\n")
EOF
}
# pty_run DEV SPEC ARGS... — gencr on a pseudo-terminal (its controlling terminal). SPEC: "y", "n", "", "x+wait",
# "wait" (no answer) or "none" (no prompt expected). Prints JSON: status, output, prompted, waited (seconds from the
# prompt to "continuing with FRESH", i.e. the timeout).
pty_run() {
  local dev="$1" spec="$2"
  shift 2
  reset_mocks
  (cd "$TARGET" && python3 - "$spec" "$REPO/bin/gencr" "$dev" "$@" <<'EOF'
import json, os, pty, select, sys, time
spec, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
out, prompted, answered, t_prompt, t_after = b"", False, False, None, None
deadline = time.time() + 60
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
        if prompted and t_after is None and b"continuing with FRESH" in out:
            t_after = time.time()
    if not prompted and b"Continue with FRESH? [Y/n] (15 seconds; default Y)" in out:
        prompted, t_prompt = True, time.time()
    if prompted and not answered:
        if spec in ("y", "n", "Y", ""):
            os.write(fd, spec.encode() + b"\r"); answered = True
        elif spec == "x+wait" and time.time() - t_prompt > 3:
            os.write(fd, b"x\r"); answered = True
_, status = os.waitpid(pid, 0)
print(json.dumps({"status": os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else status >> 8,
                  "output": out.decode("utf-8", "replace"), "prompted": prompted,
                  "waited": None if t_prompt is None or t_after is None else round(t_after - t_prompt, 1)}))
EOF
  ) > "$WORK/pty.json"
  PTY="$WORK/pty.json"
}
pty_get() { json_get "$PTY" "$1"; }

# ── 1. First review, previous APPROVED / REQUEST CHANGES, new commits, previous at HEAD ──

review APPROVED dev1
P1="$(newest dev1)"
check "first review of a branch: automatically FRESH, and says why" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "gencr: review mode: FRESH — no compatible previous review" && [ "$(json_get "$P1/metadata.json" "d[\"review_mode\"]")" = FRESH ]'
check "the terminal verdict line carries ✅ for APPROVED; the package keeps the token" \
  eval 'contains "$ERR" "gencr: final verdict: ✅ APPROVED; report:" && [ "$(json_get "$P1/metadata.json" "d[\"outcome\"]")" = APPROVED ]'
review APPROVED dev1
check "previous APPROVED at HEAD: no reviewer, exit 0, no new package, and it is not presented as a new approval" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 0 ] && [ "$(count_pkgs dev1)" -eq 1 ] &&
        contains "$ERR" "gencr: no new review needed: review $(run_id "$P1") (verdict APPROVED) already covers HEAD $(head_sha | cut -c1-12); no reviewer was launched" &&
        ! contains "$ERR" "final verdict"'
commit c1
review APPROVED dev1
P2="$(newest dev1)"
check "previous APPROVED + new commits: automatically INCREMENTAL from it" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "gencr: review mode: INCREMENTAL — previous review $(run_id "$P1") (reviewed $(git -C "$TARGET" rev-parse HEAD~1 | cut -c1-12), APPROVED), selected automatically" &&
        [ "$(json_get "$P2/metadata.json" "d[\"review_mode\"], d[\"previous_review\"][\"id\"] == \"$(run_id "$P1")\", d[\"previous_review\"][\"outcome\"]")" = "INCREMENTAL True APPROVED" ]'
check "the incremental prompt states the previous review and its verdict" \
  grep -qF "Review mode: INCREMENTAL (follow-up to review $(run_id "$P1"), which reviewed $(git -C "$TARGET" rev-parse HEAD~1); its verdict: APPROVED):" "$MOCK_STATE/call-1.stdin"

review "REQUEST CHANGES" dev2 --version=2
R1="$(newest dev2)"
check "the terminal verdict line carries ❌ for REQUEST CHANGES; exit 10 unchanged" eval '[ "$STATUS" -eq 10 ] && contains "$ERR" "gencr: final verdict: ❌ REQUEST CHANGES; report:"'
review "REQUEST CHANGES" dev2 --version=2
check "previous REQUEST CHANGES at HEAD: exit 0 (no new review needed), never 10 or a new verdict" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "(verdict REQUEST CHANGES) already covers HEAD"'
commit c2
review APPROVED dev2 --version=2
check "previous REQUEST CHANGES + new commits: INCREMENTAL, carrying its open findings" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "INCREMENTAL — previous review $(run_id "$R1")" && grep -qF "verify each one): CLAUDE-1" "$MOCK_STATE/call-1.stdin"'

# ── 2. Packages that are not baselines ──

baseline_rejected() { # DESCRIPTION EXPECTED-REASON DEV ARGS...
  local desc="$1" reason="$2"
  shift 2
  review APPROVED "$@"
  if [ "$STATUS" -eq 0 ] && contains "$ERR" "gencr: review mode: FRESH — no compatible previous review" && contains "$ERR" "$reason" &&
     ! contains "$ERR" "Traceback"; then ok "$desc"; else not_ok "$desc" "status=$STATUS $(printf '%s' "$ERR" | tail -n 3)"; fi
}
# copy_pkg FROM-DEV TO-DEV — a copy of FROM's newest package in TO's report directory (TO has nothing else).
copy_pkg() { rm -rf "$(reports "$2")"; mkdir -p "$(reports "$2")"; cp -R "$(newest "$1")" "$(reports "$2")/"; echo "$(newest "$2")"; }

review APPROVED dev3
cp -R "$(newest dev3)" "$WORK/dev3.pkg"
retouch "$(newest dev3)" 'm["outcome"] = "INCOMPLETE"'
commit c3
baseline_rejected "a previous INCOMPLETE review is not a baseline (FRESH)" "is not a completed review" dev3
commit c3b
mkdir -p "$(reports dev4)"; cp -R "$WORK/dev3.pkg" "$(reports dev4)/review-copied"
retouch "$(reports dev4)/review-copied" 'm["developer"] = "dev4"'
printf 'tampered' >> "$(reports dev4)/review-copied/metadata.json"
baseline_rejected "corrupted metadata (hash mismatch) is not a baseline" "is missing or modified" dev4
rm -rf "$(reports dev4)"; mkdir -p "$(reports dev4)"; cp -R "$WORK/dev3.pkg" "$(reports dev4)/review-shape"
retouch "$(reports dev4)/review-shape" 'm["developer"] = "dev4"; f = ["not", "an", "object"]'
baseline_rejected "valid JSON of the wrong shape is a rejected candidate with a reason, not a crash" "is not a JSON object" dev4
rm -rf "$(reports dev4)"; mkdir -p "$(reports dev4)"; cp -R "$WORK/dev3.pkg" "$(reports dev4)/review-nometa"
retouch "$(reports dev4)/review-nometa" 'm["developer"] = "dev4"'
rm -f "$(reports dev4)/review-nometa/metadata.json"
baseline_rejected "missing metadata is not a baseline" "missing or modified" dev4
for case in 'repository:m["identity"]["repository"] = "git:elsewhere":different repository' \
            'developer:m["developer"] = "someone-else":different developer' \
            'base:m["identity"]["base_branch"] = "other-base":different base branch' \
            'schema:m["schema"] = 99:unsupported metadata schema'; do
  name="${case%%:*}" rest="${case#*:}" code="${rest%:*}" reason="${rest##*:}"
  rm -rf "$(reports dev4)"; mkdir -p "$(reports dev4)"; cp -R "$WORK/dev3.pkg" "$(reports dev4)/review-$name"
  retouch "$(reports dev4)/review-$name" 'm["developer"] = "dev4"; '"$code"
  baseline_rejected "a previous review of another $name is not a baseline" "$reason" dev4
done
rm -rf "$(reports dev4)"; mkdir -p "$(reports dev4)"; cp -R "$WORK/dev3.pkg" "$(reports dev4)/review-v"
retouch "$(reports dev4)/review-v" 'm["developer"] = "dev4"'
baseline_rejected "a previous review with other instructions is not a baseline" "different review instructions" dev4 --version=2
# Another developer sharing an output directory.
SHARED="$WORK/shared reports"
review APPROVED alice --output-dir="$SHARED"
commit c4
review APPROVED bob --output-dir="$SHARED"
check "a review by another developer in a shared output directory is never reused" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "FRESH — no compatible previous review" && contains "$ERR" "different developer"'
# Another branch.
review APPROVED dev5
git -C "$TARGET" checkout -q -b feature-two
commit c5
baseline_rejected "a review of another branch is not a baseline" "different branch" dev5
git -C "$TARGET" checkout -q feature
# A rewritten history (previous reviewed SHA not an ancestor of HEAD).
git -C "$TARGET" tag pre-rewrite
review APPROVED dev6
git -C "$TARGET" reset -q --hard HEAD~1
commit rewritten
baseline_rejected "a review whose commit is not in HEAD's history is not a baseline" "is not an ancestor of HEAD" dev6
git -C "$TARGET" reset -q --hard pre-rewrite
# gencrclaude reports (old format) are never packages.
mkdir -p "$(reports dev7)"
printf '# Code review\n\nVERDICT: APPROVED\n' > "$(reports dev7)/code-review-dev7-feature-20261025-120000.md"
mkdir -p "$(reports dev7)/review-oldformat"; cp "$(reports dev7)/code-review-dev7-feature-20261025-120000.md" "$(reports dev7)/review-oldformat/report.md"
baseline_rejected "a directory holding only gencrclaude reports gives FRESH" "manifest.json missing" dev7
review APPROVED dev7 --incremental --previous="$(reports dev7)/code-review-dev7-feature-20261025-120000.md"
check "a gencrclaude report given as --previous is refused (never reinterpreted)" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "cannot use" && contains "$ERR" "Run with --fresh instead"'
review APPROVED dev8 --incremental
check "--incremental without a compatible previous review fails clearly and never falls back to FRESH" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "cannot establish a reliable incremental baseline" && contains "$ERR" "Run with --fresh instead"'

# ── 3. Several previous reviews: commit history decides; ambiguity stops ──

review APPROVED dev9
OLD="$(newest dev9)"
commit c6
review "REQUEST CHANGES" dev9
NEW="$(newest dev9)"
retouch "$OLD" 'm["completed_at"] = "2099-01-01T00:00:00Z"'   # newer timestamp, older commit
commit c7
review APPROVED dev9
check "several reviews: the one furthest along HEAD's history is the baseline, not the newest timestamp" \
  eval 'contains "$ERR" "INCREMENTAL — previous review $(run_id "$NEW")"'
# Two reviews of the same commit.
review APPROVED dev10
A="$(newest dev10)"
cp -R "$A" "$(reports dev10)/review-twin"
retouch "$(reports dev10)/review-twin" 'm["run_id"] = "twin"; m["completed_at"] = m["completed_at"]'
retouch "$A" 'm["completed_at"] = "2030-01-01T00:00:00Z"'
retouch "$(reports dev10)/review-twin" 'm["completed_at"] = "2030-01-01T00:00:00Z"'
commit c8
review APPROVED dev10
check "two reviews of one commit with the same completion time: stop, list both, launch nothing" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "none is unambiguously the latest" && contains "$ERR" "$(run_id "$A")" && contains "$ERR" "twin" &&
        contains "$ERR" "--incremental --previous=<package>" && contains "$ERR" "--fresh"'
retouch "$(reports dev10)/review-twin" 'm["completed_at"] = "2031-01-01T00:00:00Z"'
# An older tie (two reviews completed in the same second) does not hide a unique latest review.
cp -R "$A" "$(reports dev10)/review-twin2"
retouch "$(reports dev10)/review-twin2" 'm["run_id"] = "twin2"'
review APPROVED dev10
check "two reviews of one commit: the later validated completion time decides" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "INCREMENTAL — previous review twin"'
# Two reviews of one commit, one without a valid completion time: they cannot be ordered.
review APPROVED dev10m
M1="$(newest dev10m)"
cp -R "$M1" "$(reports dev10m)/review-untimed"
retouch "$(reports dev10m)/review-untimed" 'm["run_id"] = "untimed"; m["completed_at"] = "yesterday"'
retouch "$M1" 'm["completed_at"] = "2030-01-01T00:00:00Z"'
commit c8m
review APPROVED dev10m
check "two reviews of one commit, one with an invalid completion time: stop, launch nothing" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "none is unambiguously the latest" && contains "$ERR" "untimed"'
# A merge DAG: two reviewed commits on the branch, neither an ancestor of the other, both in HEAD's history.
git -C "$TARGET" tag pre-dag
commit_file left
LEFT="$(head_sha)"
review APPROVED dag
git -C "$TARGET" reset -q --hard pre-dag
commit_file right
review APPROVED dag
git -C "$TARGET" merge -q --no-ff -m "merge left" "$LEFT"
review APPROVED dag
check "two incomparable reviewed commits (merge history): stop, list both, launch nothing" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "none is unambiguously the latest" && [ "$(printf "%s" "$ERR" | grep -o "reviewed [0-9a-f]\{12\}" | sort -u | grep -c .)" -eq 2 ]'
review APPROVED dag --fresh
check "explicit --fresh with ambiguous previous reviews still knows they exist (no terminal: no question, FRESH)" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "FRESH — requested with --fresh (previous review"'
git -C "$TARGET" reset -q --hard pre-dag

# ── 4. UNRESOLVED DISAGREEMENT: never automatic; explicit --incremental continues it ──
# (New runs never produce UNRESOLVED DISAGREEMENT: these packages are made legacy — no adjudication object — first.)

review "REQUEST CHANGES" dev11 --codex=attack
U="$(newest dev11)"
retouch "$U" 'm.pop("adjudication", None); f.pop("adjudication", None); m["outcome"] = "UNRESOLVED DISAGREEMENT"; m["final_verdict"] = "UNRESOLVED DISAGREEMENT"; m["rounds"] = 3'
review APPROVED dev11 --codex=attack
check "latest review UNRESOLVED (same HEAD): automatic mode stops for a decision, launches nothing" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "ended UNRESOLVED DISAGREEMENT; gencr does not continue it automatically" &&
        contains "$ERR" "--incremental" && contains "$ERR" "--fresh"'
review APPROVED dev11 --codex=attack --incremental
C="$(newest dev11)"
check "explicit --incremental continues it at the same HEAD, with its own limit of 3 rounds, stated and recorded" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -ge 2 ] && [ "$C" != "$U" ] &&
        contains "$ERR" "INCREMENTAL — continuing UNRESOLVED DISAGREEMENT review $(run_id "$U") (it used 3 of 3 rounds; this run has its own limit of 3)" &&
        [ "$(json_get "$C/metadata.json" "d[\"previous_review\"][\"outcome\"], d[\"previous_review\"][\"rounds_used\"], d[\"max_rounds\"]")" = "UNRESOLVED DISAGREEMENT 3 3" ]'
check "the continuation carries every unresolved finding and states the previous rounds to the reviewers" \
  eval 'grep -qF "verify each one): CLAUDE-1 CODEX-1" "$MOCK_STATE/call-1.stdin" && grep -qF "after 3 of 3 reconciliation rounds; this run has its own limit of 3" "$MOCK_STATE/call-1.stdin" &&
        grep -qF -- "- Current reconciliation round: 0" "$MOCK_STATE/call-1.stdin"'
# An older APPROVED and a newer UNRESOLVED: automatic mode stops (never skips to the older one); an explicit choice warns.
review APPROVED dev12
OLDER="$(newest dev12)"
commit c9
review "REQUEST CHANGES" dev12
NEWER="$(newest dev12)"
retouch "$NEWER" 'm.pop("adjudication", None); f.pop("adjudication", None); m["outcome"] = "UNRESOLVED DISAGREEMENT"; m["rounds"] = 3'
commit c10
review APPROVED dev12
check "an older APPROVED behind a newer UNRESOLVED: automatic mode stops, never falls back to the older review" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "$(run_id "$NEWER")" && contains "$ERR" "UNRESOLVED DISAGREEMENT"'
review APPROVED dev12 --incremental --previous="$OLDER"
check "--previous=<older> across a newer UNRESOLVED: runs from the chosen one, warns and records the newer review" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "previous review $(run_id "$OLDER")" && contains "$ERR" "warning: the newer UNRESOLVED DISAGREEMENT review $(run_id "$NEWER")" &&
        [ "$(json_get "$(newest dev12)/metadata.json" "d[\"previous_review\"][\"newer_unresolved\"]")" = "$(run_id "$NEWER")" ]'
# A pinned older review that already covers HEAD: the no-op still discloses the newer UNRESOLVED review.
review APPROVED devpin
PIN="$(newest devpin)"
cp -R "$PIN" "$(reports devpin)/review-unres2"
retouch "$PIN" 'm["completed_at"] = "2030-01-01T00:00:00Z"'
retouch "$(reports devpin)/review-unres2" 'm.pop("adjudication", None); f.pop("adjudication", None); m["run_id"] = "unres2"; m["outcome"] = "UNRESOLVED DISAGREEMENT"; m["rounds"] = 3; m["completed_at"] = "2031-01-01T00:00:00Z"'
for extra in "" --print; do
  review APPROVED devpin --incremental --previous="$PIN" $extra
  check "--previous=<older> that covers HEAD${extra:+ ($extra)}: no-op, and it still warns about the newer UNRESOLVED review" \
    eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "no new review needed" && contains "$ERR" "warning: the newer UNRESOLVED DISAGREEMENT review unres2"'
done

# ── 4b. Metadata that cannot be trusted stops the selection (never coerced, never dropped) ──

untrusted() { # DEV DESCRIPTION PYTHON-EDIT — the only review covers HEAD, but its metadata is invalid
  review APPROVED "$1"
  local pkg; pkg="$(newest "$1")"
  retouch "$pkg" "$3"
  review APPROVED "$1"
  check "untrusted metadata ($2): automatic selection stops, launches nothing, names the package" \
    eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "cannot be trusted as a baseline" && contains "$ERR" "$(basename "$pkg")" &&
          ! contains "$ERR" "review None" && ! contains "$ERR" "no new review needed"'
  review APPROVED "$1" --incremental
  check "untrusted metadata ($2): explicit --incremental stops too" \
    eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "cannot be trusted as a baseline"'
  review APPROVED "$1" --incremental --previous="$pkg"
  check "untrusted metadata ($2): it cannot be pinned with --previous" \
    eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "cannot use" && contains "$ERR" "Run with --fresh instead"'
}
untrusted devu1 "run ID null" 'm["run_id"] = None'
untrusted devu2 "rounds not a number" 'm["rounds"] = "broken"'
untrusted devu3 "negative rounds" 'm["rounds"] = -1'
untrusted devu4 "previous_review fields of the wrong type" \
  'm["previous_review"] = {"id": "p", "reviewed_sha": "a" * 40, "path": None, "rounds_used": [], "outcome": 42, "newer_unresolved": ["invalid"]}'
untrusted devu5 "previous_review not an object" 'm["previous_review"] = "p"'
n=6
for sha in 123 True '["a"]' '{"sha": "a"}'; do
  untrusted "devu$n" "previous_review reviewed_sha $sha" "m[\"previous_review\"] = {\"id\": \"earlier-review\", \"reviewed_sha\": $sha, \"path\": None}"
  review APPROVED "devu$n"
  check "untrusted metadata (previous_review reviewed_sha $sha): the specific reason is given" \
    eval 'contains "$ERR" "its previous_review identity is invalid"'
  n=$((n + 1))
done
# A malformed newer UNRESOLVED review keeps its place in the history: it is never skipped for an older APPROVED one,
# and on its own it never turns into an automatic FRESH restart.
review APPROVED devbar
BOLD="$(newest devbar)"
cp -R "$BOLD" "$(reports devbar)/review-newer-unresolved"
retouch "$BOLD" 'm["completed_at"] = "2026-10-25T12:00:00Z"'
retouch "$(reports devbar)/review-newer-unresolved" 'm.pop("adjudication", None); f.pop("adjudication", None); m["run_id"] = "newer-unresolved"; m["outcome"] = "UNRESOLVED DISAGREEMENT"; m["completed_at"] = "2026-10-25T13:00:00Z"
m["previous_review"] = {"id": "earlier-review", "reviewed_sha": 123, "path": None}'
review APPROVED devbar
check "an older APPROVED behind a malformed newer UNRESOLVED (same commit): automatic mode stops, never covered by the older" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "cannot be trusted as a baseline" && contains "$ERR" "review-newer-unresolved" && ! contains "$ERR" "no new review needed"'
review APPROVED devbar --incremental
check "... explicit --incremental without --previous stops too (never silently the older package)" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "cannot be trusted as a baseline"'
review APPROVED devbar --incremental --previous="$BOLD"
check "... pinning the older APPROVED is a no-op that still warns about the newer UNRESOLVED review" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "warning: the newer UNRESOLVED DISAGREEMENT review review-newer-unresolved"'
review APPROVED devbar --incremental --previous="$(reports devbar)/review-newer-unresolved"
check "... and the malformed UNRESOLVED package itself cannot be pinned" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "cannot use"'
rm -r "${BOLD:?}"
review APPROVED devbar
check "a malformed UNRESOLVED package alone: automatic mode stops; it never restarts FRESH" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "cannot be trusted as a baseline" && ! contains "$ERR" "review mode: FRESH"'
# A completion time that matches the format but is no date cannot order reviews of one commit (no covered no-op).
review "REQUEST CHANGES" devdate
DPKG="$(newest devdate)"
cp -R "$DPKG" "$(reports devdate)/review-unres3"
retouch "$(reports devdate)/review-unres3" 'm.pop("adjudication", None); f.pop("adjudication", None); m["run_id"] = "unres3"; m["outcome"] = "UNRESOLVED DISAGREEMENT"; m["completed_at"] = "2026-10-25T12:00:00Z"'
retouch "$DPKG" 'm["outcome"] = "APPROVED"; m["completed_at"] = "2026-99-99T99:99:99Z"'
review APPROVED devdate
check "an impossible completion date never outranks an UNRESOLVED review of the same commit: stop, launch nothing" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "none is unambiguously the latest" && contains "$ERR" "unres3" && ! contains "$ERR" "no new review needed"'
review APPROVED devdate --incremental
check "an impossible completion date with explicit --incremental: stop as well" \
  eval '[ "$STATUS" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "none is unambiguously the latest"'
# Control: a valid older package without the additive fields (rounds, previous_review outcome/rounds_used) is a baseline.
review APPROVED devold
commit c10b
review APPROVED devold
OLDPKG="$(newest devold)"
retouch "$OLDPKG" 'del m["rounds"]; [m["previous_review"].pop(k, None) for k in ("outcome", "rounds_used", "newer_unresolved")]'
review APPROVED devold
check "a valid package written before the additive fields still covers HEAD (no-op, not refused)" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 0 ] && contains "$ERR" "no new review needed: review $(run_id "$OLDPKG")"'
commit c10c
review APPROVED devold
check "... and is the automatic INCREMENTAL baseline after a new commit" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "INCREMENTAL — previous review $(run_id "$OLDPKG")"'

# ── 5. Explicit --fresh: full PR scope, previous ignored, confirmation only on a terminal ──

review "REQUEST CHANGES" dev13
F0="$(newest dev13)"
commit c11
review APPROVED dev13 --fresh
F1="$(newest dev13)"
check "--fresh without a terminal: never waits, says the previous review is not the baseline, reviews the full PR" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 1 ] && contains "$ERR" "FRESH — requested with --fresh (previous review $(run_id "$F0")" &&
        [ "$(json_get "$F1/metadata.json" "d[\"review_mode\"], d[\"previous_review\"]")" = "FRESH None" ] && contains "$ERR" "review scope: FRESH, method merge-base" &&
        ! grep -qF "verify each one" "$MOCK_STATE/call-1.stdin" && [ -d "$F0" ]'

for answer in y Y ""; do
  pty_run dev13 "$answer" --fresh
  check "terminal prompt, answer '${answer:-Enter}': the exact question, then FRESH" \
    eval '[ "$(pty_get "d[\"prompted\"]")" = True ] && [ "$(pty_get "d[\"status\"]")" -eq 0 ] && [ "$(calls)" -eq 1 ] &&
          contains "$(pty_get "d[\"output\"]")" "Previous code review detected for this branch." &&
          contains "$(pty_get "d[\"output\"]")" "A FRESH review will start over and ignore the previous review as its baseline."'
done
before="$(count_pkgs dev13)"
pty_run dev13 n --fresh
check "terminal prompt, answer n: cancelled, exit 1, no reviewer, nothing written or deleted" \
  eval '[ "$(pty_get "d[\"status\"]")" -eq 1 ] && [ "$(calls)" -eq 0 ] && contains "$(pty_get "d[\"output\"]")" "FRESH review cancelled; no reviewer was launched" && [ "$(count_pkgs dev13)" -eq "$before" ]'
pty_run dev13 wait --fresh
check "terminal prompt, no answer: continues FRESH after 15 seconds" \
  eval '[ "$(pty_get "d[\"status\"]")" -eq 0 ] && [ "$(calls)" -eq 1 ] && contains "$(pty_get "d[\"output\"]")" "no answer within 15 seconds; continuing with FRESH" &&
        python3 -c "import sys; w = float(sys.argv[1]); sys.exit(0 if 14 <= w <= 20 else 1)" "$(pty_get "d[\"waited\"]")"'
pty_run dev13 x+wait --fresh
check "terminal prompt, invalid answer: asks again within the same 15 seconds (timer not restarted)" \
  eval '[ "$(pty_get "d[\"status\"]")" -eq 0 ] && contains "$(pty_get "d[\"output\"]")" "Please answer y or n:" && contains "$(pty_get "d[\"output\"]")" "continuing with FRESH" &&
        python3 -c "import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if d[\"waited\"] is not None and 14 <= d[\"waited\"] <= 16.5 else 1)" "$PTY"'
pty_run dev13 none --fresh --print
check "--fresh --print on a terminal: no question, launches and writes nothing" \
  eval '[ "$(pty_get "d[\"prompted\"]")" = False ] && [ "$(pty_get "d[\"status\"]")" -eq 0 ] && [ "$(calls)" -eq 0 ]'
pty_run dev13 none
check "automatic selection on a terminal never asks" eval '[ "$(pty_get "d[\"prompted\"]")" = False ] && [ "$(pty_get "d[\"status\"]")" -eq 0 ]'
pty_run devnew none --fresh
check "--fresh on a terminal without a previous review: no question" \
  eval '[ "$(pty_get "d[\"prompted\"]")" = False ] && [ "$(pty_get "d[\"status\"]")" -eq 0 ] && [ "$(calls)" -eq 1 ] && contains "$(pty_get "d[\"output\"]")" "FRESH — requested with --fresh"'

# ── 6. Adversarial reviews use the same selection, in both orders ──

for order in "--codex=attack" "--codex=review --claude=attack"; do
  dev="adv$( [ "$order" = --codex=attack ] && echo 1 || echo 2)"
  # shellcheck disable=SC2086
  review APPROVED "$dev" $order
  first="$(newest "$dev")"
  commit "c-$dev"
  # shellcheck disable=SC2086
  review APPROVED "$dev" $order
  check "adversarial ($order): the second review is automatically INCREMENTAL from the first" \
    eval '[ "$STATUS" -eq 0 ] && [ "$(calls)" -eq 2 ] && contains "$ERR" "INCREMENTAL — previous review $(run_id "$first")"'
done

# ── 7. Explicit --fresh with a historical scope: --fresh keeps its confirmation ──

git -C "$TARGET" checkout -q staging
git -C "$TARGET" merge -q --no-ff -m "merge feature" feature
MERGE="$(git -C "$TARGET" rev-parse HEAD)"
git -C "$TARGET" push -q origin staging
git -C "$TARGET" fetch -q origin
git -C "$TARGET" checkout -q feature
review APPROVED devm --merge-commit="$MERGE"
check "a historical --merge-commit review (fixture): FRESH, no question" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "FRESH — explicit --range/--merge-commit"'
pty_run devm none --merge-commit="$MERGE"
check "--merge-commit alone on a terminal never asks (it is not --fresh)" eval '[ "$(pty_get "d[\"prompted\"]")" = False ] && [ "$(pty_get "d[\"status\"]")" -eq 0 ]'
pty_run devm n --fresh --merge-commit="$MERGE"
check "--fresh --merge-commit with a compatible review of that merge asks; n cancels" \
  eval '[ "$(pty_get "d[\"prompted\"]")" = True ] && [ "$(pty_get "d[\"status\"]")" -eq 1 ] && [ "$(calls)" -eq 0 ]'
pty_run devm y --fresh --merge-commit="$MERGE"
check "--fresh --merge-commit, answer y: FRESH of the merged branch" \
  eval '[ "$(pty_get "d[\"status\"]")" -eq 0 ] && [ "$(calls)" -eq 1 ] && contains "$(pty_get "d[\"output\"]")" "merge-commit"'

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
