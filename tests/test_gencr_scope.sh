#!/usr/bin/env bash
# Review-scope resolution tests for bin/gencr: open branches, merged branches (merge commit, squash,
# rebase, fast-forward), explicit ranges and merge-commit evidence, ambiguous histories, and the
# incremental anchor. Real Git repositories, mock reviewer CLIs; no network or GitHub access.
# Usage: bash tests/test_gencr_scope.sh
# shellcheck disable=SC2016,SC2012,SC2034  # deferred eval checks; known-safe fixture paths

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd -P "$(mktemp -d)" && pwd)/gencr scope tests"
mkdir -p "$WORK"
trap 'rm -rf "$(dirname "$WORK")"' EXIT

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
not_ok() { FAIL=$((FAIL + 1)); echo "not ok - $1"; [ -z "$2" ] || printf '%s\n' "$2" | sed 's/^/    # /'; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else not_ok "$desc" "status=$STATUS err=$ERR"; fi; }
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
unset CODEREVIEW_BASE_BRANCH MOCK_VERDICT
GENCR="$REPO/bin/gencr"
export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"

reset_mocks() { rm -rf "$MOCK_STATE"; mkdir -p "$MOCK_STATE/responses"; }
calls() { cat "$MOCK_STATE/count" 2>/dev/null || echo 0; }
# run_in DIR ARGS... — gencr in a repository, capturing status, stdout and stderr.
run_in() {
  local dir="$1"
  shift
  reset_mocks
  (cd "$dir" && "$GENCR" dev "$@") > "$WORK/out" 2> "$WORK/err"
  STATUS=$?; OUT="$(cat "$WORK/out")"; ERR="$(cat "$WORK/err")"
}
# The "- Files" listing of a printed prompt.
listed() { printf '%s\n' "$OUT" | grep -E '^  - [AMDRTF] ' ; }
lists() { listed | grep -qF -- " $1"; }

# new_repo NAME — a repository with a bare origin; staging holds base.txt. Sets R.
new_repo() {
  R="$WORK/$1"
  git init -q --bare "$WORK/$1.git"
  git init -q "$R"
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name T
  git -C "$R" checkout -q -b staging
  echo base > "$R/base.txt"
  git -C "$R" add . && git -C "$R" commit -qm base
  git -C "$R" remote add origin "$WORK/$1.git"
  git -C "$R" push -q origin staging
}
# commit_file FILE [CONTENT] — commits a file on the current branch of $R.
commit_file() { echo "${2:-$1}" > "$R/$1"; git -C "$R" add -- "$1" && git -C "$R" commit -qm "add $1"; }
sha() { git -C "$R" rev-parse "$1"; }
publish() { git -C "$R" push -q -f origin staging; git -C "$R" fetch -q origin; }

# ── Open branch (merge-base method) ────────────────────────────────────────────

new_repo open
git -C "$R" checkout -q -b feature
commit_file feature.py
git -C "$R" checkout -q staging
commit_file later.txt
publish
git -C "$R" checkout -q feature
run_in "$R" --print
check "open branch: method merge-base, target current branch delta" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "gencr: review scope: FRESH, method merge-base, target current branch delta"'
check "open branch: base commits after the fork are not reviewed" eval 'lists feature.py && ! lists later.txt'
check "open branch: the scope line names base and head" \
  eval 'contains "$ERR" "base $(sha staging~1 | cut -c1-12), head $(sha HEAD | cut -c1-12); 1 files, 1 commits"'
check "open branch: the FRESH contract text is unchanged" \
  eval 'contains "$OUT" "every file changed between the merge-base $(sha staging~1) and HEAD $(sha HEAD)"'
check "open branch: no first-parent warning" eval '! contains "$ERR" "gencr: note:"'

# ── Regular merge commit, base advances afterwards ─────────────────────────────

new_repo merged
git -C "$R" checkout -q -b feature
commit_file one.py
commit_file two.py
FEATURE="$(sha HEAD)"
git -C "$R" checkout -q staging
commit_file before.txt
git -C "$R" merge -q --no-ff -m "merge feature" feature
MERGE="$(sha HEAD)"
commit_file after.txt
publish
git -C "$R" checkout -q feature
run_in "$R" --print
check "merged by merge commit: found, reviews the branch proposal" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "method merge-commit (found), target branch proposal" && contains "$ERR" "merge commit $(echo "$MERGE" | cut -c1-12)"'
check "merged by merge commit: every branch file, no base file before or after the merge" \
  eval 'lists one.py && lists two.py && ! lists before.txt && ! lists after.txt'
