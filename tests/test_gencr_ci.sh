#!/usr/bin/env bash
# Tests for bin/gencr-ci (the GitHub Actions adapter) and the workflow files, using a mock `gh`
# that simulates the GitHub API. No network, credentials or real reviewers.
# Usage: bash tests/test_gencr_ci.sh
# shellcheck disable=SC2016,SC2012,SC2034  # deferred eval checks; fixture paths are known-safe

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd -P "$(mktemp -d)" && pwd)/gencr ci tests"
mkdir -p "$WORK"
trap 'rm -rf "$(dirname "$WORK")"' EXIT

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
not_ok() { FAIL=$((FAIL + 1)); echo "not ok - $1"; [ -z "$2" ] || printf '%s\n' "$2" | sed 's/^/    # /'; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else not_ok "$desc"; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
py() { python3 -B -c "$@"; }

CI="$REPO/bin/gencr-ci"
MOCKS="$WORK/mocks"
mkdir -p "$MOCKS"
cp "$REPO/tests/mocks/mock_reviewer.py" "$REPO/tests/mocks/mock_gh.py" "$MOCKS/"
ln -s mock_reviewer.py "$MOCKS/claude"
ln -s mock_reviewer.py "$MOCKS/codex"
ln -s mock_gh.py "$MOCKS/gh"
export PATH="$MOCKS:$PATH" HOME="$WORK/home" GH_STATE="$WORK/gh-state.json"
mkdir -p "$HOME"
unset MOCK_STATE MOCK_VERDICT GITHUB_OUTPUT
GH_REPO_NAME="acme/app"

# A real PR repository and two review packages produced by gencr with the mock reviewers.
TARGET="$WORK/target"
git init -q --bare "$WORK/origin.git"
git init -q "$TARGET"
git -C "$TARGET" config user.email t@example.com
git -C "$TARGET" config user.name T
git -C "$TARGET" checkout -q -b main
echo base > "$TARGET/base.txt"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm base
git -C "$TARGET" remote add origin "$WORK/origin.git"
git -C "$TARGET" push -q origin main
# The packages must carry the GitHub identity of the repository the workflow reviews.
git -C "$TARGET" remote set-url origin https://github.com/acme/app.git
git -C "$TARGET" checkout -q -b feature
echo 'x = 1' > "$TARGET/app.py"
git -C "$TARGET" add . && git -C "$TARGET" commit -qm feature
HEAD_SHA="$(git -C "$TARGET" rev-parse HEAD)"
OTHER_SHA="$(git -C "$TARGET" rev-parse main)"

make_package() { # dir verdict [extra gencr args]
  local out="$1" verdict="$2"
  shift 2
  (cd "$TARGET" && CODEREVIEW_BASE_BRANCH=main MOCK_VERDICT="$verdict" "$REPO/bin/gencr" pr-7 --pr-number=7 \
    --output-dir="$out" "$@") >/dev/null 2>&1
}
make_package "$WORK/out-approved" APPROVED --codex=attack --claude-model=opus
make_package "$WORK/out-rc" "REQUEST CHANGES" --codex=attack

reset_gh() { # writes the mock GitHub state; $1 PR state, $2 PR head sha, $3 draft (false, true or missing)
  python3 - "$GH_STATE" "${1:-open}" "${2:-$HEAD_SHA}" "${3:-false}" <<'EOF'
import json, sys
path, pr_state, head, draft = sys.argv[1:5]
merged = pr_state == "merged-closed"
pr = {"number": 7, "state": "closed" if merged else pr_state, "merged": merged, "head": {"sha": head, "repo": {"full_name": "acme/app"}},
      "base": {"ref": "main", "repo": {"full_name": "acme/app"}}}
if draft != "missing":
    pr["draft"] = draft == "true"
json.dump({"prs": {"7": pr},
           "comments": [], "statuses": [], "runs": {}, "artifacts": {}, "downloads": {}}, open(path, "w"))
EOF
  : > "$GH_STATE.calls"
}
gh_eval() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); exec("print(" + sys.argv[2] + ")")' "$GH_STATE" "$1"; }
run_ci() { "$CI" "$@" > "$WORK/out" 2> "$WORK/err"; STATUS=$?; OUT="$(cat "$WORK/out")"; ERR="$(cat "$WORK/err")"; }

# ── gate ───────────────────────────────────────────────────────────────────────

gate() { # overrides as NAME=VALUE...
  local ref=refs/heads/main backend=mock pr=7 version="" scope=fresh primary=claude adversary=codex
  local claude_model="" codex_model="" retention=30 timeout=20 assignment
  for assignment in "$@"; do local "$assignment"; done
  run_ci gate --ref "$ref" --default-branch main --backend "$backend" --pr-number "$pr" --version "$version" \
    --scope "$scope" --primary "$primary" --adversary "$adversary" --claude-model "$claude_model" \
    --codex-model "$codex_model" --retention-days "$retention" --timeout-minutes "$timeout"
}
gate
check "gate accepts valid inputs on the default branch with the mock backend" [ "$STATUS" -eq 0 ]
gate_rejects() { local desc="$1" expect="$2"; shift 2; gate "$@"
  if [ "$STATUS" -ne 0 ] && contains "$ERR" "$expect"; then ok "gate rejects $desc"; else not_ok "gate rejects $desc" "$ERR"; fi; }
gate_rejects "a non-default (untrusted) tooling ref" "protected default branch" ref=refs/heads/attacker
gate_rejects "the live (paid) backend" "paid reviews are disabled" backend=live
gate_rejects "a non-numeric PR number" "pr_number" 'pr=7;id'
gate_rejects "the same reviewer twice" "must be different" adversary=claude
gate_rejects "a workflow-command-shaped model" "claude_model is not a valid" 'claude_model=::set-output name=x::y'
gate_rejects "a model with spaces" "codex_model is not a valid" 'codex_model=gpt 5'
gate_rejects "retention above 90 days" "retention_days" retention=91
gate_rejects "an unsupported scope" "scope must be" scope=full
gate adversary=none
check "gate accepts a single-reviewer review (adversary none)" [ "$STATUS" -eq 0 ]

# ── context ────────────────────────────────────────────────────────────────────

reset_gh
export GITHUB_OUTPUT="$WORK/gh-output"
: > "$GITHUB_OUTPUT"
run_ci context --repo "$GH_REPO_NAME" --pr-number 7
check "context writes the PR head SHA, base ref and fork flag as outputs" \
  eval '[ "$STATUS" -eq 0 ] && grep -qx "head_sha=$HEAD_SHA" "$GITHUB_OUTPUT" && grep -qx "base_ref=main" "$GITHUB_OUTPUT" && grep -qx "fork=false" "$GITHUB_OUTPUT"'
reset_gh closed
run_ci context --repo "$GH_REPO_NAME" --pr-number 7
check "context rejects a closed pull request" eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "is closed"'
reset_gh
run_ci context --repo "$GH_REPO_NAME" --pr-number 7 --expected-sha "$OTHER_SHA"
check "context rejects a head that differs from the intended commit" eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "not the expected"'
run_ci context --repo other/repo --pr-number 7
check "context rejects a PR that is not in the workflow's repository" eval '[ "$STATUS" -ne 0 ]'
run_ci context --repo 'acme/app;rm' --pr-number 7
check "context rejects a malformed repository name" eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "invalid repository"'
unset GITHUB_OUTPUT

# ── historical-scope: merged pull requests ────────────────────────────────────

reset_gh merged-closed
run_ci context --repo "$GH_REPO_NAME" --pr-number 7
check "context accepts a merged pull request" eval '[ "$STATUS" -eq 0 ]'
reset_gh closed
run_ci context --repo "$GH_REPO_NAME" --pr-number 7
check "context still rejects a pull request closed without merging" eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "closed without being merged"'

# A PR repository: O on main; the PR adds first.py (A) and second.py (B). It is squash-merged (S), and later
# another branch merges A into main (codex HIST-D1-R2), so the current merge-base silently drops first.py.
HIST="$WORK/hist"
git init -q --bare "$WORK/hist.git"
git init -q "$HIST"
git -C "$HIST" config user.email t@example.com
git -C "$HIST" config user.name T
git -C "$HIST" checkout -q -b main
echo base > "$HIST/base.txt"
git -C "$HIST" add . && git -C "$HIST" commit -qm base
H_O="$(git -C "$HIST" rev-parse HEAD)"
git -C "$HIST" remote add origin "$WORK/hist.git"
git -C "$HIST" checkout -q -b pr
echo 1 > "$HIST/first.py" && git -C "$HIST" add . && git -C "$HIST" commit -qm A
H_A="$(git -C "$HIST" rev-parse HEAD)"
echo 2 > "$HIST/second.py" && git -C "$HIST" add . && git -C "$HIST" commit -qm B
H_B="$(git -C "$HIST" rev-parse HEAD)"
git -C "$HIST" checkout -q main
git -C "$HIST" merge -q --squash pr >/dev/null && git -C "$HIST" commit -qm S
H_S="$(git -C "$HIST" rev-parse HEAD)"
git -C "$HIST" merge -q --no-ff -m "another branch brings in A" "$H_A"
git -C "$HIST" push -q origin main pr
git -C "$HIST" fetch -q origin
git -C "$HIST" checkout -q --detach "$H_B"
# A second PR, regular-merged: R1 on top of O, merged by a two-parent merge commit.
git -C "$HIST" checkout -q -b regular "$H_O"
echo r > "$HIST/regular.py" && git -C "$HIST" add . && git -C "$HIST" commit -qm R1
H_R="$(git -C "$HIST" rev-parse HEAD)"
git -C "$HIST" checkout -q -b landed "$H_S"
git -C "$HIST" merge -q --no-ff -m "merge regular" regular
H_RM="$(git -C "$HIST" rev-parse HEAD)"
git -C "$HIST" checkout -q --detach "$H_B"

