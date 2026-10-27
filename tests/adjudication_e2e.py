#!/usr/bin/env python3
"""End-to-end tests of primary-reviewer authority and chronological adjudication through bin/gencr with queued mock
reviewer reports (contract v2). Run by tests/test_gencr_adjudication.sh, which provides REPO, TARGET, HOME, MOCK_STATE
and the mock CLIs on PATH. Scenarios marked "sanitized" mirror the chronology of two real reviews with neutral content;
their expected positions are test expectations encoded by hand."""

import glob
import json
import os
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2reports import report, acc, schedule  # noqa: E402

REPO, TARGET, HOME, STATE = (os.environ[k] for k in ("REPO", "TARGET", "HOME", "MOCK_STATE"))
GENCR = os.path.join(REPO, "bin", "gencr")
HEADLINE = "APPROVED by primary reviewer — NOT UNANIMOUS; %d attacker objections remain."
PASS = FAIL = 0


def check(description, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print("ok - " + description)
    else:
        FAIL += 1
        print("not ok - " + description)
        if detail:
            print("    # " + str(detail)[-1500:].replace("\n", "\n    # "))


class Run:
    def __init__(self, dev, responses, args, extra_env=None):
        shutil.rmtree(STATE, ignore_errors=True)
        os.makedirs(os.path.join(STATE, "responses"))
        for n, text in enumerate(responses, 1):
            if text is None:
                continue
            if isinstance(text, dict):  # {"exit": N} or {"report": text, "exit": N}
                if "exit" in text:
                    open(os.path.join(STATE, "exit-%d" % n), "w").write(str(text["exit"]))
                text = text.get("report")
                if text is None:
                    continue
            with open(os.path.join(STATE, "responses", str(n)), "w") as handle:
                handle.write(text)
        env = dict(os.environ, **(extra_env or {}))
        env.pop("MOCK_VERDICT", None)
        proc = subprocess.run([GENCR, dev] + args, cwd=TARGET, env=env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, start_new_session=True)
        self.status, self.out, self.err = proc.returncode, proc.stdout, proc.stderr
        self.calls = int(open(os.path.join(STATE, "count")).read()) if os.path.exists(os.path.join(STATE, "count")) else 0
        pkgs = sorted(glob.glob(os.path.join(HOME, "Documents", "CodeReview", dev, "review-*")), key=os.path.getmtime)
        self.pkg = pkgs[-1] if pkgs else None

    def read(self, name):
        """A package file's text; "" when the run left no such file (a failed check, never a harness crash)."""
        path = os.path.join(self.pkg or "", name)
        return open(path, encoding="utf-8").read() if self.pkg and os.path.isfile(path) else ""

    def json(self, name):
        text = self.read(name)
        return json.loads(text) if text else {}

    def phases(self):
        return [inv["id"] for inv in self.json("metadata.json").get("invocations", [])]


def scripted(primary, attacker, steps):
    """steps: {call number: report text} for the calls that differ; the rest repeat the last report of that agent with
    its PEER-REPORT updated (a reviewer that maintains its position)."""
    sched = schedule(primary, attacker)
    out, last = [], {}
    for n, (rid, agent, peer) in enumerate(sched, 1):
        text = steps.get(n)
        if text is None and agent in last:
            text = re.sub(r"PEER-REPORT: .*\n$", "PEER-REPORT: %s\n" % peer, last[agent])
            text = text.replace("PEER-AGREEMENT: N/A\n", "PEER-AGREEMENT: NO\n")
        if text is None:
            break
        last[agent] = text
        out.append(text)
    return out


def ids(primary, attacker):
    return [rid for rid, _, _ in schedule(primary, attacker)]


def args_for(primary, attacker):
    return ["--fresh", "--%s=attack" % attacker] if primary == "claude" else ["--fresh", "--codex=review", "--claude=attack"]


def consistent(run, label):
    """findings.json, metadata.json, full-report.md, summary.md and the terminal agree on the adjudicated state."""
    meta = run.json("metadata.json").get("adjudication")
    fj = run.json("findings.json").get("adjudication")
    if not meta or not fj:
        check("%s: artifacts agree on the adjudicated state" % label, False, "no adjudication object")
        return
    n = meta["counts"]["attacker_objections"]
    summary, full = run.read("summary.md"), run.read("full-report.md")
    term = [line for line in run.err.splitlines() if "final verdict" in line]
    problems = []
    if meta != fj:
        problems.append("metadata and findings.json adjudication differ")
    if meta["unanimous"]:
        if "NOT UNANIMOUS" in summary or "NOT UNANIMOUS" in full or (term and "NOT UNANIMOUS" in term[-1]):
            problems.append("unanimous run says NOT UNANIMOUS")
    else:
        if "NOT UNANIMOUS" not in summary or "NOT UNANIMOUS" not in full or not term or "NOT UNANIMOUS" not in term[-1]:
            problems.append("non-unanimous run is not labelled in every artifact")
    if "- Attacker objections: %d" % n not in summary or "- Attacker objections: %d" % n not in full:
        problems.append("objection count %d missing from summary or full report" % n)
    if term and ("%d attacker objection" % n) not in term[-1] and not meta["unanimous"]:
        problems.append("terminal line lacks the count")
    check("%s: artifacts agree on the adjudicated state" % label, not problems, problems)


# ── 1. Both orders x four verdict combinations ─────────────────────────────────

for primary, attacker in (("claude", "codex"), ("codex", "claude")):
    P, A = primary.upper(), attacker.upper()
    sched = ids(primary, attacker)
    tag = "%s primary" % primary

    # P APPROVED, A APPROVED, nothing found: unanimous after the attack (2 calls).
    run = Run("aa-" + primary, [report(), report(peer=sched[0], agreement="YES")], args_for(primary, attacker))
    meta = run.json("metadata.json") if run.pkg else {}
    check("%s: APPROVED + APPROVED -> APPROVED, unanimous, 2 calls, exit 0" % tag,
          run.status == 0 and run.calls == 2 and meta.get("outcome") == "APPROVED"
          and meta.get("adjudication", {}).get("unanimous"), (run.status, run.calls, run.err[-800:]))
    if run.pkg:
        consistent(run, tag + " APPROVED+APPROVED")

    # P RC, A RC with the same positions: agreed after the attack (2 calls).
    p0 = report(findings=[("%s-1" % P, "Race")], blockers=["%s-1" % P])
    a0 = report(rows=[acc("%s-1" % P)], blockers=["%s-1" % P], peer=sched[0], agreement="YES")
    run = Run("rr-" + primary, [p0, a0], args_for(primary, attacker))
    meta = run.json("metadata.json") if run.pkg else {}
    check("%s: RC + RC, same positions -> REQUEST CHANGES, unanimous, 2 calls, exit 10" % tag,
          run.status == 10 and run.calls == 2 and meta.get("outcome") == "REQUEST CHANGES"
          and meta.get("adjudication", {}).get("unanimous"), (run.status, run.calls, run.err[-800:]))

    # P APPROVED, A RC on its own finding the primary rejects throughout: cap, APPROVED by authority (9 calls).
    steps = {1: report(),
             2: report(findings=[("%s-1" % A, "Leak")], blockers=["%s-1" % A], peer=sched[0]),
             3: report(rows=["- %s-1: rejected — the handle is closed in finally" % A], peer=sched[1])}
    run = Run("ar-" + primary, scripted(primary, attacker, steps), args_for(primary, attacker))
    meta = run.json("metadata.json") if run.pkg else {}
    adj = meta.get("adjudication", {})
    check("%s: APPROVED + RC -> APPROVED by primary authority after the 3-round cap, exit 0, 9 calls" % tag,
          run.status == 0 and run.calls == 9 and meta.get("outcome") == "APPROVED" and not adj.get("unanimous")
          and adj.get("counts", {}).get("attacker_objections") == 1, (run.status, run.calls, run.err[-800:]))
    if run.pkg:
        summary = run.read("summary.md")
        check("%s: the non-unanimous approval uses the exact headline" % tag, HEADLINE % 1 in summary, summary[:600])
        check("%s: the attacker's finding is preserved with evidence, fix and the primary's response" % tag,
              all(s in summary for s in ("%s-1" % A, "evidence for %s-1" % A, "fix %s-1" % A, "closed in finally")),
              summary[:2000])
        check("%s: the exact invocation trace up to the cap" % tag, run.phases() == sched, run.phases())
        check("%s: no 'No merge blockers were reported' while the attacker lists blockers" % tag,
              "No merge blockers were reported" not in summary)
        consistent(run, tag + " APPROVED+RC")

    # P RC, A APPROVED rejecting the primary's finding throughout: cap, REQUEST CHANGES by authority.
    steps = {1: report(findings=[("%s-1" % P, "Race")], blockers=["%s-1" % P]),
             2: report(rows=["- %s-1: rejected — writes are serialised by the lock" % P], peer=sched[0])}
    run = Run("ra-" + primary, scripted(primary, attacker, steps), args_for(primary, attacker))
    meta = run.json("metadata.json") if run.pkg else {}
    check("%s: RC + APPROVED -> REQUEST CHANGES by primary authority, exit 10, 9 calls" % tag,
          run.status == 10 and run.calls == 9 and meta.get("outcome") == "REQUEST CHANGES"
          and not meta.get("adjudication", {}).get("unanimous"), (run.status, run.calls, run.err[-800:]))
    if run.pkg:
        consistent(run, tag + " RC+APPROVED")

# ── 2. Positions within one verdict ────────────────────────────────────────────

sched = ids("claude", "codex")
# A later response resolves an earlier dispute: severity objection, the primary lowers it, the attacker accepts.
steps = {1: report(findings=[("CLAUDE-1", "Race", "High")], blockers=["CLAUDE-1"]),
         2: report(rows=[acc("CLAUDE-1", severity="medium", blocking="no", why="minor")], peer=sched[0]),
         3: report(findings=[("CLAUDE-1", "Race", "Medium")], peer=sched[1]),
         4: report(rows=[acc("CLAUDE-1", severity="medium", blocking="no", why="agreed")], peer=sched[2], agreement="YES")}
run = Run("resolve", scripted("claude", "codex", steps)[:4], args_for("claude", "codex"))
meta = run.json("metadata.json") if run.pkg else {}
check("a later response resolving an earlier dispute -> stops on agreement (4 calls), unanimous APPROVED",
      run.status == 0 and run.calls == 4 and meta.get("adjudication", {}).get("unanimous"), (run.calls, run.err[-800:]))
if run.pkg:
    summary = run.read("summary.md")
    check("a resolved dispute is not shown as unresolved", "Disputed or unresolved" not in summary
          and "NOT UNANIMOUS" not in summary, summary[:1500])

# An accepted finding with a remaining severity objection, to the cap.
steps = {1: report(findings=[("CLAUDE-1", "Race", "High")], blockers=["CLAUDE-1"]),
         2: report(rows=[acc("CLAUDE-1", severity="medium", blocking="no", why="real but minor")], peer=sched[0])}
run = Run("sevobj", scripted("claude", "codex", steps), args_for("claude", "codex"))
if run.pkg:
    fj = run.json("findings.json")
    f = fj.get("adjudication", {}).get("findings", {}).get("CLAUDE-1", {"facets": {}})
    check("accepted with a remaining severity objection: existence agreed, severity and blocking opposed, preserved",
          f["facets"].get("existence") == "agreed" and f["facets"].get("severity") == "opposed" and f["facets"].get("blocking") == "opposed"
          and run.json("metadata.json")["outcome"] == "REQUEST CHANGES", f["facets"])
    summary = run.read("summary.md")
    check("severity per reviewer and blocking per reviewer are shown in the summary",
          "Claude: high" in summary and "Codex: medium" in summary and "Claude: yes" in summary and "Codex: no" in summary,
          summary[:2500])
else:
    check("accepted with a remaining severity objection produced a package", False, run.err[-800:])

# ── 3. Sanitized real-run chronologies ─────────────────────────────────────────

# Claude primary, CODEX-1: disputed attribution/severity/blocking; Codex maintains; Claude concedes attribution only.
steps = {1: report(findings=[("CLAUDE-1", "Settings modal untested")], blockers=["CLAUDE-1"]),
         2: report(findings=[("CODEX-1", "ETL rejection reported as success")], rows=[acc("CLAUDE-1")],
                   blockers=["CLAUDE-1", "CODEX-1"], peer=sched[0]),
         3: report(findings=[("CLAUDE-1", "Settings modal untested")], blockers=["CLAUDE-1"],
                   rows=[acc("CODEX-1", "no", "medium", "no", "pre-existing platform pattern", status="disputed")],
                   disputes=["- CODEX-1: disputed on whether it is new and whether it blocks merge"], peer=sched[1]),
         4: report(findings=[("CODEX-1", "ETL rejection reported as success")], rows=[acc("CLAUDE-1")],
                   blockers=["CLAUDE-1", "CODEX-1"],
                   disputes=["- CODEX-1: scope attribution and merge-blocking significance remain disputed"], peer=sched[2]),
         5: report(findings=[("CLAUDE-1", "Settings modal untested")], blockers=["CLAUDE-1"],
                   rows=[acc("CODEX-1", "yes", "medium", "no", "present in the new code; not blocking")], peer=sched[3],
                   agreement="YES")}
run = Run("sanitized-claude", scripted("claude", "codex", steps), args_for("claude", "codex"))
if run.pkg:
    f = run.json("findings.json").get("adjudication", {}).get("findings", {}).get("CODEX-1", {"facets": None})
    check("sanitized CODEX-1: attribution agreed; severity and blocking still opposed at the end",
          f["facets"] == {"existence": "agreed", "introduced": "agreed", "severity": "opposed", "blocking": "opposed"},
          f["facets"])
    summary, full = run.read("summary.md"), run.read("full-report.md")
    check("sanitized CODEX-1: the old Codex dispute text is labelled as a dated statement, not a current claim",
          "scope attribution and merge-blocking significance remain disputed" not in summary.split("### Attacker objections")[0]
          and "answered later by Claude" in full, summary[:2500])
    check("sanitized CODEX-1: PEER-AGREEMENT YES no longer ends reconciliation while positions differ (cap reached)",
          run.calls == 9, run.calls)
else:
    check("sanitized CODEX-1 produced a package", False, run.err[-1200:])

# Codex primary, CODEX-6: Claude accepts it as real but not blocking, with no dispute row.
csched = ids("codex", "claude")
steps = {1: report(findings=[("CODEX-6", "ETL rejection reported as success")], blockers=["CODEX-6"]),
         2: report(rows=[acc("CODEX-6", "yes", "high", "no", "real, but every provider ignores it")], peer=csched[0],
                   agreement="YES")}
run = Run("sanitized-codex", scripted("codex", "claude", steps), args_for("codex", "claude"))
if run.pkg:
    summary = run.read("summary.md")
    check("sanitized CODEX-6: accepted-but-not-blocking is listed as an attacker objection",
          "CODEX-6" in summary.split("### Attacker objections")[-1] and run.json("metadata.json")["outcome"] == "REQUEST CHANGES",
          summary[:2500])
else:
    check("sanitized CODEX-6 produced a package", False, run.err[-1200:])

# ── 4. Claims, rewrites and supplemental objections end to end ─────────────────

steps = {1: report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"]),
         2: report(rows=[acc("CLAUDE-1", severity="critical")], blockers=["CLAUDE-1"], peer=sched[0]),
         3: report(withdrawn=["- CLAUDE-1: withdrawn — the lock covers it"], peer=sched[1]),
         4: report(rows=[acc("CLAUDE-1", severity="critical", source=sched[0], why="the lock misses the second writer")],
                   blockers=["CLAUDE-1"], peer=sched[2])}
run = Run("withdraw", scripted("claude", "codex", steps), args_for("claude", "codex"))
if run.pkg:
    summary = run.read("summary.md")
    check("primary withdraws, attacker maintains -> APPROVED by authority with the objection kept (original ID/author)",
          run.json("metadata.json")["outcome"] == "APPROVED" and "CLAUDE-1" in summary and HEADLINE % 1 in summary
          and "the lock covers it" in run.read("full-report.md"), summary[:2000])
else:
    check("withdrawal scenario produced a package", False, run.err[-1200:])

# The primary rewords a Low finding in its last report at the cap (an unrelated severity dispute keeps the run going).
steps = {1: report(findings=[("CLAUDE-1", "Race"), ("CLAUDE-2", "Typo", "Low")], blockers=["CLAUDE-1"]),
         2: report(rows=[acc("CLAUDE-1", severity="medium", blocking="no"), acc("CLAUDE-2", severity="low", blocking="no")],
                   peer=sched[0]),
         9: report(findings=[("CLAUDE-1", "Race"), ("CLAUDE-2", "Typo in log message", "Low")], blockers=["CLAUDE-1"],
                   peer=sched[7])}
run = Run("rewrite", scripted("claude", "codex", steps), args_for("claude", "codex"))
full = run.read("full-report.md") if run.pkg else ""
check("a Low finding reworded in the last report is labelled not reassessed in the full report",
      "accepted an earlier version" in full and "CLAUDE-2" in full, (run.calls, run.err[-600:]))

steps = {1: report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"]),
         2: report(rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"], peer=sched[0],
                   supplemental=["- CODEX-O1 (CLAUDE-1; fix): raised — the retry duplicates committed exports"]),
         3: report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"], peer=sched[1],
                   supplemental=["- CODEX-O1: rejected — the retry is idempotent"]),
         4: report(rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"], peer=sched[2],
                   supplemental=["- CODEX-O1 (CLAUDE-1; fix): conceded — idempotent, as shown"], agreement="YES")}