check "merged by merge commit: the prompt states the historical scope" \
  eval 'contains "$OUT" "merged into origin/staging by the merge commit ${MERGE}" && contains "$OUT" "between the review base $(sha staging~3) (where the branch started" && contains "$OUT" "and HEAD ${FEATURE}, including"'
run_in "$R" --print --merge-commit="$MERGE"
check "--merge-commit given: same scope, labelled given" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "method merge-commit (given)" && lists one.py && ! lists after.txt'
run_in "$R" --print --merge-commit "$(echo "$MERGE" | cut -c1-12)"
check "--merge-commit space form with an abbreviated SHA" eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "(given)"'
run_in "$R" --print --merge-commit="$(sha staging)"
check "--merge-commit that is not a merge commit is refused" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "is not a merge commit"'

# A real run shows the scope before the reviewer runs and records it in the package.
run_in "$R" --merge-commit="$MERGE"
PKG="$(ls -td "$HOME/Documents/CodeReview/dev"/review-* | head -n 1)"
check "a real run prints the scope and still runs the reviewer" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "gencr: review scope:" && [ "$(calls)" -eq 1 ]'
check "metadata records method, target, review base, merge commit and the git merge-base" \
  eval '[ "$(json_get "$PKG/metadata.json" "d[\"identity\"][\"scope_method\"]")" = merge-commit ] &&
        [ "$(json_get "$PKG/metadata.json" "d[\"identity\"][\"scope_target\"]")" = "branch proposal" ] &&
        [ "$(json_get "$PKG/metadata.json" "d[\"identity\"][\"review_base\"]")" = "$(sha staging~3)" ] &&
        [ "$(json_get "$PKG/metadata.json" "d[\"identity\"][\"merge_commit\"]")" = "$MERGE" ] &&
        [ "$(json_get "$PKG/metadata.json" "d[\"identity\"][\"git_merge_base\"]")" = "$FEATURE" ]'
check "the report header shows the review scope" \
  eval 'grep -qF "Review Scope: merge-commit (given), target branch proposal, $(sha staging~3 | cut -c1-12)..$(echo "$FEATURE" | cut -c1-12), merge commit $(echo "$MERGE" | cut -c1-12)" "$PKG/full-report.md"'

# A later merge of the same head (redundant re-merge) is never chosen; given explicitly it is refused.
git -C "$R" checkout -q staging
REMERGE="$(git -C "$R" commit-tree -p HEAD -p "$FEATURE" -m "redundant re-merge" "HEAD^{tree}")"
git -C "$R" reset -q --hard "$REMERGE"
publish
git -C "$R" checkout -q feature
run_in "$R" --print --fresh
check "redundant re-merge: the first introduction is found" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "merge commit $(echo "$MERGE" | cut -c1-12)"'
run_in "$R" --print --merge-commit="$REMERGE"
check "redundant re-merge given explicitly is refused" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "already part of origin/staging before"'

# Merge evidence that does not merge HEAD, or is not on the base's first-parent history.
git -C "$R" checkout -q -b other staging~1
commit_file other.py
SIDE_MERGE="$(git -C "$R" commit-tree -p "$(sha other)" -p "$FEATURE" -m "side merge" "$(sha other)^{tree}")"
git -C "$R" checkout -q feature
run_in "$R" --print --merge-commit="$SIDE_MERGE"
check "--merge-commit off the base's first-parent history is refused" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "is not on the first-parent history of origin/staging"'
git -C "$R" checkout -q other
run_in "$R" --print --merge-commit="$MERGE"
check "--merge-commit whose second parent is not HEAD is refused" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "is $(echo "$FEATURE" | cut -c1-12), not HEAD"'

# The integrated result (including a conflict resolution) is a different, explicit target.
new_repo conflict
commit_file shared.txt original
git -C "$R" checkout -q -b feature
commit_file shared.txt feature-side
FEATURE="$(sha HEAD)"
git -C "$R" checkout -q staging
commit_file shared.txt staging-side
publish
git -C "$R" merge -q --no-ff -m "merge feature" feature >/dev/null 2>&1
echo resolved-in-merge > "$R/shared.txt"
git -C "$R" add shared.txt && git -C "$R" commit -qm "merge feature (resolved)"
MERGE="$(sha HEAD)"
publish
git -C "$R" checkout -q feature
run_in "$R" --print
check "branch proposal: the reviewed diff is the branch's change, not the merge resolution" \
  eval '[ "$STATUS" -eq 0 ] && contains "$OUT" "+feature-side" && ! contains "$OUT" "resolved-in-merge"'
git -C "$R" checkout -q --detach "$MERGE"
run_in "$R" --print --range="$(sha "$MERGE^1")..$MERGE"
check "integrated result: an explicit range at the merge reviews the resolution" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "method explicit-range, target explicit range" && contains "$OUT" "+resolved-in-merge"'

# ── Squash and rebase merges (head stays outside the base) ─────────────────────

new_repo squash
git -C "$R" checkout -q -b feature
commit_file s1.py
commit_file s2.py
git -C "$R" checkout -q staging
git -C "$R" merge -q --squash feature >/dev/null && git -C "$R" commit -qm "squashed feature"
commit_file after.txt
publish
git -C "$R" checkout -q feature
run_in "$R" --print
check "squash merge then base advances: the branch is reviewed by merge-base, later base commits excluded" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "method merge-base" && lists s1.py && lists s2.py && ! lists after.txt'

new_repo rebase
git -C "$R" checkout -q -b feature
commit_file r1.py
git -C "$R" checkout -q staging
commit_file moved.txt
git -C "$R" cherry-pick -q feature
commit_file after.txt
publish
git -C "$R" checkout -q feature
run_in "$R" --print
check "rebase merge (rewritten commits): reviewed by merge-base" \
  eval '[ "$STATUS" -eq 0 ] && lists r1.py && ! lists moved.txt && ! lists after.txt'

# codex HIST-D1-R2: squash, then another branch integrates the PR's first commit into the base.
new_repo prefix
ORIGINAL="$(sha HEAD)"
git -C "$R" checkout -q -b feature
commit_file first.py
PREFIX="$(sha HEAD)"
commit_file second.py
git -C "$R" checkout -q staging
git -C "$R" merge -q --squash feature >/dev/null && git -C "$R" commit -qm "squashed feature"
git -C "$R" merge -q --no-ff -m "another branch brings in the first commit" "$PREFIX"
publish
git -C "$R" checkout -q feature
run_in "$R" --print
check "shared prefix integrated by a merge: the current delta is labelled and warned about" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "target current branch delta" &&
        contains "$ERR" "gencr: note: merge-base $(echo "$PREFIX" | cut -c1-12) was integrated into origin/staging through a merge" &&
        contains "$ERR" "--range=<original base>..HEAD"'
run_in "$R" --print --range="$ORIGINAL..$(sha HEAD)"
check "shared prefix: the explicit original range reviews the whole proposal" \
  eval '[ "$STATUS" -eq 0 ] && lists first.py && lists second.py'

# ── Merged without usable merge evidence ───────────────────────────────────────

new_repo ff
git -C "$R" checkout -q -b feature
commit_file ff.py
git -C "$R" checkout -q staging
git -C "$R" merge -q --ff-only feature
publish
git -C "$R" checkout -q feature
run_in "$R" --print
check "fast-forward merge: actionable error, no reviewer" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "fast-forward" && contains "$ERR" "--range=<original base>.." && [ "$(calls)" -eq 0 ]'

new_repo octopus
git -C "$R" checkout -q -b feature
commit_file oct.py
git -C "$R" checkout -q -b other staging
commit_file other.py
git -C "$R" checkout -q staging
git -C "$R" merge -q --no-ff -m octopus feature other
publish
git -C "$R" checkout -q feature
run_in "$R" --print
check "octopus merge: refused" eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "octopus"'

new_repo indirect
git -C "$R" checkout -q -b feature
commit_file ind.py
git -C "$R" checkout -q -b integration staging
commit_file int.py
git -C "$R" merge -q --no-ff -m "feature into integration" feature
git -C "$R" checkout -q staging
git -C "$R" merge -q --no-ff -m "integration into staging" integration
publish
git -C "$R" checkout -q feature
run_in "$R" --print
check "merged indirectly through another branch: refused with guidance" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "through another branch" && contains "$ERR" "--merge-commit"'

# Shallow history cannot prove the introduction.
git clone -q --no-local --depth 2 --branch staging "$WORK/merged.git" "$WORK/shallow" 2>/dev/null
git -C "$WORK/shallow" checkout -q --detach "$(git -C "$WORK/shallow" rev-parse 'HEAD^2')"
run_in "$WORK/shallow" --print
check "shallow clone of a merged branch: fetch full history" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "git fetch --unshallow"'

# ── Criss-cross histories (codex HIST-D3-R2) ──────────────────────────────────

new_repo criss
git -C "$R" checkout -q -b a
commit_file a.py
git -C "$R" checkout -q -b c staging
commit_file c.py
git -C "$R" checkout -q -b feature a
git -C "$R" merge -q --no-ff -m "H: a + c" c
H="$(sha HEAD)"
git -C "$R" checkout -q -b p c
git -C "$R" merge -q --no-ff -m "P: c + a" a
git -C "$R" checkout -q staging
git -C "$R" reset -q --hard p
publish
git -C "$R" checkout -q feature
run_in "$R" --print
check "criss-cross on the ordinary method: ambiguous base refused" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "ambiguous review base (criss-cross history)" && contains "$ERR" "--range="'
git -C "$R" checkout -q staging
git -C "$R" merge -q --no-ff -m "M: P + H" feature
M="$(sha HEAD)"
publish
git -C "$R" checkout -q feature
run_in "$R" --print
check "criss-cross with a discovered merge commit: refused" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "ambiguous review base"'
run_in "$R" --print --merge-commit="$M"
check "criss-cross with a given merge commit: refused" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "ambiguous review base"'

# ── Explicit ranges ────────────────────────────────────────────────────────────

R="$WORK/merged"
git -C "$R" checkout -q feature
BASE0="$(sha feature~2)" HEAD0="$(sha feature)"
run_in "$R" --print --range "$BASE0..$HEAD0"
check "--range space form: exact pair, never rewritten" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "method explicit-range" && contains "$ERR" "base $(echo "$BASE0" | cut -c1-12)" && lists one.py'
run_in "$R" --print --range="$(sha feature~1)..$HEAD0"
check "--range with a later base reviews only the later commits" eval '[ "$STATUS" -eq 0 ] && lists two.py && ! lists one.py'
run_in "$R" --print --range="$BASE0..$(sha feature~1)"
check "--range head that is not HEAD: check out instruction" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "git switch --detach $(sha feature~1)"'
run_in "$R" --print --range="1234567890abcdef1234567890abcdef12345678..$HEAD0"
check "--range with an unknown commit: fetch instruction" eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "git fetch origin 1234567890abcdef"'
run_in "$R" --print --range="$(sha staging)..$HEAD0"
check "--range base that is not an ancestor of head is refused" eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "is not an ancestor of"'
run_in "$R" --print --range="$HEAD0..$HEAD0"
check "--range with equal base and head is refused" eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "nothing to review"'
for bad in "main..HEAD" "$BASE0...$HEAD0" "$BASE0" "-x..$HEAD0"; do
  run_in "$R" --print --range="$bad"
  check "--range '$bad' is a usage error" eval '[ "$STATUS" -eq 2 ]'
done
run_in "$R" --print --range="$BASE0..$HEAD0" --merge-commit="$HEAD0"
check "--range and --merge-commit together are a usage error" eval '[ "$STATUS" -eq 2 ]'
run_in "$R" --print --incremental --range="$BASE0..$HEAD0"
check "--range with --incremental is a usage error" eval '[ "$STATUS" -eq 2 ]'
run_in "$R" --print --incremental --merge-commit="$HEAD0"
check "--merge-commit with --incremental is a usage error" eval '[ "$STATUS" -eq 2 ]'

# ── Incremental anchors ────────────────────────────────────────────────────────

new_repo inc
git -C "$R" checkout -q -b feature
commit_file inc.py
git -C "$R" checkout -q staging
git -C "$R" merge -q --no-ff -m "merge feature" feature
publish
git -C "$R" checkout -q feature
OUTDIR="$WORK/inc-out"
MOCK_VERDICT="REQUEST CHANGES" run_in "$R" --output-dir="$OUTDIR"
FIRST="$(ls -td "$OUTDIR"/review-* | head -n 1)"
check "historical FRESH with open findings (fixture)" eval '[ "$STATUS" -eq 10 ]'
run_in "$R" --print --incremental --output-dir="$OUTDIR"
check "same-head incremental after a merge-commit review: that review covers HEAD, nothing new to review" \
  eval '[ "$STATUS" -eq 0 ] && contains "$ERR" "no new review needed" && contains "$ERR" "(verdict REQUEST CHANGES)"'
commit_file followup.py
run_in "$R" --print --incremental --output-dir="$OUTDIR"
check "branch advanced after the merge: refused as merge-commit evidence mismatch" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "no longer matches HEAD" && contains "$ERR" "--fresh"'
git -C "$R" reset -q --hard HEAD~1
RANGE_OUT="$WORK/range-out"
MOCK_VERDICT="REQUEST CHANGES" run_in "$R" --output-dir="$RANGE_OUT" --range="$(sha HEAD~1)..$(sha HEAD)"
run_in "$R" --print --incremental --output-dir="$RANGE_OUT"
check "an explicit-range package is never an incremental baseline" \
  eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "explicit range"'

# A package written before scope methods existed is read as a merge-base review.
new_repo legacy
git -C "$R" checkout -q -b feature
commit_file leg.py
LEGACY_OUT="$WORK/legacy-out"
MOCK_VERDICT="REQUEST CHANGES" run_in "$R" --output-dir="$LEGACY_OUT"
LEG="$(ls -td "$LEGACY_OUT"/review-* | head -n 1)"
python3 - "$LEG" <<'EOF'
import hashlib, json, os, sys
run = sys.argv[1]
meta_path = os.path.join(run, "metadata.json")
meta = json.load(open(meta_path))
for key in ("review_base", "scope_method", "scope_target", "merge_commit", "git_merge_base"):
    meta["identity"].pop(key, None)
open(meta_path, "w").write(json.dumps(meta, indent=2))
manifest_path = os.path.join(run, "manifest.json")
manifest = json.load(open(manifest_path))
manifest["files"]["metadata.json"] = hashlib.sha256(open(meta_path, "rb").read()).hexdigest()
open(manifest_path, "w").write(json.dumps(manifest, indent=2))
EOF
commit_file leg2.py
run_in "$R" --print --incremental --output-dir="$LEGACY_OUT"
check "a legacy package without scope fields is still a merge-base baseline" \
  eval '[ "$STATUS" -eq 0 ] && contains "$OUT" "Review mode: INCREMENTAL"'

# ── Revision 1: coverage labels, incremental range, base-free explicit range (codex HIST-I1..I3) ──

# HIST-I1: a known-partial current delta is never labelled or prompted as a full PR review.
R="$WORK/prefix"
git -C "$R" checkout -q feature
PART_OUT="$WORK/partial-out"
run_in "$R" --output-dir="$PART_OUT"
PART="$(ls -td "$PART_OUT"/review-* | head -n 1)"
check "known partial delta: the package is labelled current branch delta, not Full PR" \
  eval '[ "$STATUS" -eq 0 ] && grep -qF "Approval Scope: Current branch delta only (merge-base $(echo "$PREFIX" | cut -c1-12)" "$PART/full-report.md" &&
        ! grep -qF "Approval Scope: Full PR" "$PART/full-report.md" &&
        [ "$(json_get "$PART/metadata.json" "d[\"approval_scope\"]")" = partial ]'
check "known partial delta: the prompt does not claim the complete pull request" \
  eval 'grep -qF "Review mode: FRESH (review of the branch'"'"'s current delta against origin/staging; not the complete original pull request):" "$PART/00-shared-prompt.md" &&
        ! grep -qF "FRESH (complete review of the pull request)" "$PART/00-shared-prompt.md"'
RANGE2_OUT="$WORK/range2-out"
run_in "$R" --output-dir="$RANGE2_OUT" --range="$PREFIX..$(sha HEAD)"
RNG="$(ls -td "$RANGE2_OUT"/review-* | head -n 1)"
check "explicit (narrowed) range: labelled explicit range only, in report, metadata and prompt" \
  eval '[ "$STATUS" -eq 0 ] && grep -qF "Approval Scope: Explicit range only ($(echo "$PREFIX" | cut -c1-12) .. HEAD" "$RNG/full-report.md" &&
        [ "$(json_get "$RNG/metadata.json" "d[\"approval_scope\"]")" = range ] &&
        grep -qF "Review mode: FRESH (complete review of the requested range):" "$RNG/00-shared-prompt.md"'
R="$WORK/open"
git -C "$R" checkout -q feature
OPEN_OUT="$WORK/open-out"
run_in "$R" --output-dir="$OPEN_OUT"
OPN="$(ls -td "$OPEN_OUT"/review-* | head -n 1)"
check "ordinary open branch: still a Full PR review (GitHub's merge-base..head PR diff)" \
  eval 'grep -qF "Approval Scope: Full PR (merge-base" "$OPN/full-report.md" && [ "$(json_get "$OPN/metadata.json" "d[\"approval_scope\"]")" = full ] &&
        grep -qF "Review mode: FRESH (complete review of the pull request):" "$OPN/00-shared-prompt.md"'

# HIST-I2: an incremental review shows the range it actually reviews, with the anchor labelled separately.
new_repo incrange
ANCHOR="$(sha HEAD)"
git -C "$R" checkout -q -b feature
commit_file a.py
FIRST_HEAD="$(sha HEAD)"
INC2_OUT="$WORK/inc2-out"
MOCK_VERDICT="REQUEST CHANGES" run_in "$R" --output-dir="$INC2_OUT"
commit_file h.py
run_in "$R" --incremental --output-dir="$INC2_OUT"
INC2="$(ls -td "$INC2_OUT"/review-* | head -n 1)"
check "incremental: stderr shows the reviewed range and the anchor separately" \
  eval 'contains "$ERR" "gencr: review scope: INCREMENTAL since" && contains "$ERR" "range $(echo "$FIRST_HEAD" | cut -c1-12)..$(sha HEAD | cut -c1-12), anchor merge-base $(echo "$ANCHOR" | cut -c1-12)"'
check "incremental: header and metadata record the reviewed range start, not the anchor" \
  eval 'grep -qF "Review Scope: incremental $(echo "$FIRST_HEAD" | cut -c1-12)..$(sha HEAD | cut -c1-12) (anchor merge-base $(echo "$ANCHOR" | cut -c1-12))" "$INC2/full-report.md" &&
        [ "$(json_get "$INC2/metadata.json" "d[\"identity\"][\"review_base\"]")" = "$FIRST_HEAD" ] &&
        [ "$(json_get "$INC2/metadata.json" "d[\"identity\"][\"merge_base\"]")" = "$ANCHOR" ]'

# HIST-I3: an exact range needs only its own commits, not the configured base ref.
R="$WORK/noorigin"
git init -q "$R"
git -C "$R" config user.email t@example.com
git -C "$R" config user.name T
echo base > "$R/base.txt" && git -C "$R" add . && git -C "$R" commit -qm base
NO_BASE="$(sha HEAD)"
commit_file x.py
run_in "$R" --print --range="$NO_BASE..$(sha HEAD)"
check "--range works without any origin remote" \
  eval '[ "$STATUS" -eq 0 ] && lists x.py && contains "$ERR" "method explicit-range"'
run_in "$R" --print
check "without --range, a missing base ref is still an error" eval '[ "$STATUS" -eq 1 ] && contains "$ERR" "base ref origin/staging not found"'
NB_OUT="$WORK/nobase-out"
run_in "$R" --output-dir="$NB_OUT" --range="$NO_BASE..$(sha HEAD)"
NB="$(ls -td "$NB_OUT"/review-* | head -n 1)"
check "--range without a base ref records the base tip and git merge-base as unavailable" \
  eval '[ "$STATUS" -eq 0 ] && grep -qF "Base Branch: origin/staging (tip unavailable)" "$NB/full-report.md" &&
        [ "$(json_get "$NB/metadata.json" "d[\"identity\"][\"git_merge_base\"]")" = None ]'
R="$WORK/merged"
git -C "$R" checkout -q feature
(cd "$R" && CODEREVIEW_BASE_BRANCH=no-such-base "$GENCR" dev --print --range="$(sha feature~2)..$(sha feature)") > "$WORK/out" 2> "$WORK/err"
STATUS=$?; OUT="$(cat "$WORK/out")"; ERR="$(cat "$WORK/err")"
check "--range works when the configured base branch does not exist" eval '[ "$STATUS" -eq 0 ] && lists one.py'

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