commit_json() { # sha... -> PR commit list entries with their real parents
  local sha
  for sha in "$@"; do
    printf '{"sha": "%s", "parents": [%s]}\n' "$sha" \
      "$(git -C "$HIST" rev-list --parents -n 1 "$sha" | cut -d' ' -f2- | tr ' ' '\n' | sed 's/.*/{"sha": "&"}/' | paste -sd, -)"
  done | paste -sd, - | sed 's/^/[/; s/$/]/'
}
hist_gh() { # head merge_commit_sha count page_size commit-list-json [fail_path]
  python3 - "$GH_STATE" "$@" <<'EOF'
import json, sys
path, head, merge, count, size, commits = sys.argv[1:7]
fail = sys.argv[7:]
json.dump({"prs": {"7": {"number": 7, "state": "closed", "merged": True, "merge_commit_sha": merge,
                         "commits": int(count), "head": {"sha": head, "repo": {"full_name": "acme/app"}},
                         "base": {"ref": "main", "repo": {"full_name": "acme/app"}}}},
           "pr_commits": {"7": json.loads(commits)}, "commit_page_size": int(size), "fail_paths": fail,
           "comments": [], "statuses": [], "runs": {}, "artifacts": {}, "downloads": {}}, open(path, "w"))
EOF
  : > "$GH_STATE.calls"
}
hist() { # [head]
  git -C "$HIST" checkout -q --detach "${1:-$H_B}"
  export GITHUB_OUTPUT="$WORK/gh-output"
  : > "$GITHUB_OUTPUT"
  run_ci historical-scope --repo "$GH_REPO_NAME" --pr-number 7 --expected-sha "${1:-$H_B}" --target "$HIST"
  SCOPE_ARG="$(sed -n 's/^scope_arg=//p' "$GITHUB_OUTPUT")"
  unset GITHUB_OUTPUT
}

reset_gh open "$H_B"
hist
check "historical-scope: an open pull request adds no scope argument" eval '[ "$STATUS" -eq 0 ] && [ -z "$SCOPE_ARG" ]'

hist_gh "$H_R" "$H_RM" 1 100 "$(commit_json "$H_R")"
hist "$H_R"
check "historical-scope: a regular merge yields --merge-commit" eval '[ "$STATUS" -eq 0 ] && [ "$SCOPE_ARG" = "--merge-commit=$H_RM" ]'

hist_gh "$H_B" "$H_S" 2 1 "$(commit_json "$H_A" "$H_B")"
hist
check "historical-scope: a squash merge yields the exact original range from the complete commit list" \
  eval '[ "$STATUS" -eq 0 ] && [ "$SCOPE_ARG" = "--range=$H_O..$H_B" ]'
check "historical-scope: the commit list is read with pagination" eval 'grep -q -- "--paginate --slurp repos/acme/app/pulls/7/commits" "$GH_STATE.calls"'
(cd "$HIST" && CODEREVIEW_BASE_BRANCH=main "$REPO/bin/gencr" pr-7 --print "$SCOPE_ARG") > "$WORK/hist-print" 2>&1
check "historical-scope: gencr with that range reviews both original files" \
  eval 'grep -q " first.py" "$WORK/hist-print" && grep -q " second.py" "$WORK/hist-print" && grep -q "method explicit-range" "$WORK/hist-print"'

hist_gh "$H_B" "$H_S" 2 100 "$(commit_json "$H_B")"
hist
check "historical-scope: a truncated (suffix-only) commit list is refused, although it is locally consistent" \
  eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "lists 1 of the 2 commits" && [ -z "$SCOPE_ARG" ]'
hist_gh "$H_B" "$H_S" 2 1 "$(commit_json "$H_A" "$H_B")" "pulls/7/commits"
hist
check "historical-scope: a failed commit-list request is refused" eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "cannot read the complete commit list" && [ -z "$SCOPE_ARG" ]'
hist_gh "$H_B" "$H_S" 300 100 "$(commit_json "$H_A" "$H_B")"
hist
check "historical-scope: a pull request beyond the provider's commit list limit is refused" \
  eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "lists 2 of the 300 commits"'
hist_gh "$H_B" "$H_S" 3 100 "$(commit_json "$H_A" "$H_B" "$H_A")"
hist
check "historical-scope: duplicate commits in the list are refused" eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "duplicate"'
hist_gh "$H_B" "$H_S" 3 100 "$(commit_json "$H_A" "$H_B" "$H_RM")"
hist
check "historical-scope: commits with several outside parents are refused" \
  eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "more than one parent outside"'
# A foreign commit claimed in place of A, with parents that form a consistent-looking chain.
hist_gh "$H_B" "$H_S" 2 100 "[{\"sha\": \"$H_R\", \"parents\": [{\"sha\": \"$H_O\"}]}, {\"sha\": \"$H_B\", \"parents\": [{\"sha\": \"$H_R\"}]}]"
hist
check "historical-scope: a list that disagrees with local history is refused" \
  eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "does not match the local history"'
hist_gh "$H_A" "$H_S" 2 100 "$(commit_json "$H_A" "$H_B")"
hist "$H_B"
check "historical-scope: a pull request head that is not the checked-out commit is refused" \
  eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "not the expected"'
hist_gh "$H_B" "$H_S" 1 100 "$(commit_json "$H_B")"
python3 - "$GH_STATE" <<'EOF'
import json, sys
state = json.load(open(sys.argv[1]))
state["prs"]["7"]["commits"] = True
json.dump(state, open(sys.argv[1], "w"))
EOF
hist
check "historical-scope: a non-integer (boolean) commit count is refused (codex HIST-C1)" \
  eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "does not report its commit count" && [ -z "$SCOPE_ARG" ]'
hist_gh "$H_B" "$H_S" 1 100 "$(commit_json "$H_A")"
hist
git -C "$HIST" checkout -q --detach "$H_B"
check "historical-scope: a list without the pull request head is refused" eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "does not include the pull request head" && [ -z "$SCOPE_ARG" ]'

# ── package ────────────────────────────────────────────────────────────────────

run_ci package --output-dir "$WORK/out-approved" --pr-number 7 --backend mock --out "$WORK/art-approved"
ART="$WORK/art-approved/code-review-pr-7"
check "package contains exactly the standard files, the manifest, the CI disposition and transcripts" \
  [ "$(cd "$ART" && ls | tr '\n' ' ')" = "ci-backend.json ci-disposition.json findings.json full-report.md manifest.json metadata.json reconciliation.md summary.md transcripts " ]
check "a review package's CI disposition is 'packaged'" [ "$(py 'import json,sys; print(json.load(open(sys.argv[1]))["disposition"])' "$ART/ci-disposition.json")" = packaged ]
check "the artifact records the reviewer backend" [ "$(py 'import json,sys; print(json.load(open(sys.argv[1]))["backend"])' "$ART/ci-backend.json")" = mock ]
check "package transcripts hold prompts, reports and invocation records only (no logs, raw output or state)" \
  eval '[ -z "$(ls "$ART/transcripts" | grep -vE "^(00-shared-prompt\.md|[0-9][0-9]-round[0-9]-(claude|codex)-[a-z]+\.(prompt\.md|report\.md|invoke\.json))$")" ] && [ -n "$(ls "$ART/transcripts")" ]'
check "the packaged review is still a valid, verifiable package" \
  py 'import sys; sys.path.insert(0, sys.argv[1]); import gencr_support as g; g.load_package(sys.argv[2])' "$REPO/bin" "$ART"
run_ci package --output-dir "$WORK/no-such-output" --pr-number 7 --backend mock --out "$WORK/art-missing"
check "a run that produced no package becomes an explicit infrastructure-failure artifact" \
  eval 'grep -q "INFRASTRUCTURE FAILURE" "$WORK/art-missing/code-review-pr-7/summary.md" && contains "$OUT" "packaged=false"'