run = Run("supplemental", scripted("claude", "codex", steps)[:4], args_for("claude", "codex"))
check("a supplemental objection on the fix gets a primary response and is resolved by its concession (4 calls)",
      run.calls == 4 and run.status == 10 and run.pkg and run.json("metadata.json").get("adjudication", {}).get("unanimous"),
      (run.calls, run.status, run.err[-800:]))

# ── 5. Invalid and incomplete reports never produce a verdict ──────────────────

base = [report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"])]
for label, a0 in (("a disposition row without facets", report(rows=["- CLAUDE-1: accepted — fine"], peer=sched[0])),
                  ("a row missing the blocking facet",
                   report(rows=["- CLAUDE-1: accepted; introduced: yes; severity: high — fine"], peer=sched[0]))):
    run = Run("bad-" + label.split()[1], base + [a0], args_for("claude", "codex"))
    meta = run.json("metadata.json") if run.pkg else {}
    check("malformed v2 report (%s) -> INCOMPLETE, exit 20, no verdict" % label,
          run.status == 20 and meta.get("outcome") == "INCOMPLETE", (run.status, run.err[-600:]))
steps = {1: report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"]),
         2: report(findings=[("CODEX-1", "Leak")], rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1", "CODEX-1"], peer=sched[0]),
         3: report(rows=[acc("CODEX-1")], blockers=["CODEX-1"], peer=sched[1])}
run = Run("omit", scripted("claude", "codex", steps)[:3], args_for("claude", "codex"))
check("a reviewer dropping its own finding without withdrawing it -> INCOMPLETE",
      run.status == 20 and "CLAUDE-1" in run.err and "Withdrawn findings" in run.err, run.err[-600:])
steps = {1: report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"]),
         2: report(rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"], peer=sched[0],
                   supplemental=["- CODEX-O1 (CLAUDE-1; evidence): raised — the trace skips the retry path"]),
         3: report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"], peer=sched[1])}
run = Run("noresp", scripted("claude", "codex", steps)[:3], args_for("claude", "codex"))
check("a missing response to a live supplemental objection -> INCOMPLETE", run.status == 20 and "CODEX-O1" in run.err,
      run.err[-600:])
steps = {1: report(),
         2: report(findings=[("CODEX-1", "Leak")], blockers=["CODEX-1"], peer=sched[0]),
         3: {"exit": 3}}
run = Run("pfail", scripted("claude", "codex", {1: steps[1], 2: steps[2]})[:2] + [steps[3]], args_for("claude", "codex"))
meta = run.json("metadata.json") if run.pkg else {}
check("the primary's required response fails after its initial approval -> never APPROVED",
      run.status != 0 and meta.get("outcome") not in ("APPROVED",), (run.status, meta.get("outcome")))

# ── 6. GitHub-ready comment bounds: overflow disclosure, untruncated artifacts ──

many = [("CODEX-%d" % i, "Objection %d" % i, "Medium", "yes", "p", "E" * 3000, "F" * 3000) for i in range(1, 41)]
steps = {1: report(),
         2: report(findings=many, blockers=["CODEX-%d" % i for i in range(1, 41)], peer=sched[0]),
         3: report(rows=["- CODEX-%d: rejected — not reproducible" % i for i in range(1, 41)], peer=sched[1])}
run = Run("overflow", scripted("claude", "codex", steps), args_for("claude", "codex"))
if run.pkg:
    summary = run.read("summary.md")
    comment = summary.split("<!-- gencr:review-comment:begin -->")[1].split("<!-- gencr:review-comment:end -->")[0]
    full, fj = run.read("full-report.md"), run.json("findings.json")
    check("overflow: the comment stays within its budget and discloses how many objections it does not show",
          len(comment) <= 40000 and re.search(r"\d+ of 40 attacker objections are not shown (in full )?in this comment", comment),
          len(comment))
    check("overflow: the headline and the total count are always present", HEADLINE % 40 in comment
          and "- Attacker objections: 40" in comment)
    check("overflow: full report and findings.json keep every objection with its complete evidence",
          all(("CODEX-%d " % i) in full for i in range(1, 41)) and full.count("E" * 3000) >= 40
          and len(fj.get("adjudication", {}).get("findings", {})) == 40)
else:
    check("overflow produced a package", False, run.err[-1200:])

# ── 7. History: no barrier; objections carried; tampered adjudication is a barrier ──

import copy  # noqa: E402
import hashlib  # noqa: E402

steps = {1: report(),
         2: report(findings=[("CODEX-1", "Leak")], blockers=["CODEX-1"], peer=sched[0]),
         3: report(rows=["- CODEX-1: rejected — the handle is closed in finally"], peer=sched[1])}
first = Run("history", scripted("claude", "codex", steps), args_for("claude", "codex"))
subprocess.run(["git", "-C", TARGET, "commit", "-q", "--allow-empty", "-m", "follow-up"], check=True)
follow = Run("history", [], ["--codex=attack"])
stdin1 = open(os.path.join(STATE, "call-1.stdin")).read() if follow.calls else ""
check("no barrier: after an authority APPROVED with an open objection, a new commit is automatically INCREMENTAL",
      first.json("metadata.json")["outcome"] == "APPROVED" and "review mode: INCREMENTAL" in follow.err, follow.err[-800:])
check("no barrier: the open attacker objection is carried into the next review for reassessment",
      re.search(r"Previous findings still open \(verify each one\): .*CODEX-1", stdin1) is not None, stdin1[-400:])

first_adjudication = copy.deepcopy(first.json("metadata.json")["adjudication"])  # before the tampering below
# A tampered adjudication (claims unanimity) with a re-hashed manifest: never a trusted baseline.
pkg = first.pkg
meta = json.load(open(os.path.join(pkg, "metadata.json")))
meta["adjudication"]["unanimous"] = True
data = json.dumps(meta, indent=2) + "\n"
open(os.path.join(pkg, "metadata.json"), "w").write(data)
manifest = json.load(open(os.path.join(pkg, "manifest.json")))
manifest["files"]["metadata.json"] = hashlib.sha256(data.encode()).hexdigest()
open(os.path.join(pkg, "manifest.json"), "w").write(json.dumps(manifest, indent=2) + "\n")
for extra in glob.glob(os.path.join(HOME, "Documents", "CodeReview", "history", "review-*")):
    if extra != pkg:
        shutil.rmtree(extra)
subprocess.run(["git", "-C", TARGET, "commit", "-q", "--allow-empty", "-m", "second follow-up"], check=True)
tampered = Run("history", [], ["--codex=attack"])
check("a tampered adjudication stops automatic selection (untrusted baseline), launching nothing",
      tampered.status == 1 and tampered.calls == 0 and "cannot be trusted" in tampered.err and "adjudication" in tampered.err,
      tampered.err[-800:])

# ── 8. The comment's fallback keeps the qualification ──────────────────────────

sys.path.insert(0, os.path.join(REPO, "bin"))
import gencr_summary  # noqa: E402
adj = first_adjudication
fallback = gencr_summary.safe_render({"adjudication": adj, "objections": [], "findings": [], "outcome": "APPROVED",
                                      "review_mode": "FRESH", "approval_scope_label": "x", "head_sha": "a" * 40,
                                      "models": {"claude": "m", "codex": "m"}}, budget=100)
check("fallback comment keeps the NOT UNANIMOUS qualification, both verdicts and the objection count",
      "NOT UNANIMOUS" in fallback and "- Attacker objections: 1" in fallback and "Codex (attacker)" in fallback, fallback)

# ── 9. Implementation review 1 regressions (SD-I2, SD-I3, SD-I4, SD-I5) ────────

for primary, attacker in (("claude", "codex"), ("codex", "claude")):
    P, A = primary.upper(), attacker.upper()
    PF, AF, OID = P + "-1", A + "-1", A + "-O1"
    sched = ids(primary, attacker)
    tag = "%s primary" % primary
    raise_o = "- %s (%s; fix): raised — the retry duplicates committed exports" % (OID, PF)
    keep_o = "- %s (%s; fix): maintained — the retry duplicates committed exports" % (OID, PF)

    # SD-I3: a supplemental-only disagreement on a primary-authored finding (no ordinary primary disposition).
    steps = {1: report(findings=[(PF, "Race")], blockers=[PF]),
             2: report(rows=[acc(PF)], blockers=[PF], supplemental=[raise_o], peer=sched[0]),
             3: report(findings=[(PF, "Race")], blockers=[PF], peer=sched[1],
                       supplemental=["- %s: rejected — RETRY_IS_IDEMPOTENT_AFTER_RECHECK" % OID]),
             4: report(rows=[acc(PF)], blockers=[PF], supplemental=[keep_o], peer=sched[2])}
    run = Run("suppresp-" + primary, scripted(primary, attacker, steps), args_for(primary, attacker))
    summary = run.read("summary.md")
    check("SD-I3 %s: the comment shows the primary's response to a supplemental objection with its rationale" % tag,
          run.calls == 9 and "RETRY_IS_IDEMPOTENT_AFTER_RECHECK" in summary
          and re.search(r"Response by %s \(report %s; rejected\)" % (primary.capitalize(), re.escape(sched[8])), summary)
          is not None, (run.calls, summary[:3000], run.err[-600:]))

    # SD-I2: the primary accepts the objection, the attacker maintains it, the primary then rejects it (APPROVED primary;
    # an unrelated attacker finding keeps the run going until the reversal).
    steps = {1: report(findings=[(PF, "Race", "Low")]),
             2: report(findings=[(AF, "Leak", "Low")], rows=[acc(PF, "yes", "low", "no")], supplemental=[raise_o],
                       peer=sched[0]),
             3: report(findings=[(PF, "Race", "Low")], rows=["- %s: rejected — not real" % AF], peer=sched[1],
                       supplemental=["- %s: accepted — first answer" % OID]),
             4: report(findings=[(AF, "Leak", "Low")], rows=[acc(PF, "yes", "low", "no")], supplemental=[keep_o],
                       peer=sched[2]),
             5: report(findings=[(PF, "Race", "Low")], rows=[acc(AF, "yes", "low", "no")], peer=sched[3],
                       supplemental=["- %s: rejected — RETRY_IS_IDEMPOTENT_AFTER_RECHECK" % OID])}
    run = Run("reversal-" + primary, scripted(primary, attacker, steps), args_for(primary, attacker))
    meta = run.json("metadata.json") if run.pkg else {}
    adj = meta.get("adjudication", {})
    check("SD-I2 %s: a later rejection of an accepted objection keeps it active: APPROVED, NOT UNANIMOUS, 9 calls" % tag,
          run.status == 0 and run.calls == 9 and meta.get("outcome") == "APPROVED" and not adj.get("unanimous")
          and adj.get("counts", {}).get("supplemental_active") == 1 and "NOT UNANIMOUS" in run.read("summary.md")
          and "unanimous" not in (run.err.splitlines() or [""])[-1].replace("NOT UNANIMOUS", ""),
          (run.status, run.calls, adj.get("counts"), run.err[-600:]))

# SD-I5: overflow with distinct files and existence/introduced disagreements: every indexed objection is complete.
sched = ids("claude", "codex")
many = [{"fid": "CODEX-%d" % i, "title": "Objection %d" % i, "severity": "Medium", "introduced": "yes" if i % 2 else "no",
         "evidence": "E" * 3000, "fix": "F" * 3000, "file": "pkg/mod_%d.py:%d" % (i, 10 + i)} for i in range(1, 41)]
steps = {1: report(),
         2: report(findings=many, blockers=["CODEX-%d" % i for i in range(1, 41)], peer=sched[0]),
         3: report(rows=["- CODEX-%d: rejected — not reproducible" % i if i % 3 else
                         acc("CODEX-%d" % i, "no" if i % 2 else "yes", "low", "no", "pre-existing", status="disputed")
                         for i in range(1, 41)], peer=sched[1])}
run = Run("overflow-index", scripted("claude", "codex", steps), args_for("claude", "codex"))
summary = run.read("summary.md")
index = [line for line in summary.split("\n") if re.match(r"^- \*\*CODEX-\d+\*\*", line)]
incomplete = [line[:80] for line in index if not re.search(r"File: pkg/mod_(\d+)\.py:\d+; exists — .*introduced by this "
                                                             r"change — .*severity — .*blocks merge — ", line)
              or "mod_%s.py" % re.match(r"^- \*\*CODEX-(\d+)", line).group(1) not in line]
hidden = re.search(r"(\d+) of 40 attacker objections are not shown in this comment", summary)
check("SD-I5: every indexed objection carries its file and every reviewer's existence, introduced, severity and "
      "blocking positions", index and not incomplete, (len(index), incomplete[:3]))
check("SD-I5: indexed plus disclosed-as-not-shown objections account for all 40",
      len(index) + (int(hidden.group(1)) if hidden else 0) == 40, (len(index), hidden and hidden.group(0)))

# SD-I4: a valid completed package whose adjudication is edited (manifest re-hashed) is never trusted as a baseline:
# (a) ill-typed and mis-bound (primary report -> attacker's, a blocking position as "yes", needs_another_round as
# "false"); (b) findings.json's copy alone changed; (c) SD-I4-R1: in a unanimous APPROVED package, the author's current
# "introduced" changed in every copy (metadata, findings.json and the canonical finding's), contradicting the peer's
# current-version assessment while every stored facet still says agreed.
rc_steps = {1: report(),
            2: report(findings=[("CODEX-1", "Leak")], blockers=["CODEX-1"], peer=sched[0]),
            3: report(rows=["- CODEX-1: rejected — the handle is closed in finally"], peer=sched[1])}
unanimous = [report(findings=[("CLAUDE-1", "Race", "Low")]),
             report(rows=[acc("CLAUDE-1", "yes", "low", "no")], peer=sched[0], agreement="YES")]


def ill_typed(adj):
    adj["primary_report"] = adj["attacker_report"]
    adj["needs_another_round"] = "false"
    for f in adj["findings"].values():
        for p in f["positions"].values():
            p["blocking"] = "yes" if p["blocking"] else p["blocking"]


def contradict(adj):
    adj["findings"]["CLAUDE-1"]["positions"]["claude"]["introduced"] = "no"


def edited_copies(doc, name, edit):
    """Every adjudication copy in a package document (the canonical findings' copies in findings.json included)."""
    edit(doc["adjudication"])
    if edit is contradict and name == "findings.json":
        for f in doc.get("final_findings", []):
            if f["id"] == "CLAUDE-1" and f.get("adjudication"):
                f["adjudication"]["positions"]["claude"]["introduced"] = "no"


for label, dev, responses, files, edit in (
        ("an ill-typed, mis-bound adjudication", "malformed-a", scripted("claude", "codex", rc_steps),
         ("metadata.json", "findings.json"), ill_typed),
        ("a findings.json adjudication that differs from metadata.json", "malformed-b",
         scripted("claude", "codex", rc_steps), ("findings.json",), lambda adj: adj["counts"].update(agreed=adj["counts"]["agreed"] + 1)),
        ("a current-version assessment contradicting the author's current position (SD-I4-R1)", "malformed-c", unanimous,
         ("metadata.json", "findings.json"), contradict)):
    base = Run(dev, responses, args_for("claude", "codex"))
    if edit is contradict:
        check("SD-I4-R1: the base package is a valid unanimous APPROVED review",
              base.status == 0 and base.json("metadata.json").get("adjudication", {}).get("unanimous"), base.err[-400:])
    manifest = json.load(open(os.path.join(base.pkg, "manifest.json")))
    for name in files:
        doc = json.load(open(os.path.join(base.pkg, name)))
        edited_copies(doc, name, edit)
        data = json.dumps(doc, indent=2) + "\n"
        open(os.path.join(base.pkg, name), "w").write(data)
        manifest["files"][name] = hashlib.sha256(data.encode()).hexdigest()
    open(os.path.join(base.pkg, "manifest.json"), "w").write(json.dumps(manifest, indent=2) + "\n")
    explicit = Run(dev, [], ["--incremental", "--previous=" + base.pkg, "--codex=attack"])
    check("SD-I4: %s is refused as an explicit baseline (no 'no new review needed', no reviewer call)" % label,
          explicit.status not in (0, 10) and explicit.calls == 0 and "no new review needed" not in explicit.err
          and "adjudication" in explicit.err, (explicit.status, explicit.err[-600:]))
    subprocess.run(["git", "-C", TARGET, "commit", "-q", "--allow-empty", "-m", "after " + dev], check=True)
    auto = Run(dev, [], ["--codex=attack"])
    check("SD-I4: %s stops automatic selection, launching nothing" % label,
          auto.status == 1 and auto.calls == 0 and "adjudication" in auto.err, auto.err[-600:])

print("\n%d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