run_ci package --output-dir "$WORK/out-rc" --pr-number 7 --backend mock --out "$WORK/art-rc"

# ── publish ────────────────────────────────────────────────────────────────────

publish() { # artifact-root run-id [attempt] — as a future live backend would publish
  run_ci publish --repo "$GH_REPO_NAME" --pr-number 7 --run-id "$2" --run-attempt "${3:-1}" --package "$1" \
    --run-url "https://github.example/acme/app/actions/runs/$2" --artifact-url "https://github.example/artifacts/$2" \
    --retention-days 30 --reviewed-sha "${REVIEWED-$HEAD_SHA}" --review-result "${RESULT:-success}" --backend "${BACKEND:-live}"
}
reset_gh
publish "$WORK/art-approved" 100
BODY="$(gh_eval 'd["comments"][0]["body"]')"
check "publish creates one bot comment and a success status on the reviewed SHA" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(gh_eval "len(d[\"comments\"])")" = 1 ] && [ "$(gh_eval "(d[\"statuses\"][0][\"state\"], d[\"statuses\"][0][\"sha\"], d[\"statuses\"][0][\"context\"])")" = "('"'"'success'"'"', '"'"'$HEAD_SHA'"'"', '"'"'gencr/review'"'"')" ]'
for field in "## Code review: APPROVED" "- Mode: FRESH" "Claude: opus" "Codex: mock-codex-default" "- Reviewed commit: $HEAD_SHA" \
    "https://github.example/artifacts/100" "not permanent PR attachments"; do
  check "the PR comment shows: $field" contains "$BODY" "$field"
done
check "the PR comment carries the package's summary.md review comment exactly (one source)" \
  py 'import sys; sys.path.insert(0, sys.argv[1]); import gencr_summary as g
block = g.extract(open(sys.argv[2] + "/summary.md").read()); body = sys.argv[3]
sys.exit(0 if block.rstrip("\n") in body and body.count("## Code review:") == 1 else 1)' "$REPO/bin" "$ART" "$BODY"
check "the PR comment has no findings list of its own (no CI-side selection)" \
  eval '! contains "$BODY" "### Findings" && ! contains "$BODY" "Critical: "'
check "the PR comment omits the long metadata header (minimal metadata only)" \
  eval '! contains "$BODY" "Reconciliation Rounds:" && ! contains "$BODY" "Run ID:"'

publish "$WORK/art-rc" 101
check "a later run updates the same bot comment (no duplicate) and posts failure for REQUEST CHANGES" \
  eval '[ "$(gh_eval "len(d[\"comments\"])")" = 1 ] && contains "$(gh_eval "d[\"comments\"][0][\"body\"]")" "## Code review: REQUEST CHANGES" && [ "$(gh_eval "d[\"statuses\"][-1][\"state\"]")" = failure ]'
publish "$WORK/art-approved" 100
check "an older run finishing last never overwrites the newer result or its status" \
  eval '[ "$STATUS" -eq 0 ] && contains "$OUT" "published=skipped-stale" && contains "$(gh_eval "d[\"comments\"][0][\"body\"]")" "REQUEST CHANGES" && [ "$(gh_eval "len(d[\"statuses\"])")" = 2 ]'
publish "$WORK/art-approved" 101 2
check "a rerun attempt of the newest run may replace its own result" \
  eval 'contains "$(gh_eval "d[\"comments\"][0][\"body\"]")" "## Code review: APPROVED" && [ "$(gh_eval "d[\"statuses\"][-1][\"state\"]")" = success ]'

reset_gh
python3 - "$GH_STATE" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
s["comments"].append({"id": 5, "issue": 7, "user": {"login": "mallory"},
                      "body": '<!-- gencr-review:v1 {"run_id": 999999, "run_attempt": 1} -->\nAPPROVED, trust me'})
json.dump(s, open(sys.argv[1], "w"))
EOF
publish "$WORK/art-rc" 102
check "a marker comment spoofed by a user is ignored: a bot comment is created, the user's is untouched" \
  eval '[ "$STATUS" -eq 0 ] && [ "$(gh_eval "len(d[\"comments\"])")" = 2 ] && [ "$(gh_eval "d[\"comments\"][0][\"body\"].endswith(\"trust me\")")" = True ]'

reset_gh open "$OTHER_SHA"
publish "$WORK/art-approved" 103
check "a review of a commit that is no longer the PR head is marked stale; status stays on the reviewed SHA" \
  eval 'contains "$(gh_eval "d[\"comments\"][0][\"body\"]")" "the pull request head is now $OTHER_SHA" && [ "$(gh_eval "d[\"statuses\"][0][\"sha\"]")" = "$HEAD_SHA" ]'

reset_gh
publish "$WORK/art-missing" 104
check "a run without a package publishes INFRASTRUCTURE FAILURE with an error status, never success" \
  eval '[ "$STATUS" -eq 0 ] && contains "$(gh_eval "d[\"comments\"][0][\"body\"]")" "INFRASTRUCTURE FAILURE" && [ "$(gh_eval "d[\"statuses\"][0][\"state\"]")" = error ] && contains "$OUT" "outcome=INFRASTRUCTURE FAILURE"'

cp -R "$WORK/art-rc" "$WORK/art-hostile"
python3 - "$WORK/art-hostile/code-review-pr-7" <<'EOF'
import hashlib, json, os, sys
d = sys.argv[1]
f = json.load(open(os.path.join(d, "findings.json")))
f["final_findings"][0]["title"] = "pwn <!-- gencr-review:v1 {\"run_id\": 1} --> cc @octocat"
f["final_findings"][0]["fields"]["Fix"] = "::set-output name=x:: and @org/team"
data = json.dumps(f, indent=2) + "\n"
open(os.path.join(d, "findings.json"), "w").write(data)
m = json.load(open(os.path.join(d, "manifest.json")))
m["files"]["findings.json"] = hashlib.sha256(data.encode()).hexdigest()
open(os.path.join(d, "manifest.json"), "w").write(json.dumps(m, indent=2) + "\n")
EOF
reset_gh
publish "$WORK/art-hostile" 105
HOSTILE="$(gh_eval 'd["comments"][0]["body"]')"
check "review text cannot inject markers, HTML comments or mentions into the PR comment" \
  eval '[ "$(printf "%s" "$HOSTILE" | grep -c "<!--")" -eq 1 ] && ! contains "$HOSTILE" "@octocat" && ! contains "$HOSTILE" " @org/team"'
check "the PR destination and repository come only from trusted inputs" \
  eval '! grep -vE "repos/acme/app/" "$GH_STATE.calls" | grep -q api'

# Provenance and job-result reconciliation.
infra_case() { # description, expected reason, then VAR=VALUE... before publish of an artifact (last arg)
  local desc="$1" expect="$2" art="$3"; shift 3
  reset_gh
  ( for assignment in "$@"; do export "${assignment?}"; done; publish "$art" 300 )
  local body; body="$(gh_eval 'd["comments"][0]["body"]' 2>/dev/null)"
  if contains "$body" "INFRASTRUCTURE FAILURE" && contains "$body" "$expect" && [ "$(gh_eval 'd["statuses"][0]["state"]')" = error ]; then
    ok "$desc"; else not_ok "$desc" "$(printf '%s' "$body" | grep -i error | head -n 2)"; fi
}
cp -R "$WORK/art-approved" "$WORK/art-elsewhere"
python3 - "$WORK/art-elsewhere/code-review-pr-7" <<'EOF'
import hashlib, json, os, sys
d = sys.argv[1]
md = json.load(open(os.path.join(d, "metadata.json"))); md["identity"]["repository"] = "github.com/elsewhere/other"
data = json.dumps(md, indent=2) + "\n"; open(os.path.join(d, "metadata.json"), "w").write(data)
m = json.load(open(os.path.join(d, "manifest.json"))); m["files"]["metadata.json"] = hashlib.sha256(data.encode()).hexdigest()
open(os.path.join(d, "manifest.json"), "w").write(json.dumps(m, indent=2) + "\n")
EOF
infra_case "a complete package for another repository is never published as a review" "is for github.com/elsewhere/other" "$WORK/art-elsewhere"
infra_case "a package whose head differs from the review job's commit is rejected" "not the review job's commit" "$WORK/art-approved" REVIEWED="$OTHER_SHA"
infra_case "a run without a trusted reviewed SHA is an infrastructure failure" "did not record the reviewed commit" "$WORK/art-approved" REVIEWED=
infra_case "a failed review job with an APPROVED artifact never posts success" "the review job did not succeed (failure)" "$WORK/art-approved" RESULT=failure
infra_case "a cancelled review job with an APPROVED artifact never posts success" "the review job did not succeed (cancelled)" "$WORK/art-approved" RESULT=cancelled
reset_gh
RESULT=failure publish "$WORK/art-rc" 301
check "a failed review job keeps a REQUEST CHANGES result as a review rejection (failure status)" \
  eval 'contains "$(gh_eval "d[\"comments\"][0][\"body\"]")" "## Code review: REQUEST CHANGES" && [ "$(gh_eval "d[\"statuses\"][0][\"state\"]")" = failure ]'
reset_gh
BACKEND=mock publish "$WORK/art-approved" 302
MOCKBODY="$(gh_eval 'd["comments"][0]["body"]')"
check "mock-backend runs use the gencr/review-mock context and say they are not a code review" \
  eval '[ "$(gh_eval "d[\"statuses\"][0][\"context\"]")" = gencr/review-mock ] && contains "$(gh_eval "d[\"statuses\"][0][\"description\"]")" "MOCK pipeline test, not a code review" && contains "$MOCKBODY" "MOCK reviewers" && contains "$MOCKBODY" "does not approve this pull request" && contains "$MOCKBODY" "\"backend\": \"mock\""'
check "a mock run never sets the real gencr/review status" eval '[ "$(gh_eval "[s for s in d[\"statuses\"] if s[\"context\"] == \"gencr/review\"]")" = "[]" ]'

cp -R "$WORK/art-rc" "$WORK/art-tampered"
echo '{}' > "$WORK/art-tampered/code-review-pr-7/metadata.json"
reset_gh
publish "$WORK/art-tampered" 106
check "a tampered package is treated as an infrastructure failure, not a review result" \
  eval 'contains "$(gh_eval "d[\"comments\"][0][\"body\"]")" "INFRASTRUCTURE FAILURE" && [ "$(gh_eval "d[\"statuses\"][0][\"state\"]")" = error ]'

reset_gh
python3 - "$GH_STATE" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1])); s["fail_paths"] = ["/statuses/"]; json.dump(s, open(sys.argv[1], "w"))
EOF
publish "$WORK/art-approved" 107
check "a failed status update makes publishing fail visibly" eval '[ "$STATUS" -ne 0 ] && contains "$ERR" "publishing failed"'

# ── find-previous ──────────────────────────────────────────────────────────────

seed_previous() { # run-id artifact-dir [workflow-path] [expired] [login] [marker-artifact-dir] [marker-backend]
  python3 - "$GH_STATE" "$1" "$2" "${3:-.github/workflows/gencr-review.yml}" "${4:-false}" "${5:-github-actions[bot]}" "$HEAD_SHA" "${6:-$2}" "${7:-mock}" <<'EOF'
import json, sys
path, run_id, art, wf, expired, login, sha, marker_art, backend = sys.argv[1:10]
s = json.load(open(path))
md = json.load(open(marker_art + "/code-review-pr-7/metadata.json"))
marker = {"run_id": int(run_id), "run_attempt": 1, "reviewed_sha": sha, "review_id": md.get("run_id"), "outcome": "REQUEST CHANGES", "backend": backend}
s["comments"].append({"id": 50, "issue": 7, "user": {"login": login},
                      "body": "<!-- gencr-review:v1 " + json.dumps(marker) + " -->\nsummary"})
s["runs"][run_id] = {"path": wf, "repository": {"full_name": "acme/app"}, "status": "completed"}
s["artifacts"][run_id] = [{"name": "code-review-pr-7", "expired": expired == "true"}]
s["downloads"][run_id + "/code-review-pr-7"] = art + "/code-review-pr-7"
json.dump(s, open(path, "w"))
EOF
}
reset_gh
seed_previous 200 "$WORK/art-rc"
run_ci find-previous --repo "$GH_REPO_NAME" --pr-number 7 --backend mock --out "$WORK/prev-ok"
check "find-previous downloads and verifies the published review package" \
  eval '[ "$STATUS" -eq 0 ] && [ -f "$WORK/prev-ok/manifest.json" ] && [ -f "$WORK/prev-ok/findings.json" ]'
(cd "$TARGET" && echo 'x = 2' > app.py && git commit -qam fix)
(cd "$TARGET" && CODEREVIEW_BASE_BRANCH=main "$REPO/bin/gencr" pr-7 --pr-number=7 --codex=attack --incremental \
  --previous="$WORK/prev-ok" --output-dir="$WORK/out-inc" --print) > "$WORK/inc-prompt" 2> "$WORK/inc-err"
check "the downloaded package is accepted by gencr --incremental" \
  eval 'grep -q "follow-up to review" "$WORK/inc-prompt"'
(cd "$TARGET" && git reset -q --hard HEAD~1)
prev_rejects() { local desc="$1" expect="$2"; shift 2; reset_gh; "$@"; rm -rf "$WORK/prev-x"
  run_ci find-previous --repo "$GH_REPO_NAME" --pr-number 7 --backend "${FIND_BACKEND:-mock}" --out "$WORK/prev-x"
  if [ "$STATUS" -ne 0 ] && contains "$ERR" "$expect" && contains "$ERR" "Run a fresh review"; then ok "find-previous rejects $desc"
  else not_ok "find-previous rejects $desc" "$ERR"; fi; }
prev_rejects "a PR without a previous review" "no previous gencr review comment" true
prev_rejects "a marker written by a user" "no previous gencr review comment" seed_previous 201 "$WORK/art-rc" .github/workflows/gencr-review.yml false mallory
prev_rejects "a run of another workflow" "is not a completed" seed_previous 202 "$WORK/art-rc" .github/workflows/evil.yml
prev_rejects "an expired artifact" "missing or expired" seed_previous 203 "$WORK/art-rc" .github/workflows/gencr-review.yml true
prev_rejects "a package that does not match the published review" "does not match the published review" seed_previous 204 "$WORK/art-approved" .github/workflows/gencr-review.yml false github-actions[bot] "$WORK/art-rc"
cp -R "$WORK/art-rc" "$WORK/art-link"
ln -s /etc/passwd "$WORK/art-link/code-review-pr-7/extra"
prev_rejects "a package containing a symlink" "refusing symlink" seed_previous 205 "$WORK/art-link"
FIND_BACKEND=live
prev_rejects "a mock review as the baseline of a live review" "used the mock reviewer backend, not live" seed_previous 206 "$WORK/art-rc"
FIND_BACKEND=mock

# ── workflow files ─────────────────────────────────────────────────────────────

WF="$REPO/.github/workflows/gencr-review.yml"
check "the review workflow is triggered only by workflow_dispatch" \
  py 'import re, sys; t = open(sys.argv[1]).read(); on = t.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
keys = re.findall(r"^  ([a-z_]+):", on, re.M); sys.exit(0 if keys == ["workflow_dispatch"] else 1)' "$WF"
check "the review workflow references no secrets and no paid-provider credentials" \
  eval '! grep -nE "secrets\.|ANTHROPIC_API_KEY|OPENAI_API_KEY|AWS_|aws-actions|id-token" "$WF"'
check "the reviewer backend offers only the mock CLIs" \
  py 'import sys; t = open(sys.argv[1]).read(); b = t.split("reviewer_backend:", 1)[1].split("retention_days:", 1)[0]
sys.exit(0 if "options: [mock]" in b else 1)' "$WF"
check "workflow-level permissions are empty; the review job has no write permission" \
  py 'import sys; t = open(sys.argv[1]).read(); r = t.split("\n  review:\n", 1)[1].split("\n  publish:\n", 1)[0]
p = r.split("permissions:", 1)[1].split("concurrency:", 1)[0]
sys.exit(0 if "\npermissions: {}\n" in t and "write" not in p else 1)' "$WF"
check "the publish job never checks out pull request code" \
  py 'import sys; t = open(sys.argv[1]).read(); p = t.split("\n  publish:\n", 1)[1]
sys.exit(0 if "context.outputs" not in p and p.count("actions/checkout") == 1 and "ref: ${{ github.sha }}" in p else 1)' "$WF"
check "every action is pinned to a full commit SHA" \
  eval '! grep -hE "^ *(- )?uses: " "$WF" "$REPO/.github/workflows/gencr-tests.yml" | grep -vqE "uses: [a-z-]+/[a-z-]+@[0-9a-f]{40} # v"'
check "workflow inputs are never interpolated into run scripts" \
  py 'import re, sys; t = open(sys.argv[1]).read()
blocks = re.findall(r"run: [|>]?\n((?:          .*\n)+)|run: (.*)\n", t)
sys.exit(1 if any("${{" in (a or b) for a, b in blocks) else 0)' "$WF"
check "a trust job with no permissions and no checkout gates every other job" \
  py 'import sys; t = open(sys.argv[1]).read(); j = t.split("\n  trust:\n", 1)[1].split("\n  review:\n", 1)[0]
r = t.split("\n  review:\n", 1)[1].split("\n  publish:\n", 1)[0]; p = t.split("\n  publish:\n", 1)[1]
ok = ("permissions: {}" in j and "uses:" not in j and "refs/heads/$DEFAULT_BRANCH" in j and "needs: trust" in r
      and "needs: [trust, review]" in p and "if: always() && needs.trust.result == '"'"'success'"'"'" in p)
sys.exit(0 if ok else 1)' "$WF"
check "both jobs serialize per pull request without cancelling runs" \
  eval '[ "$(grep -c "cancel-in-progress: false" "$WF")" -eq 2 ] && grep -q "group: gencr-publish-" "$WF" && grep -q "group: gencr-review-" "$WF"'
check "PR checkouts never persist credentials" eval '[ "$(grep -c "persist-credentials: false" "$WF")" -eq 3 ]'
check "the test workflow needs no secrets" eval '! grep -q "secrets\." "$REPO/.github/workflows/gencr-tests.yml"'
# The workflow's own "Run gencr" script, executed as the runner would (mock reviewers on PATH).
python3 - "$WF" > "$WORK/run-step.sh" <<'EOF'
import sys
text = open(sys.argv[1]).read()
block = text.split("- name: Run gencr (headless, read-only reviewers)", 1)[1].split("        run: |\n", 1)[1]
lines = []
for line in block.splitlines():
    if not line.startswith("          "):
        break
    lines.append(line[10:])
print("\n".join(lines))
EOF
run_step() { # scope primary adversary [claude_model]
  local ws="$WORK/ws-$1-$2-$3"
  rm -rf "$ws"; mkdir -p "$ws/tmp"; ln -s "$REPO" "$ws/tools"; ln -s "$TARGET" "$ws/target"
  reset_gh open "$(git -C "$TARGET" rev-parse HEAD)"
  (cd "$TARGET" && env GITHUB_WORKSPACE="$ws" RUNNER_TEMP="$ws/tmp" GITHUB_OUTPUT="$ws/output" PR_NUMBER=7 VERSION="" \
     GITHUB_REPOSITORY=acme/app GITHUB_EVENT_NAME=workflow_dispatch EVENT_ACTION="" BROKER_TOKEN=broker-secret \
     HEAD_SHA="$(git -C "$TARGET" rev-parse HEAD)" \
     SCOPE="$1" PRIMARY="$2" ADVERSARY="$3" CLAUDE_MODEL="${4:-}" CODEX_MODEL="" TIMEOUT_MINUTES=1 \
     CODEREVIEW_BASE_BRANCH=main HOME="$ws/home" bash -e "$WORK/run-step.sh") > "$ws/log" 2>&1
  STEP_DIR="$ws"; cp "$ws/log" "$WORK/last-run-step.log"
}
run_step fresh codex none
check "workflow run step: single Codex review produces a package and records exit 0" \
  eval 'grep -qx "exit_code=0" "$STEP_DIR/output" && [ "$(python3 -c "import json,glob; print(json.load(open(glob.glob(\"$STEP_DIR/tmp/gencr-out/review-*/metadata.json\")[0]))[\"models\"][\"claude\"][\"display\"])")" = "Not used" ]'
run_step fresh codex claude opus
check "workflow run step: Codex-first adversarial review with a Claude model override" \
  eval 'grep -qx "exit_code=0" "$STEP_DIR/output" && grep -q "Claude Model: opus" "$STEP_DIR"/tmp/gencr-out/review-*/full-report.md && grep -q "Primary Reviewer: Codex" "$STEP_DIR"/tmp/gencr-out/review-*/full-report.md'
check "workflow run step writes nothing inside the PR checkout" eval '[ -z "$(git -C "$TARGET" status --porcelain --untracked-files=all)" ]'
ws="$WORK/ws-historical"
mkdir -p "$ws/tmp"; ln -s "$REPO" "$ws/tools"
git -C "$HIST" checkout -q --detach "$H_B"
reset_gh merged-closed "$H_B"
(cd "$HIST" && env GITHUB_WORKSPACE="$ws" RUNNER_TEMP="$ws/tmp" GITHUB_OUTPUT="$ws/output" PR_NUMBER=7 VERSION="" \
   GITHUB_REPOSITORY=acme/app GITHUB_EVENT_NAME=workflow_dispatch EVENT_ACTION="" BROKER_TOKEN=broker-secret HEAD_SHA="$H_B" \
   SCOPE=fresh PRIMARY=claude ADVERSARY=none CLAUDE_MODEL="" CODEX_MODEL="" TIMEOUT_MINUTES=1 \
   SCOPE_ARG="--range=$H_O..$H_B" CODEREVIEW_BASE_BRANCH=main HOME="$ws/home" bash -e "$WORK/run-step.sh") > "$ws/log" 2>&1
check "workflow run step passes the resolved historical scope to gencr" \
  eval 'grep -qx "exit_code=0" "$ws/output" && [ "$(python3 -c "import json,glob; print(json.load(open(glob.glob(\"$ws/tmp/gencr-out/review-*/metadata.json\")[0]))[\"identity\"][\"scope_method\"])")" = explicit-range ]'
check "the scope step runs only for fresh reviews and only its validated output reaches gencr" \
  py 'import sys; t = open(sys.argv[1]).read(); b = t.split("- name: Resolve the review scope of a merged pull request (fresh)", 1)[1].split("- name:", 1)[0]
sys.exit(0 if "if: inputs.scope == '"'"'fresh'"'"'" in b and "historical-scope" in b and "SCOPE_ARG: ${{ steps.scope.outputs.scope_arg }}" in t else 1)' "$WF"

if command -v docker >/dev/null 2>&1 && docker image inspect rhysd/actionlint:latest >/dev/null 2>&1; then
  check "actionlint accepts both workflows" docker run --rm -v "$REPO:/repo:ro" -w /repo rhysd/actionlint:latest -no-color
fi

# ── Draft-PR eligibility: before the run, before EVERY reviewer launch, and in publishing ──

# classify() on live PR states and events (the gate's rules), without GitHub.
cat > "$WORK/classify.py" <<'EOF'
import importlib.machinery, json, sys
ci = importlib.machinery.SourceFileLoader("gencr_ci", sys.argv[1]).load_module()
head, other = sys.argv[2], sys.argv[3]
def pr(**changes):
    value = {"number": 7, "state": "open", "merged": False, "draft": False, "head": {"sha": head},
             "base": {"repo": {"full_name": "acme/app"}}}
    value.update(changes)
    return value
missing = pr(); del missing["draft"]
cases = {
    "dispatch, ready": (pr(), "workflow_dispatch", ""),
    "dispatch, draft": (pr(draft=True), "workflow_dispatch", ""),
    "synchronize on a draft": (pr(draft=True), "pull_request", "synchronize"),
    "synchronize, ready": (pr(), "pull_request", "synchronize"),
    "opened as a draft": (pr(draft=True), "pull_request", "opened"),
    "ready_for_review, live ready": (pr(), "pull_request", "ready_for_review"),
    "ready_for_review, live still draft": (pr(draft=True), "pull_request", "ready_for_review"),
    "push event": (pr(), "push", ""),
    "draft field missing": (missing, "workflow_dispatch", ""),
    "draft field not a boolean": (pr(draft="false"), "workflow_dispatch", ""),
    "stale head": (pr(head={"sha": other}), "workflow_dispatch", ""),
    "other pull request": (pr(number=8), "workflow_dispatch", ""),
    "other repository": (pr(base={"repo": {"full_name": "evil/app"}}), "workflow_dispatch", ""),
    "not an object": (["x"], "workflow_dispatch", ""),
    "merged (historical)": (pr(state="closed", merged=True), "workflow_dispatch", ""),
    "closed unmerged": (pr(state="closed"), "workflow_dispatch", ""),
    "state missing": (pr(state=None), "workflow_dispatch", ""),
    "state missing, merged": (pr(state=None, merged=True), "workflow_dispatch", ""),
    "state unrecognized": (pr(state="locked"), "workflow_dispatch", ""),
    "closed, merged missing": (pr(state="closed", merged=None), "workflow_dispatch", ""),
    "open, merged missing": (pr(merged=None), "workflow_dispatch", ""),
    "merged not a boolean": (pr(state="closed", merged="true"), "workflow_dispatch", ""),
    "open and merged (contradictory)": (pr(merged=True), "workflow_dispatch", ""),
    "draft, state missing": (pr(draft=True, state=None), "workflow_dispatch", ""),
}
print(json.dumps({name: ci.classify(value, "acme/app", 7, event, action, head)[0]
                  for name, (value, event, action) in cases.items()}))
EOF
python3 -B "$WORK/classify.py" "$CI" "$HEAD_SHA" "$OTHER_SHA" > "$WORK/classify.json"
classified() { py 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$WORK/classify.json" "$1"; }
for case in "dispatch, ready:ELIGIBLE" "ready_for_review, live ready:ELIGIBLE" "merged (historical):ELIGIBLE" \
            "dispatch, draft:INELIGIBLE" "synchronize on a draft:INELIGIBLE" "opened as a draft:INELIGIBLE" \
            "ready_for_review, live still draft:INELIGIBLE" "synchronize, ready:INELIGIBLE" "push event:INELIGIBLE" \
            "closed unmerged:INELIGIBLE" "draft field missing:UNKNOWN" "draft field not a boolean:UNKNOWN" \
            "stale head:UNKNOWN" "other pull request:UNKNOWN" "other repository:UNKNOWN" "not an object:UNKNOWN" \
            "state missing:UNKNOWN" "state missing, merged:UNKNOWN" "state unrecognized:UNKNOWN" \
            "closed, merged missing:UNKNOWN" "open, merged missing:UNKNOWN" "merged not a boolean:UNKNOWN" \
            "open and merged (contradictory):UNKNOWN" "draft, state missing:INELIGIBLE"; do
  check "eligibility: ${case%:*} -> ${case##*:}" [ "$(classified "${case%:*}")" = "${case##*:}" ]
done

# The one-shot gate before the run: exit 0 eligible, 3 confirmed ineligible (+ skip record), 4 unknown.
reset_gh open "$HEAD_SHA" false
run_ci eligibility --repo acme/app --pr-number 7 --event workflow_dispatch --expected-sha "$HEAD_SHA" --skip-record "$WORK/skip0.json"
check "gate: a ready PR is eligible (exit 0), no skip record" eval '[ "$STATUS" -eq 0 ] && contains "$OUT" "eligibility=ELIGIBLE" && [ ! -e "$WORK/skip0.json" ]'
reset_gh open "$HEAD_SHA" true
run_ci eligibility --repo acme/app --pr-number 7 --event workflow_dispatch --expected-sha "$HEAD_SHA" --skip-record "$WORK/skip1.json"
check "gate: a draft PR is a confirmed skip (exit 3) with a skip record" \
  eval '[ "$STATUS" -eq 3 ] && contains "$OUT" "eligibility=INELIGIBLE" && [ "$(py "import json,sys; print(json.load(open(sys.argv[1]))[\"kind\"])" "$WORK/skip1.json")" = ineligible ]'
reset_gh open "$HEAD_SHA" missing
run_ci eligibility --repo acme/app --pr-number 7 --event workflow_dispatch --expected-sha "$HEAD_SHA" --skip-record "$WORK/skip2.json"
check "gate: missing draft status is an error (exit 4), never a skip" eval '[ "$STATUS" -eq 4 ] && [ ! -e "$WORK/skip2.json" ]'
reset_gh open "$HEAD_SHA" false
py 'import json,sys; d=json.load(open(sys.argv[1])); d["fail_paths"]=["pulls/7"]; json.dump(d, open(sys.argv[1], "w"))' "$GH_STATE"
run_ci eligibility --repo acme/app --pr-number 7 --event workflow_dispatch --expected-sha "$HEAD_SHA"
check "gate: an API failure is an error (exit 4)" eval '[ "$STATUS" -eq 4 ] && contains "$OUT" "cannot read the pull request"'

# Before EVERY reviewer launch: the engine asks the broker; flipping the live PR to draft stops further launches.
start_broker() { # expected-sha
  BROKER_DIR="$(mktemp -d /tmp/gencr-broker-test.XXXXXX)"
  GH_TOKEN=broker-only "$CI" eligibility-broker --repo acme/app --pr-number 7 --event workflow_dispatch \
    --expected-sha "$1" --socket "$BROKER_DIR/s" --ready "$BROKER_DIR/ready" > "$WORK/broker.log" 2>&1 &
  BROKER=$!
  for _ in $(seq 50); do [ -f "$BROKER_DIR/ready" ] && break; sleep 0.1; done
}
stop_broker() { kill "$BROKER" 2>/dev/null; wait "$BROKER" 2>/dev/null; rm -f "$BROKER_DIR/s" "$BROKER_DIR/ready"; rmdir "$BROKER_DIR"; }
ci_review() { # out-dir [extra gencr args] — gencr as the run step runs it: socket set, tokens stripped
  local out="$1"
  shift
  rm -rf "$WORK/rstate"; mkdir -p "$WORK/rstate/responses"
  (cd "$TARGET" && env GH_TOKEN=must-not-reach-reviewers MOCK_STATE="$WORK/rstate" GENCR_ELIGIBILITY_SOCKET="$BROKER_DIR/s" \
     CODEREVIEW_BASE_BRANCH=main GENCR_REVIEW_COMMENT=off "$REPO/bin/gencr" pr-7 --pr-number=7 --fresh --output-dir="$out" "$@") \
     > "$WORK/rout" 2> "$WORK/rerr"
  RSTATUS=$?; RCALLS="$(cat "$WORK/rstate/count" 2>/dev/null || echo 0)"
}
reset_gh open "$HEAD_SHA" false
start_broker "$HEAD_SHA"
ci_review "$WORK/elig-ok" --codex=attack
check "an eligible PR: every reviewer launch is checked and allowed (2 launches, 2 broker checks)" \
  eval '[ "$RSTATUS" -eq 0 ] && [ "$RCALLS" -eq 2 ] && [ "$(grep -c "broker: ELIGIBLE" "$WORK/broker.log")" -eq 2 ]'
check "reviewer processes never receive GH_TOKEN or the eligibility socket" \
  eval '! grep -q "^GH_TOKEN=" "$WORK/rstate/call-1.env" && ! grep -q "^GENCR_ELIGIBILITY" "$WORK/rstate/call-1.env" && ! grep -q "^GH_TOKEN=" "$WORK/rstate/call-2.env"'
stop_broker
reset_gh open "$HEAD_SHA" false
start_broker "$HEAD_SHA"
rm -rf "$WORK/rstate"; mkdir -p "$WORK/rstate/responses"
cat > "$WORK/flip.sh" <<EOF
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["prs"]["7"]["draft"]=True; json.dump(d, open(sys.argv[1], "w"))' "$GH_STATE"
EOF
ci_review_with_hook() { # out-dir hook-file [args]
  local out="$1" hook="$2"
  shift 2
  rm -rf "$WORK/rstate"; mkdir -p "$WORK/rstate/responses"; cp "$hook" "$WORK/rstate/hook-1"
  (cd "$TARGET" && env MOCK_STATE="$WORK/rstate" GENCR_ELIGIBILITY_SOCKET="$BROKER_DIR/s" CODEREVIEW_BASE_BRANCH=main \
     GENCR_REVIEW_COMMENT=off "$REPO/bin/gencr" pr-7 --pr-number=7 --fresh --output-dir="$out" "$@") > "$WORK/rout" 2> "$WORK/rerr"
  RSTATUS=$?; RCALLS="$(cat "$WORK/rstate/count" 2>/dev/null || echo 0)"
}
ci_review_with_hook "$WORK/elig-flip" "$WORK/flip.sh" --codex=attack
FLIP_PKG="$(ls -d "$WORK/elig-flip"/review-*)"
check "PR converted to draft after the first reviewer: the second launch is refused, no further reviewer runs" \
  eval '[ "$RSTATUS" -eq 20 ] && [ "$RCALLS" -eq 1 ] && contains "$(cat "$WORK/rerr")" "the pull request is not eligible for review: pull request #7 is a draft" &&
        [ "$(py "import json,sys; d=json.load(open(sys.argv[1])); print(d[\"eligibility\"], d[\"outcome\"])" "$FLIP_PKG/metadata.json")" = "ineligible INCOMPLETE" ]'
stop_broker
reset_gh open "$HEAD_SHA" true
start_broker "$HEAD_SHA"
ci_review "$WORK/elig-draft"
check "PR already a draft at the first launch (after checkout): zero reviewer calls" eval '[ "$RSTATUS" -eq 20 ] && [ "$RCALLS" -eq 0 ]'
stop_broker
reset_gh open "$HEAD_SHA" missing
start_broker "$HEAD_SHA"
ci_review "$WORK/elig-unknown"
check "missing live draft status at a launch: zero calls, eligibility unknown (an error, not a skip)" \
  eval '[ "$RSTATUS" -eq 20 ] && [ "$RCALLS" -eq 0 ] && [ "$(py "import json,sys; print(json.load(open(sys.argv[1]))[\"eligibility\"])" "$(ls -d "$WORK/elig-unknown"/review-*)/metadata.json")" = unknown ]'
stop_broker
# Ambiguous live state/merged information at a launch: an error with zero reviewer calls, never a launch or a skip.
pr_edit() { py "import json,sys; d=json.load(open(sys.argv[1])); pr=d[\"prs\"][\"7\"]; $1; json.dump(d, open(sys.argv[1], \"w\"))" "$GH_STATE"; }
for edit in 'pr["state"] = None; pr["merged"] = True' 'pr["merged"] = True' 'pr["state"] = "closed"; del pr["merged"]'; do
  reset_gh open "$HEAD_SHA" false; pr_edit "$edit"
  start_broker "$HEAD_SHA"
  rm -rf "$WORK/elig-ambiguous"
  ci_review "$WORK/elig-ambiguous" --codex=attack
  check "ambiguous live PR state ($edit) at a launch: zero calls, unknown, logged by the broker" \
    eval '[ "$RSTATUS" -eq 20 ] && [ "$RCALLS" -eq 0 ] && grep -q "broker: UNKNOWN" "$WORK/broker.log" && ! grep -q "broker: ELIGIBLE" "$WORK/broker.log" &&
          [ "$(py "import json,sys; print(json.load(open(sys.argv[1]))[\"eligibility\"])" "$(ls -d "$WORK/elig-ambiguous"/review-*)/metadata.json")" = unknown ]'
  stop_broker
done
reset_gh open "$HEAD_SHA" false; pr_edit 'pr["state"] = None; pr["merged"] = True'
run_ci eligibility --repo acme/app --pr-number 7 --event workflow_dispatch --expected-sha "$HEAD_SHA" --skip-record "$WORK/skip3.json"
check "gate: ambiguous state/merged information is an error (exit 4), never a skip record" eval '[ "$STATUS" -eq 4 ] && [ ! -e "$WORK/skip3.json" ]'
reset_gh open "$OTHER_SHA" false
start_broker "$HEAD_SHA"
ci_review "$WORK/elig-stale"
check "stale head (the PR moved after checkout): zero calls, unknown" eval '[ "$RSTATUS" -eq 20 ] && [ "$RCALLS" -eq 0 ] && grep -q "stale" "$WORK/rerr"'
stop_broker
# A broker that answers garbage, and no broker at all.
BROKER_DIR="$(mktemp -d /tmp/gencr-broker-test.XXXXXX)"
python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)
open(sys.argv[2], "w").write("ready")
while True:
    c, _ = s.accept(); c.recv(4096); c.sendall(b"{\"disposition\": \"ELIGIBLE\"}\n"); c.close()' "$BROKER_DIR/s" "$BROKER_DIR/ready" &
BROKER=$!
for _ in $(seq 50); do [ -f "$BROKER_DIR/ready" ] && break; sleep 0.1; done
ci_review "$WORK/elig-garbage"
check "a malformed broker answer (no reason) is unknown: zero calls" eval '[ "$RSTATUS" -eq 20 ] && [ "$RCALLS" -eq 0 ] && grep -q "malformed answer" "$WORK/rerr"'
stop_broker
BROKER_DIR="$WORK/no-such-broker"
ci_review "$WORK/elig-none"
check "an unreachable broker is unknown: zero calls" eval '[ "$RSTATUS" -eq 20 ] && [ "$RCALLS" -eq 0 ] && grep -q "did not answer" "$WORK/rerr"'

# Packaging and publishing: a skip or a no-new-review result writes nothing to the PR; forged records fail closed.
seed_rc_comment() { # existing REQUEST CHANGES bot comment and status
  py 'import json,sys
d = json.load(open(sys.argv[1]))
d["comments"] = [{"id": 900, "issue": 7, "user": {"login": "github-actions[bot]"},
                  "body": "<!-- gencr-review:v1 {\"outcome\": \"REQUEST CHANGES\", \"run_id\": 5, \"run_attempt\": 1} -->\nREQUEST CHANGES"}]
d["statuses"] = [{"state": "failure", "context": "gencr/review-mock", "sha": sys.argv[2]}]
json.dump(d, open(sys.argv[1], "w"))' "$GH_STATE" "$HEAD_SHA"
  cp "$GH_STATE" "$WORK/gh-before.json"
}
publish_disposition() { # artifact-dir
  run_ci publish --repo acme/app --pr-number 7 --run-id 9 --run-attempt 1 --package "$1" --run-url https://x/run \
    --artifact-url https://x/art --retention-days 7 --reviewed-sha "$HEAD_SHA" --review-result success --backend mock
}
unchanged_pr() { py 'import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); sys.exit(0 if (a["comments"], a["statuses"]) == (b["comments"], b["statuses"]) else 1)' "$WORK/gh-before.json" "$GH_STATE" && ! grep -qE "^api -X (POST|PATCH)" "$GH_STATE.calls"; }
disposition_of() { py 'import json,sys; print(json.load(open(sys.argv[1]))["disposition"])' "$1/code-review-pr-7/ci-disposition.json"; }
# A genuine covered decision: the previous RC package already reviewed HEAD.
PREV="$(ls -d "$WORK/out-rc"/review-*)"
mkdir -p "$WORK/noop-out"
(cd "$TARGET" && CODEREVIEW_BASE_BRANCH=main "$REPO/bin/gencr" pr-7 --pr-number=7 --incremental --previous="$PREV" --output-dir="$WORK/noop-out" --codex=attack) > /dev/null 2> "$WORK/noop.err"
check "covered HEAD in CI: no reviewer, exit 0, a no-review receipt in the fresh output directory" \
  eval '[ -f "$WORK/noop-out/no-review.json" ] && ! ls -d "$WORK/noop-out"/review-* >/dev/null 2>&1 && grep -q "no new review needed" "$WORK/noop.err"'
reset_gh open "$HEAD_SHA" false; seed_rc_comment
run_ci package --output-dir "$WORK/noop-out" --pr-number 7 --backend mock --out "$WORK/art-noop" --exit-code 0 --expected-head "$HEAD_SHA" --previous "$PREV"
publish_disposition "$WORK/art-noop"
check "covered HEAD: disposition no-review; publish writes no comment and no status (the REQUEST CHANGES stays)" \
  eval '[ "$(disposition_of "$WORK/art-noop")" = no-review ] && [ "$STATUS" -eq 0 ] && contains "$OUT" "outcome=NO NEW REVIEW" && unchanged_pr'
forged() { # description python-edit-of-receipt [package-args...]
  local desc="$1" edit="$2"
  shift 2
  rm -rf "$WORK/forge-out" "$WORK/art-forge"; mkdir -p "$WORK/forge-out"; cp "$WORK/noop-out/no-review.json" "$WORK/forge-out/"
  py "import json,sys; p=sys.argv[1]; r=json.load(open(p)); $edit; json.dump(r, open(p, 'w'))" "$WORK/forge-out/no-review.json"
  reset_gh open "$HEAD_SHA" false; seed_rc_comment
  run_ci package --output-dir "$WORK/forge-out" --pr-number 7 --backend mock --out "$WORK/art-forge" --expected-head "$HEAD_SHA" --previous "$PREV" "$@"
  publish_disposition "$WORK/art-forge"
  if [ "$(disposition_of "$WORK/art-forge")" = failure ] && ! py 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(s["state"] == "success" for s in d["statuses"]) else 1)' "$GH_STATE" \
     && grep -qE "^api -X POST repos/acme/app/statuses" "$GH_STATE.calls"; then ok "forged no-review receipt ($desc): infrastructure failure, never silent, never success"
  else not_ok "forged no-review receipt ($desc)" "$(disposition_of "$WORK/art-forge") $(tail -n 2 "$GH_STATE.calls")"; fi
}
forged "previous verdict changed" 'r["previous_outcome"] = "APPROVED"' --exit-code 0
forged "other previous review" 'r["previous_id"] = "someone-else"' --exit-code 0
forged "other head" 'r["head_sha"] = "0" * 40' --exit-code 0
forged "extra field" 'r["note"] = "x"' --exit-code 0
forged "engine did not exit 0" 'pass' --exit-code 20
rm -rf "$WORK/link-out"; mkdir -p "$WORK/link-out"; ln -s "$WORK/noop-out/no-review.json" "$WORK/link-out/no-review.json"
reset_gh open "$HEAD_SHA" false; seed_rc_comment
run_ci package --output-dir "$WORK/link-out" --pr-number 7 --backend mock --out "$WORK/art-link2" --exit-code 0 --expected-head "$HEAD_SHA" --previous "$PREV"
check "a symlinked no-review receipt is refused (failure)" [ "$(disposition_of "$WORK/art-link2")" = failure ]
rm -rf "$WORK/mix-out"; mkdir -p "$WORK/mix-out"; cp "$WORK/noop-out/no-review.json" "$WORK/mix-out/"; cp -R "$PREV" "$WORK/mix-out/"
run_ci package --output-dir "$WORK/mix-out" --pr-number 7 --backend mock --out "$WORK/art-mix" --exit-code 0 --expected-head "$HEAD_SHA" --previous "$PREV"
check "a receipt next to a review package is refused (failure)" [ "$(disposition_of "$WORK/art-mix")" = failure ]
# Confirmed ineligible before the run, and during it.
rm -rf "$WORK/skip-out"; mkdir -p "$WORK/skip-out"; cp "$WORK/skip1.json" "$WORK/skip-out/ineligible.json"
reset_gh open "$HEAD_SHA" true; seed_rc_comment
run_ci package --output-dir "$WORK/skip-out" --pr-number 7 --backend mock --out "$WORK/art-skip" --expected-head "$HEAD_SHA"
publish_disposition "$WORK/art-skip"
check "a draft PR skipped before the run: no comment, no status, previous state untouched, not an approval" \
  eval '[ "$(disposition_of "$WORK/art-skip")" = skipped ] && contains "$OUT" "outcome=SKIPPED" && contains "$OUT" "not an approval" && unchanged_pr'
reset_gh open "$HEAD_SHA" true; seed_rc_comment
run_ci package --output-dir "$WORK/elig-flip" --pr-number 7 --backend mock --out "$WORK/art-flip" --exit-code 20 --expected-head "$HEAD_SHA"
publish_disposition "$WORK/art-flip"
check "a PR that became a draft mid-review: the partial package is skipped, nothing published" \
  eval '[ "$(disposition_of "$WORK/art-flip")" = skipped ] && unchanged_pr'
reset_gh open "$HEAD_SHA" false; seed_rc_comment
run_ci package --output-dir "$WORK/elig-unknown" --pr-number 7 --backend mock --out "$WORK/art-unknown" --exit-code 20 --expected-head "$HEAD_SHA"
run_ci publish --repo acme/app --pr-number 7 --run-id 9 --run-attempt 1 --package "$WORK/art-unknown" --run-url https://x/run \
  --artifact-url https://x/art --retention-days 7 --reviewed-sha "$HEAD_SHA" --review-result failure --backend mock
check "unknown eligibility mid-review: published as an error (INCOMPLETE), never success" \
  eval 'py "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"statuses\"][-1][\"state\"] == \"error\" else 1)" "$GH_STATE"'

# The whole workflow, end to end in step order (tests/workflow_sim.py applies every step's real `if:` and the implicit
# success() rule): a confirmed Draft PR is skipped even when review preparation would fail, and publishes nothing.
simulate() { # name scope — runs trust, review and publish against the current mock GitHub state
  SIM="$WORK/sim-$1"
  rm -rf "$SIM"; mkdir -p "$SIM"
  [ "$(git -C "$TARGET" rev-parse HEAD)" = "$HEAD_SHA" ] || { echo "simulate: target is not at the PR head" >&2; return 1; }
  python3 -B "$REPO/tests/workflow_sim.py" "$WF" "$SIM" "$REPO" "$TARGET" \
    "{\"pr_number\": \"7\", \"version\": \"\", \"scope\": \"$2\", \"primary\": \"claude\", \"adversary\": \"codex\",
      \"claude_model\": \"\", \"codex_model\": \"\", \"reviewer_backend\": \"mock\", \"retention_days\": \"30\",
      \"reviewer_timeout_minutes\": \"20\"}" > "$SIM/trace.json" 2> "$SIM/sim.err"
}
sim_get() { py 'import json,sys
d = json.load(open(sys.argv[1]))
def step(job, name):
    return [s for s in d[job]["steps"] if s["name"].startswith(name)][0]
print(eval(sys.argv[2]))' "$SIM/trace.json" "$1"; }
seed_status() { py 'import json,sys; d=json.load(open(sys.argv[1])); d["statuses"].append({"state": "failure", "context": "gencr/review-mock", "sha": sys.argv[2]}); json.dump(d, open(sys.argv[1], "w"))' "$GH_STATE" "$HEAD_SHA"; }
snapshot_pr() { cp "$GH_STATE" "$WORK/gh-before.json"; : > "$GH_STATE.calls"; }
draft_skipped() { # description
  if [ "$(sim_get 'step("review", "Check pull request eligibility")["outputs"].get("eligibility")')" = INELIGIBLE ] &&
     [ "$(sim_get '[s["name"][:24] for s in d["review"]["steps"] if s["ran"] and s["name"].startswith(("Check out the pull", "Verify", "Resolve the review scope", "Use the mock", "Fetch the previous", "Run gencr"))]')" = "[]" ] &&
     [ "$(sim_get 'd["review"]["result"]')" = success ] &&
     [ "$(sim_get 'step("publish", "Publish the PR comment")["outputs"].get("outcome")')" = SKIPPED ] &&
     [ "$(sim_get 'step("publish", "Report the review outcome")["status"]')" = 0 ] && unchanged_pr; then ok "$1"
  else not_ok "$1" "$(sim_get '[(s["name"][:30], s["ran"], s.get("status")) for s in d["review"]["steps"] + d["publish"]["steps"]]') $(tail -n 3 "$GH_STATE.calls")"; fi
}
reset_gh open "$HEAD_SHA" true; seed_rc_comment; snapshot_pr
simulate draft-incremental-none incremental
draft_skipped "workflow: Draft PR + incremental + no previous review: skipped before find-previous; no comment, no status"
reset_gh open "$HEAD_SHA" true; seed_previous 203 "$WORK/art-rc" .github/workflows/gencr-review.yml true; seed_status; snapshot_pr
simulate draft-incremental-expired incremental
draft_skipped "workflow: Draft PR + incremental + expired previous artifact: skipped; the REQUEST CHANGES comment and status stay"
reset_gh open "$HEAD_SHA" true; seed_rc_comment; snapshot_pr
simulate draft-fresh fresh
draft_skipped "workflow: Draft PR + fresh: skipped before checkout and scope resolution; nothing published"
reset_gh open "$HEAD_SHA" false; seed_rc_comment; snapshot_pr
simulate ready-incremental-none incremental
check "workflow control: a ready PR + incremental + no previous review still fails strictly (error status, no reviewer)" \
  eval '[ "$(sim_get "step(\"review\", \"Fetch the previous\")[\"status\"]")" != 0 ] && [ "$(sim_get "step(\"review\", \"Run gencr\")[\"ran\"]")" = False ] &&
        [ "$(sim_get "d[\"review\"][\"result\"]")" = failure ] && [ "$(sim_get "step(\"publish\", \"Publish the PR comment\")[\"outputs\"].get(\"outcome\")")" = "INFRASTRUCTURE FAILURE" ] &&
        [ "$(gh_eval "d[\"statuses\"][-1][\"state\"]")" = error ] && [ "$(sim_get "step(\"publish\", \"Report the review outcome\")[\"status\"]")" != 0 ]'
reset_gh open "$HEAD_SHA" false; snapshot_pr
simulate ready-fresh fresh
check "workflow control: a ready PR + fresh runs gencr and publishes APPROVED with a success status" \
  eval '[ "$(sim_get "step(\"review\", \"Run gencr\")[\"outputs\"].get(\"exit_code\")")" = 0 ] &&
        [ "$(sim_get "step(\"publish\", \"Publish the PR comment\")[\"outputs\"].get(\"outcome\")")" = APPROVED ] &&
        [ "$(gh_eval "d[\"statuses\"][-1][\"state\"]")" = success ] && [ "$(sim_get "step(\"publish\", \"Report the review outcome\")[\"status\"]")" = 0 ]'
reset_gh open "$HEAD_SHA" false; pr_edit 'pr["state"] = None; pr["merged"] = True'; seed_rc_comment; snapshot_pr
simulate ambiguous fresh
check "workflow: ambiguous live PR state is an infrastructure error (error status), never a review or a skip" \
  eval '[ "$(sim_get "step(\"review\", \"Check pull request eligibility\")[\"status\"]")" = 4 ] && [ "$(sim_get "step(\"review\", \"Run gencr\")[\"ran\"]")" = False ] &&
        [ "$(sim_get "step(\"publish\", \"Publish the PR comment\")[\"outputs\"].get(\"outcome\")")" = "INFRASTRUCTURE FAILURE" ] &&
        [ "$(gh_eval "d[\"statuses\"][-1][\"state\"]")" = error ]'

# The workflow wiring (triggers unchanged: manual only).
check "the eligibility gate runs before gencr, and gencr runs only for an eligible PR" \
  py 'import sys
t = open(sys.argv[1]).read()
gate, run = t.index("- name: Check pull request eligibility"), t.index("- name: Run gencr (headless, read-only reviewers)")
block = t[run:].split("- name:", 2)[1]
sys.exit(0 if gate < run and "if: steps.eligibility.outputs.eligibility == '"'"'ELIGIBLE'"'"'" in block
         and "env -u BROKER_TOKEN -u GH_TOKEN -u GITHUB_TOKEN GENCR_ELIGIBILITY_SOCKET=" in block
         and "eligibility-broker" in block else 1)' "$WF"
check "the review workflow is still manual-only (no pull_request trigger)" \
  py 'import sys; t = open(sys.argv[1]).read(); head = t.split("\njobs:", 1)[0]; sys.exit(0 if "workflow_dispatch:" in head and "pull_request" not in head else 1)' "$WF"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
