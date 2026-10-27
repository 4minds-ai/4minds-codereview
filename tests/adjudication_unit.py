#!/usr/bin/env python3
"""Unit tests for the contract-v2 position grammar (bin/gencr_report.py) and the chronological claim ledger
(bin/gencr_adjudicate.py). Usage: adjudication_unit.py REPO. Prints TAP-like "ok -" / "not ok -" lines.

Report texts are built by report() below. Scenarios marked "sanitized" mirror the chronology of two real reviews
(Claude-primary CODEX-1; Codex-primary CODEX-6) with neutral content; their expected positions are test expectations
encoded by hand, not output of the models that produced the original reviews."""

import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(sys.argv[1], "bin"))
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
            print("    # " + str(detail).replace("\n", "\n    # "))


try:
    import gencr_report
    import gencr_adjudicate
except ImportError as error:
    check("the adjudication modules import", False, error)
    print("\n%d passed, %d failed" % (PASS, FAIL))
    sys.exit(1)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2reports import NOTES, report, acc  # noqa: E402


PRODUCED = []  # every adjudication built below, with its invocation records: each must validate (end of file)


def invocations(reports):
    """The package's invocation records of valid reports: id, agent, the verdict and the report answered."""
    def last(text, key):
        return [line for line in text.split("\n") if line.startswith(key + ": ")][-1][len(key) + 2:]
    return [{"id": rid, "agent": rid.split("-")[2], "verdict": last(text, "VERDICT"),
             "peer_report": None if last(text, "PEER-REPORT") == "N/A" else last(text, "PEER-REPORT")}
            for rid, text in reports]


def run(reports, primary="claude", attacker="codex"):
    """reports: [(id, text)] in invocation order; agent and answered report come from the ID and PEER-REPORT."""
    seq = []
    for rid, text in reports:
        agent = rid.split("-")[2]
        peer = text.rstrip("\n").split("\n")[-1].split(": ", 1)[1]
        seq.append({"id": rid, "agent": agent, "peer_report": None if peer == "N/A" else peer, "text": text})
    adj = gencr_adjudicate.adjudicate(seq, primary, attacker)
    PRODUCED.append((adj, invocations(reports), primary, attacker))
    return adj


P0, A0, P1, A1, P2 = ("01-round0-claude-initial", "02-round0-codex-attack", "03-round1-claude-reconcile",
                      "04-round1-codex-respond", "05-round1-claude-reconcile")
# ── Grammar ────────────────────────────────────────────────────────────────────

text = report(findings=[("CLAUDE-1", "Lost update", "Medium", "no")],
              rows=[acc("CODEX-1", "yes", "medium", "no", "real but minor"), "- CODEX-2: rejected — false positive",
                    acc("CODEX-3", blocking="no", source="02-round0-codex-attack", status="disputed")],
              withdrawn=["- CLAUDE-2: withdrawn — disproved by the lock at sync.py:40"],
              supplemental=["- CLAUDE-O1 (CODEX-1; fix): raised — the retry duplicates exports",
                            "- CODEX-O2: rejected — the evidence is in the test"],
              blockers=["CLAUDE-1"], peer="02-round0-codex-attack")
pos = gencr_report.parse_positions(text)
check("grammar: no errors on a well-formed contract-v2 report", not pos["errors"], pos["errors"])
row = {r["id"]: r for r in pos["rows"]}
check("grammar: accepted row facets", (row["CODEX-1"]["status"], row["CODEX-1"]["introduced"], row["CODEX-1"]["severity"],
                                       row["CODEX-1"]["blocking"]) == ("accepted", "yes", "medium", False), row.get("CODEX-1"))
check("grammar: rejected row has no facets and keeps its rationale",
      row["CODEX-2"]["status"] == "rejected" and row["CODEX-2"]["severity"] is None and row["CODEX-2"]["rationale"] == "false positive")
check("grammar: source-qualified disputed row", row["CODEX-3"]["source"] == "02-round0-codex-attack" and row["CODEX-3"]["status"] == "disputed")
check("grammar: withdrawn finding", pos["withdrawn"] == [{"id": "CLAUDE-2", "reason": "disproved by the lock at sync.py:40"}], pos["withdrawn"])
check("grammar: supplemental claim and response",
      pos["objections"] == [{"id": "CLAUDE-O1", "finding": "CODEX-1", "topic": "fix", "status": "raised",
                             "text": "the retry duplicates exports"}]
      and pos["responses"] == [{"id": "CODEX-O2", "status": "rejected", "text": "the evidence is in the test"}],
      (pos["objections"], pos["responses"]))
check("grammar: own finding position (severity class, introduced, blocking)",
      [(f["id"], f["severity"], f["introduced"], f["blocking"]) for f in pos["findings"]] == [("CLAUDE-1", "medium", "no", True)],
      pos["findings"])
bad = gencr_report.parse_positions(report(rows=["- CODEX-1: accepted; introduced: yes; severity: high — no blocking facet"],
                                          peer="02-round0-codex-attack"))
check("grammar: a row missing a facet is an error, never a default", bad["errors"], bad)
bad = gencr_report.parse_positions(report(rows=["- CODEX-1: accepted — verified"], peer="02-round0-codex-attack"))
check("grammar: a v1-style accepted row without facets is an error in contract v2", bad["errors"], bad)
bad = gencr_report.parse_positions(report(findings=[("CLAUDE-1", "X", "High", "maybe")]))
check("grammar: Introduced by this change must be yes or no", bad["errors"], bad)
bad = gencr_report.parse_positions(report(rows=[acc("CODEX-1", blocking="yes")], peer="02-round0-codex-attack"))
check("grammar: blocking: yes requires the ID under Merge blockers", bad["errors"], bad)
bad = gencr_report.parse_positions(report(findings=[("CLAUDE-1", "X")], blockers=["CLAUDE-1"],
                                          withdrawn=["- CLAUDE-1: withdrawn — oops"]))
check("grammar: a finding cannot be both defined and withdrawn", bad["errors"], bad)
bad = gencr_report.parse_positions(report(supplemental=["- CLAUDE-O1 (CODEX-1; style): raised — x"]))
check("grammar: supplemental topic must be evidence, fix, scope or other", bad["errors"], bad)

# ── Ledger: agreement, single facets, existence ────────────────────────────────

p0 = report(findings=[("CLAUDE-1", "Lost update")], blockers=["CLAUDE-1"])
a0 = report(rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"], peer=P0, agreement="YES")
r = run([(P0, p0), (A0, a0)])
f = r["findings"]["CLAUDE-1"]
check("ledger: full agreement on the current version -> agreed, unanimous, no further round",
      f["status"] == "agreed" and r["positions_agree"] and r["verdicts_agree"] and r["unanimous"]
      and not r["needs_another_round"] and r["counts"]["attacker_objections"] == 0, (f, r["counts"]))
check("ledger: primary authority verdict and report", r["primary_verdict"] == "REQUEST CHANGES" and r["primary_report"] == P0
      and r["attacker_report"] == A0 and r["attacker_verdict"] == "REQUEST CHANGES")

a0 = report(rows=[acc("CLAUDE-1", severity="medium", blocking="no", why="minor")], peer=P0)
r = run([(P0, p0), (A0, a0)])
f = r["findings"]["CLAUDE-1"]
check("ledger: accepted with a different severity and blocking -> both facets opposed, existence agreed",
      f["facets"] == {"existence": "agreed", "introduced": "agreed", "severity": "opposed", "blocking": "opposed"}
      and f["status"] == "opposed", f["facets"])
check("ledger: an accepted finding with a remaining objection is an attacker objection; not unanimous",
      r["counts"]["attacker_objections"] == 1 and not r["unanimous"] and r["needs_another_round"])
check("ledger: verdicts differ (primary RC, attacker APPROVED) -> the primary verdict applies",
      r["primary_verdict"] == "REQUEST CHANGES" and r["attacker_verdict"] == "APPROVED" and not r["verdicts_agree"])

a0 = report(rows=["- CLAUDE-1: rejected — the lock serialises writers"], peer=P0)
r = run([(P0, p0), (A0, a0)])
check("ledger: existence disagreement (rejected) -> opposed existence",
      r["findings"]["CLAUDE-1"]["facets"]["existence"] == "opposed" and r["findings"]["CLAUDE-1"]["status"] == "opposed")

a0 = report(findings=[("CODEX-1", "Ignored ETL result")], rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1", "CODEX-1"], peer=P0)
r = run([(P0, p0), (A0, a0)])
check("ledger: a new attacker finding the primary has not assessed -> not reassessed; another round needed",
      r["findings"]["CODEX-1"]["status"] == "not reassessed" and r["needs_another_round"]
      and r["counts"]["attacker_objections"] == 0 and r["counts"]["not_reassessed"] == 1, r["counts"])

# ── Sanitized real-run chronologies ────────────────────────────────────────────

# Claude primary: CODEX-1 disputed (attribution, severity, blocking), Codex maintains it, Claude finally concedes
# attribution but keeps Medium / not blocking (the swalker-claude chronology).
p0 = report(findings=[("CLAUDE-1", "Settings modal untested", "High")], blockers=["CLAUDE-1"])
a0 = report(findings=[("CODEX-1", "ETL rejection reported as success")], rows=[acc("CLAUDE-1")],
            blockers=["CLAUDE-1", "CODEX-1"], peer=P0)
p1 = report(findings=[("CLAUDE-1", "Settings modal untested", "High")], blockers=["CLAUDE-1"],
            rows=[acc("CODEX-1", "no", "medium", "no", "pre-existing pattern", status="disputed")],
            disputes=["- CODEX-1: disputed on whether it is new and whether it blocks merge"], peer=A0)
a1 = report(findings=[("CODEX-1", "ETL rejection reported as success")], rows=[acc("CLAUDE-1")],
            blockers=["CLAUDE-1", "CODEX-1"],
            disputes=["- CODEX-1: scope attribution and merge-blocking significance remain disputed"], peer=P1)
p2 = report(findings=[("CLAUDE-1", "Settings modal untested", "High")], blockers=["CLAUDE-1"],
            rows=[acc("CODEX-1", "yes", "medium", "no", "present in the new code; not blocking")], peer=A1, agreement="YES")
r = run([(P0, p0), (A0, a0), (P1, p1), (A1, a1), (P2, p2)])
f = r["findings"]["CODEX-1"]
check("sanitized CODEX-1: attribution resolved, severity and blocking still opposed",
      f["facets"] == {"existence": "agreed", "introduced": "agreed", "severity": "opposed", "blocking": "opposed"}, f["facets"])
st = [s for s in f["statements"] if s["report"] == A1 and s["kind"] == "dispute"]
check("sanitized CODEX-1: Codex's round-1 dispute row is a dated statement answered later by Claude in report 05",
      st and st[0]["answered_later_by"] == {"agent": "claude", "report": P2}, f["statements"])
check("sanitized CODEX-1: primary response is Claude's latest row with its report",
      f["primary_response"] and f["primary_response"]["report"] == P2 and "not blocking" in f["primary_response"]["text"])
check("sanitized CODEX-1: one attacker objection; primary verdict RC; not unanimous",
      r["counts"]["attacker_objections"] == 1 and r["primary_verdict"] == "REQUEST CHANGES" and not r["unanimous"])
ev = [h["event"] for h in f["history"]]
check("sanitized CODEX-1: history in order (raised, disputed, maintained, accepted)",
      ev == ["raised", "disputed", "maintained", "accepted"], ev)

# Codex primary: Claude accepts CODEX-6 as real but not blocking (the swalker-codex chronology); no dispute row at all.
cp0 = report(findings=[("CODEX-6", "ETL rejection reported as success")], blockers=["CODEX-6"])
ca0 = report(rows=[acc("CODEX-6", "yes", "high", "no", "real, but every provider ignores it")], peer="01-round0-codex-initial",
             agreement="YES")
r = run([("01-round0-codex-initial", cp0), ("02-round0-claude-attack", ca0)], primary="codex", attacker="claude")
f = r["findings"]["CODEX-6"]
check("sanitized CODEX-6: accepted but not blocking is an active disagreement even with no disputed row",
      f["facets"]["blocking"] == "opposed" and f["status"] == "opposed" and r["counts"]["attacker_objections"] == 1, f)
check("sanitized CODEX-6: PEER-AGREEMENT YES does not make the positions agree", not r["positions_agree"] and r["needs_another_round"])

# ── Claims: withdrawal ─────────────────────────────────────────────────────────

p0 = report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"])
a0 = report(rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"], peer=P0)
p1 = report(withdrawn=["- CLAUDE-1: withdrawn — I was wrong about the lock"], peer=A0)
a1 = report(rows=[acc("CLAUDE-1", source=P0, why="the lock does not cover the second writer")], blockers=["CLAUDE-1"], peer=P1)
p2 = report(withdrawn=[], peer=A1)
r = run([(P0, p0), (A0, a0), (P1, p1), (A1, a1), (P2, p2)])
f = r["findings"].get("CLAUDE-1")
check("claims: author withdraws, attacker maintains -> still reportable with original ID and author, opposed",
      f and f["live"] and f["author"] == "claude" and f["status"] == "opposed" and f["withdrawn"]["report"] == P1, f)
check("claims: primary APPROVED applies; one attacker objection; not unanimous",
      r["primary_verdict"] == "APPROVED" and r["counts"]["attacker_objections"] == 1 and not r["unanimous"])
a1w = report(rows=["- CLAUDE-1 (report %s): withdrawn — agreed, the lock covers it" % P0], peer=P1)
r = run([(P0, p0), (A0, a0), (P1, p1), (A1, a1w)])
f = r["findings"].get("CLAUDE-1")
check("claims: both withdraw -> history only, no objection", f is not None and not f["live"]
      and r["counts"]["attacker_objections"] == 0 and r["positions_agree"], f)

# Reverse roles: the primary maintains an attacker finding the attacker withdrew.
p0 = report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"])
a0 = report(findings=[("CODEX-1", "Leak")], rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1", "CODEX-1"], peer=P0)
p1 = report(findings=[("CLAUDE-1", "Race")], rows=[acc("CODEX-1")], blockers=["CLAUDE-1", "CODEX-1"], peer=A0)
a1 = report(withdrawn=["- CODEX-1: withdrawn — duplicate of CLAUDE-1"], rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"], peer=P1)
r = run([(P0, p0), (A0, a0), (P1, p1), (A1, a1)])
f = r["findings"]["CODEX-1"]
check("claims (reverse roles): attacker withdraws, primary still asserts -> reportable and opposed until the primary answers",
      f["live"] and f["status"] == "opposed" and f["author"] == "codex", f)

# ── Definition rewrites ────────────────────────────────────────────────────────

p0 = report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"])
a0 = report(rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"], peer=P0)
p1 = report(findings=[("CLAUDE-1", "Race between writers")], blockers=["CLAUDE-1"], peer=A0)
r = run([(P0, p0), (A0, a0), (P1, p1)])
f = r["findings"]["CLAUDE-1"]
check("rewrite after acceptance -> not reassessed, no fabricated objection",
      f["status"] == "not reassessed" and r["counts"]["attacker_objections"] == 0 and not f["retained"], f)
a0 = report(rows=[acc("CLAUDE-1", severity="medium", blocking="no")], peer=P0)
p1 = report(findings=[("CLAUDE-1", "Race between writers")], blockers=["CLAUDE-1"], peer=A0)
r = run([(P0, p0), (A0, a0), (P1, p1)])
f = r["findings"]["CLAUDE-1"]
check("rewrite after opposition -> retained earlier-version objection, still counted",
      f["status"] == "opposed" and f["retained"] and r["counts"]["attacker_objections"] == 1
      and r["counts"]["retained_earlier_version"] == 1, (f, r["counts"]))
a1 = report(rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"], peer=P1)
r = run([(P0, p0), (A0, a0), (P1, p1), (A1, a1)])
check("rewrite after opposition, then explicit acceptance of the current version -> resolved",
      r["findings"]["CLAUDE-1"]["status"] == "agreed" and r["counts"]["attacker_objections"] == 0)

# ── Supplemental objections ────────────────────────────────────────────────────

p0 = report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"])
a0 = report(rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"],
            supplemental=["- CODEX-O1 (CLAUDE-1; fix): raised — the retry duplicates committed exports"], peer=P0)
r = run([(P0, p0), (A0, a0)])
check("supplemental: an objection to the fix with four equal facets is an active disagreement",
      r["findings"]["CLAUDE-1"]["status"] == "opposed" and r["objections"]["CODEX-O1"]["state"] == "active"
      and r["needs_another_round"] and r["counts"]["attacker_objections"] == 1)
p1 = report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"],
            supplemental=["- CODEX-O1: rejected — the retry is idempotent"], peer=A0)
r = run([(P0, p0), (A0, a0), (P1, p1)])
check("supplemental: a rejection by the other reviewer is not a resolution", r["objections"]["CODEX-O1"]["state"] == "active")
a1 = report(rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"],
            supplemental=["- CODEX-O1 (CLAUDE-1; fix): conceded — idempotent, as shown"], peer=P1)
r = run([(P0, p0), (A0, a0), (P1, p1), (A1, a1)])
check("supplemental: the claimant's concession resolves it", r["objections"]["CODEX-O1"]["state"] == "resolved"
      and r["findings"]["CLAUDE-1"]["status"] == "agreed")
p1 = report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"],
            supplemental=["- CODEX-O1: accepted — the fix should dedupe"], peer=A0)
r = run([(P0, p0), (A0, a0), (P1, p1)])
check("supplemental: acceptance of the current version resolves it", r["objections"]["CODEX-O1"]["state"] == "resolved")
a1 = report(rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"],
            supplemental=["- CODEX-O1 (CLAUDE-1; fix): maintained — and the dedupe must cover partial uploads"], peer=P1)
r = run([(P0, p0), (A0, a0), (P1, p1), (A1, a1)])
check("supplemental: a revised objection is not settled by an acceptance of its earlier version",
      r["objections"]["CODEX-O1"]["state"] == "active", r["objections"]["CODEX-O1"])

# ── Unknown legacy positions and the truth table ───────────────────────────────

legacy = {"id": A0, "agent": "codex", "peer_report": P0, "contract": 1,
          "text": p0.replace("Report.", "Legacy.").replace("- **CLAUDE-1 Race**", "- None").split("## Findings")[0]
          + "## Findings\n- None\n\n## Disposition of peer findings\n- CLAUDE-1: accepted — fine\n\n## Merge blockers\n- None\n\n"
          "## Outstanding disputed findings\n- None\n\n" + "\n".join(NOTES) + "\n\nVERDICT: APPROVED\nPEER-AGREEMENT: YES\nPEER-REPORT: %s\n" % P0}
seq = [{"id": P0, "agent": "claude", "peer_report": None, "text": report(findings=[("CLAUDE-1", "Race", "Low")])}, legacy]
r = gencr_adjudicate.adjudicate(seq, "claude", "codex")
f = r["findings"]["CLAUDE-1"]
check("unknown: legacy facets are unknown, never agreed or unanimous, never an objection",
      f["status"] == "unknown" and not r["positions_agree"] and not r["unanimous"] and r["counts"]["attacker_objections"] == 0, f)
check("unknown: unknown alone does not demand another round", not r["needs_another_round"] or r["findings"]["CLAUDE-1"]["status"] != "unknown")

# ── Run-history rules for a new report (check_report) ──────────────────────────

def prior(*pairs):
    seq = []
    for rid, text in pairs:
        peer = text.rstrip("\n").split("\n")[-1].split(": ", 1)[1]
        seq.append({"id": rid, "agent": rid.split("-")[2], "peer_report": None if peer == "N/A" else peer, "text": text})
    return seq


known = {"CLAUDE-1", "CODEX-1"}
p0 = report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"])
a0 = report(rows=[acc("CLAUDE-1", severity="critical")], blockers=["CLAUDE-1"], peer=P0,
            supplemental=["- CODEX-O1 (CLAUDE-1; fix): raised — dedupe"])
p1 = report(withdrawn=["- CLAUDE-1: withdrawn — covered"], supplemental=["- CODEX-O1: rejected — not needed"], peer=A0)
errs = gencr_adjudicate.check_report(p1, "claude", "codex", A0, prior((P0, p0), (A0, a0)), known)
check("check_report: an explicit withdrawal and an answered objection are valid", errs == [], errs)
p2 = report(withdrawn=["- CLAUDE-1: withdrawn — covered"], peer=A1)
a1 = report(rows=[acc("CLAUDE-1", severity="critical", source=P0)], blockers=["CLAUDE-1"], peer=P1,
            supplemental=["- CODEX-O1 (CLAUDE-1; fix): maintained — dedupe"])
errs = gencr_adjudicate.check_report(p2, "claude", "codex", A1, prior((P0, p0), (A0, a0), (P1, p1), (A1, a1)), known)
check("check_report: re-listing an earlier withdrawal is harmless; the open objection still needs an answer",
      len(errs) == 1 and "CODEX-O1" in errs[0], errs)
errs = gencr_adjudicate.check_report(report(withdrawn=["- CLAUDE-9: withdrawn — x"], peer=A0), "claude", "codex", A0,
                                     prior((P0, p0), (A0, a0)), known)
check("check_report: withdrawing a finding never defined is an error, and dropping CLAUDE-1 silently too",
      any("CLAUDE-9" in e for e in errs) and any("CLAUDE-1" in e and "Withdrawn findings" in e for e in errs), errs)
a1_missing = report(blockers=[], peer=P1, supplemental=["- CODEX-O1 (CLAUDE-1; fix): maintained — dedupe"])
errs = gencr_adjudicate.check_report(a1_missing, "codex", "claude", P1, prior((P0, p0), (A0, a0), (P1, p1)), known)
check("check_report: a claim on a finding its author withdrew must be kept or withdrawn explicitly",
      any("hold a claim on CLAUDE-1" in e for e in errs), errs)
a1_bad = report(rows=[acc("CLAUDE-1", severity="critical", source=P0)], blockers=["CLAUDE-1"], peer=P1,
                supplemental=["- CODEX-O1 (CLAUDE-1; fix): raised — again", "- CODEX-O2 (CLAUDE-1; fix): maintained — new",
                              "- CLAUDE-O5: accepted — no such objection"])
errs = gencr_adjudicate.check_report(a1_bad, "codex", "claude", P1, prior((P0, p0), (A0, a0), (P1, p1)), known)
check("check_report: objection IDs follow their status rules and responses answer open objections only",
      any("CODEX-O1 was raised before" in e for e in errs) and any("CODEX-O2 is new" in e for e in errs)
      and any("CLAUDE-O5" in e for e in errs), errs)

# ── Validation of the adjudication object ──────────────────────────────────────

p0 = report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"])
a0 = report(rows=[acc("CLAUDE-1", severity="medium", blocking="no")], peer=P0)
good = run([(P0, p0), (A0, a0)])
invs = invocations([(P0, p0), (A0, a0)])


def problems(adj, outcome="REQUEST CHANGES", records=None, primary="claude", attacker="codex"):
    return gencr_adjudicate.validate(adj, invs if records is None else records, outcome, primary, attacker)


check("validate: a valid authority adjudication passes", problems(good) == [], problems(good))
import copy  # noqa: E402
for name, edit, outcome in (
        ("unsupported version", lambda d: d.update(version=9), "REQUEST CHANGES"),
        ("unknown primary report", lambda d: d.update(primary_report="99-round9-claude-reconcile"), "REQUEST CHANGES"),
        ("outcome is not the primary verdict", lambda d: None, "APPROVED"),
        ("unanimous with objections", lambda d: d.update(unanimous=True), "REQUEST CHANGES"),
        ("count does not match the findings", lambda d: d["counts"].update(attacker_objections=0), "REQUEST CHANGES"),
        ("wrong type", lambda d: d.update(findings=[]), "REQUEST CHANGES")):
    bad = copy.deepcopy(good)
    edit(bad)
    check("validate: %s is rejected" % name, problems(bad, outcome) != [])
apair = [(P0, report(findings=[("CLAUDE-1", "Race", "Low")])),
         (A0, report(rows=[acc("CLAUDE-1", severity="high", blocking="yes")], blockers=["CLAUDE-1"], peer=P0))]
appr = run(apair)
check("validate: primary APPROVED with attacker RC is valid (no indirect veto)",
      appr["primary_verdict"] == "APPROVED" and problems(appr, "APPROVED", invocations(apair)) == [],
      problems(appr, "APPROVED", invocations(apair)))

# ── Implementation review 1 regressions (SD-I1..SD-I5) ─────────────────────────


def order_ids(primary, attacker):
    return ("01-round0-%s-initial" % primary, "02-round0-%s-attack" % attacker, "03-round1-%s-reconcile" % primary,
            "04-round1-%s-respond" % attacker, "05-round1-%s-reconcile" % primary)


sys.path.insert(0, os.path.join(sys.argv[1], "bin"))
import gencr_summary  # noqa: E402

for primary, attacker in (("claude", "codex"), ("codex", "claude")):
    q0, b0, q1, b1, q2 = order_ids(primary, attacker)
    PF, AF, OID = primary.upper() + "-1", attacker.upper() + "-1", attacker.upper() + "-O1"
    tag = "%s primary" % primary

    # SD-I1: the primary promotes its unchanged finding to a blocker after the attacker accepted it as not blocking.
    s0 = report(findings=[(PF, "Race", "High")])
    t0 = report(findings=[(AF, "Leak")], rows=[acc(PF, blocking="no")], blockers=[AF], peer=q0)
    s1 = report(findings=[(PF, "Race", "High")], rows=[acc(AF)], blockers=[PF, AF], peer=b0)
    r = run([(q0, s0), (b0, t0), (q1, s1)], primary, attacker)
    f = r["findings"][PF]
    check("SD-I1 %s: a blocking-only promotion is a new version the attacker has not assessed (never agreed)" % tag,
          f["status"] == "not reassessed" and f["positions"][attacker]["assessed_version"] == "earlier"
          and not r["unanimous"] and not r["positions_agree"] and r["needs_another_round"], (f, r["counts"]))
    line = gencr_summary.facet_line(f, r, "blocking", "blocks merge")
    check("SD-I1 %s: differing blocking values are never labelled agreed for the current version" % tag,
          "(agreed)" not in line and "earlier version" in line, line)
    check("SD-I1 %s: the history records the promotion as a modification" % tag,
          [h["event"] for h in f["history"] if h["agent"] == primary] == ["raised", "modified"], f["history"])
    t1 = report(findings=[(AF, "Leak")], rows=[acc(PF, blocking="yes")], blockers=[PF, AF], peer=q1)
    r = run([(q0, s0), (b0, t0), (q1, s1), (b1, t1)], primary, attacker)
    check("SD-I1 %s: genuine convergence after the promotion -> agreed and unanimous" % tag,
          r["findings"][PF]["status"] == "agreed" and r["unanimous"] and not r["needs_another_round"],
          (r["findings"][PF], r["counts"]))

    # Demotion without text changes, after the attacker accepted it as blocking.
    s0 = report(findings=[(PF, "Race", "High")], blockers=[PF])
    t0 = report(rows=[acc(PF, blocking="yes")], blockers=[PF], peer=q0)
    s1 = report(findings=[(PF, "Race", "High")], peer=b0)
    r = run([(q0, s0), (b0, t0), (q1, s1)], primary, attacker)
    check("SD-I1 %s: a blocking-only demotion is not reassessed, never agreed or unanimous" % tag,
          r["findings"][PF]["status"] == "not reassessed" and not r["unanimous"] and r["needs_another_round"],
          r["findings"][PF])
    t1 = report(rows=[acc(PF, blocking="no")], peer=q1)
    r = run([(q0, s0), (b0, t0), (q1, s1), (b1, t1)], primary, attacker)
    check("SD-I1 %s: the attacker accepting the demotion -> agreed" % tag,
          r["findings"][PF]["status"] == "agreed" and r["unanimous"], r["findings"][PF])
    # An opposition on the earlier blocking position stays an objection until the attacker reassesses.
    t0 = report(rows=[acc(PF, blocking="no", why="not blocking")], peer=q0)
    r = run([(q0, s0), (b0, t0), (q1, s1)], primary, attacker)
    f = r["findings"][PF]
    check("SD-I1 %s: an opposition to the earlier blocking position is retained after a blocking-only change" % tag,
          f["status"] == "opposed" and f["retained"] and r["counts"]["retained_earlier_version"] == 1, (f, r["counts"]))

    # SD-I2: the latest applicable response decides a supplemental objection.
    raise_o = "- %s (%s; fix): raised — the retry duplicates committed exports" % (OID, PF)
    keep_o = "- %s (%s; fix): maintained — the retry duplicates committed exports" % (OID, PF)
    revise_o = "- %s (%s; fix): maintained — and partial uploads are duplicated too" % (OID, PF)
    s0 = report(findings=[(PF, "Race")], blockers=[PF])
    t0 = report(rows=[acc(PF)], blockers=[PF], supplemental=[raise_o], peer=q0)

    def chain(first, second, revised=False, verdict=None):
        s1 = report(findings=[(PF, "Race")], blockers=[PF], supplemental=["- %s: %s — first answer" % (OID, first)], peer=b0)
        t1 = report(rows=[acc(PF)], blockers=[PF], supplemental=[revise_o if revised else keep_o], peer=q1)
        s2 = report(findings=[(PF, "Race")], blockers=[PF],
                    supplemental=["- %s: %s — RETRY_IS_IDEMPOTENT_AFTER_RECHECK" % (OID, second)], peer=b1)
        return run([(q0, s0), (b0, t0), (q1, s1), (b1, t1), (q2, s2)], primary, attacker)

    r = chain("accepted", "rejected")
    o = r["objections"][OID]
    check("SD-I2 %s: accepted then rejected (unchanged objection) -> active; the rejection is the latest response" % tag,
          o["state"] == "active" and o["resolution"] is None and r["findings"][PF]["status"] == "opposed"
          and not r["unanimous"] and r["needs_another_round"] and r["counts"]["supplemental_active"] == 1
          and o["latest_response"]["status"] == "rejected" and o["latest_response"]["report"] == q2
          and o["latest_response"]["version"] == "current", o)
    r = chain("rejected", "accepted")
    check("SD-I2 %s: rejected then accepted -> resolved by the later acceptance" % tag,
          r["objections"][OID]["state"] == "resolved" and q2 in r["objections"][OID]["resolution"], r["objections"][OID])
    r = chain("accepted", "rejected", revised=True)
    check("SD-I2 %s: accepted, revised, then rejected -> active" % tag, r["objections"][OID]["state"] == "active",
          r["objections"][OID])
    r = chain("rejected", "accepted", revised=True)
    check("SD-I2 %s: rejected, revised, then accepted -> resolved by the acceptance of the revised version" % tag,
          r["objections"][OID]["state"] == "resolved", r["objections"][OID])
    s1 = report(findings=[(PF, "Race")], blockers=[PF], supplemental=["- %s: accepted — first answer" % OID], peer=b0)
    t1 = report(rows=[acc(PF)], blockers=[PF], supplemental=[revise_o], peer=q1)
    r = run([(q0, s0), (b0, t0), (q1, s1), (b1, t1)], primary, attacker)
    lr = r["objections"][OID]["latest_response"]
    check("SD-I2 %s: a response to an earlier version of the objection is labelled as such" % tag,
          r["objections"][OID]["state"] == "active" and lr["report"] == q1 and lr["version"] == "earlier", lr)
    # APPROVED primary: the reversal keeps the run non-unanimous (the verdict stays the primary's).
    s0a = report(findings=[(PF, "Race", "Low")])
    t0a = report(rows=[acc(PF, severity="low", blocking="no")], supplemental=[raise_o], peer=q0)
    s1a = report(findings=[(PF, "Race", "Low")], supplemental=["- %s: accepted — first answer" % OID], peer=b0)
    t1a = report(rows=[acc(PF, severity="low", blocking="no")], supplemental=[keep_o], peer=q1)
    s2a = report(findings=[(PF, "Race", "Low")], supplemental=["- %s: rejected — RETRY_IS_IDEMPOTENT_AFTER_RECHECK" % OID],
                 peer=b1)
    r = run([(q0, s0a), (b0, t0a), (q1, s1a), (b1, t1a), (q2, s2a)], primary, attacker)
    check("SD-I2 %s: APPROVED primary after the reversal -> APPROVED, NOT UNANIMOUS, one objection" % tag,
          r["primary_verdict"] == "APPROVED" and not r["unanimous"] and r["counts"]["attacker_objections"] == 1
          and "NOT UNANIMOUS" in gencr_summary.qualification(r), (r["counts"], gencr_summary.qualification(r)))

# SD-I4: typed, bound and recomputed validation; malformed shapes give a reason, never an exception.
p0 = report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"])
a0 = report(rows=[acc("CLAUDE-1", severity="medium", blocking="no")], peer=P0,
            supplemental=["- CODEX-O1 (CLAUDE-1; fix): raised — dedupe"])
pair = [(P0, p0), (A0, a0)]
good = run(pair)
records = invocations(pair)


def recount(d):
    d["counts"], d["positions_agree"] = gencr_adjudicate.summarize(d["findings"], d["objections"])


def set_status(d, status):
    d["findings"]["CLAUDE-1"]["status"] = status
    d["objections"]["CODEX-O1"]["state"] = "resolved"
    d["findings"]["CLAUDE-1"]["objections"] = []
    recount(d)
    d["unanimous"] = d["positions_agree"] and d["verdicts_agree"]


for name, edit in (
        ("a blocking position given as the string 'yes'",
         lambda d: d["findings"]["CLAUDE-1"]["positions"]["codex"].update(blocking="yes")),
        ("an attacker verdict outside the vocabulary (with matching flags)",
         lambda d: d.update(attacker_verdict="BANANA", verdicts_agree=False)),
        ("the primary report pointing at the attacker's report", lambda d: d.update(primary_report=A0)),
        ("needs_another_round given as the string 'false'", lambda d: d.update(needs_another_round="false")),
        ("needs_another_round false while an objection is active", lambda d: d.update(needs_another_round=False)),
        ("a stored status contradicting the positions (with recomputed counts)", lambda d: set_status(d, "agreed")),
        ("a facet state contradicting the positions", lambda d: d["findings"]["CLAUDE-1"]["facets"].update(severity="agreed")),
        ("an objection marked resolved without a resolution in its history",
         lambda d: (d["objections"]["CODEX-O1"].update(state="resolved"), recount(d))),
        ("a position on a report of the other reviewer",
         lambda d: d["findings"]["CLAUDE-1"]["positions"]["codex"].update(report=P0)),
        ("roles swapped", lambda d: d.update(primary="codex", attacker="claude")),
        ("a finding that is not an object", lambda d: d["findings"].update({"CLAUDE-1": "agreed"})),
        ("positions that are not objects", lambda d: d["findings"]["CLAUDE-1"].update(positions="x")),
        ("a missing position field", lambda d: d["findings"]["CLAUDE-1"]["positions"]["claude"].pop("severity")),
        ("an objection history that is not a list", lambda d: d["objections"]["CODEX-O1"].update(history=7)),
        ("counts holding a boolean", lambda d: d["counts"].update(agreed=False))):
    bad = copy.deepcopy(good)
    edit(bad)
    try:
        found = gencr_adjudicate.validate(bad, records, "REQUEST CHANGES", "claude", "codex")
    except Exception as error:  # noqa: BLE001 — the test is that nothing escapes
        found = "raised %s" % type(error).__name__
    check("SD-I4 validate: %s is rejected with a reason" % name, isinstance(found, list) and found != [], found)
bad = copy.deepcopy(good)
bad["objections"]["CODEX-O1"]["history"][0]["report"] = [A0]  # unhashable: a lookup in the validator would raise
try:
    found = gencr_adjudicate.validate(bad, records, "REQUEST CHANGES", "claude", "codex")
except Exception as error:  # noqa: BLE001 — the test is that nothing escapes
    found = "raised %s" % type(error).__name__
check("SD-I4 validate: a shape that makes the checks themselves fail gives a reason, not an exception",
      isinstance(found, list) and found != [], found)
check("SD-I4 validate: the package's roles bind the adjudication",
      gencr_adjudicate.validate(good, records, "REQUEST CHANGES", "codex", "claude") != [])
check("SD-I4 validate: an attacker verdict that is not its latest report's verdict is rejected",
      gencr_adjudicate.validate(good, [dict(records[0]), dict(records[1], verdict="REQUEST CHANGES")],
                                "REQUEST CHANGES", "claude", "codex") != [])
for junk in (None, [], "x", {"version": 1, "rule": "primary-authority", "findings": {"A": []}, "objections": {},
                             "counts": {}}):
    try:
        found = gencr_adjudicate.validate(junk, records, "REQUEST CHANGES", "claude", "codex")
    except Exception as error:  # noqa: BLE001
        found = "raised %s" % type(error).__name__
    check("SD-I4 validate: malformed shape %r gives a reason, not an exception" % (junk if junk is None else type(junk).__name__),
          isinstance(found, list) and found != [], found)

import gencr_support  # noqa: E402
meta = {"invocations": [dict(r, role="x") for r in records], "outcome": "REQUEST CHANGES", "primary": "claude",
        "adversary": "codex", "adjudication": good}
check("SD-I4 package: a consistent package passes", gencr_support.adjudication_problem(meta, {"adjudication": copy.deepcopy(good)}) is None,
      gencr_support.adjudication_problem(meta, {"adjudication": good}))
other = copy.deepcopy(good)
other["findings"]["CLAUDE-1"]["primary_response"] = {"report": P0, "text": "edited"}
check("SD-I4 package: metadata and findings.json adjudications that differ are rejected",
      gencr_support.adjudication_problem(meta, {"adjudication": other}) is not None)
check("SD-I4 package: a findings.json without the adjudication is rejected",
      gencr_support.adjudication_problem(meta, {}) is not None)

# SD-I4-R1: current-version consistency and chronology are bound, not only types and roles.
p0 = report(findings=[("CLAUDE-1", "Race", "Low")])
a0 = report(rows=[acc("CLAUDE-1", "yes", "low", "no")], peer=P0, agreement="YES")
pair = [(P0, p0), (A0, a0)]
clean = run(pair)
records = invocations(pair)
check("SD-I4-R1: the clean unanimous APPROVED adjudication validates",
      clean["unanimous"] and gencr_adjudicate.validate(clean, records, "APPROVED", "claude", "codex") == [])
for facet, value in (("introduced", "no"), ("severity", "high"), ("blocking", True)):
    bad = copy.deepcopy(clean)
    bad["findings"]["CLAUDE-1"]["positions"]["claude"][facet] = value
    found = gencr_adjudicate.validate(bad, records, "APPROVED", "claude", "codex")
    check("SD-I4-R1: a current author %s that contradicts the current-version assessment is rejected" % facet,
          found != [], found)
for name, edit in (("a position order that is not its report's invocation order",
                    lambda d: d["findings"]["CLAUDE-1"]["positions"]["codex"].update(order=999)),
                   ("version true (a boolean, not the integer version)", lambda d: d.update(version=True))):
    bad = copy.deepcopy(clean)
    edit(bad)
    check("SD-I4-R1: %s is rejected" % name, gencr_adjudicate.validate(bad, records, "APPROVED", "claude", "codex") != [])

# The five-report response reversal: reordering the stored responses (and recomputing the derived state with the
# production helpers) must not turn the later rejection into an earlier one.
s0 = report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"])
t0 = report(rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"], peer=P0,
            supplemental=["- CODEX-O1 (CLAUDE-1; fix): raised — the retry duplicates committed exports"])
s1 = report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"], peer=A0,
            supplemental=["- CODEX-O1: accepted — first answer"])
t1 = report(rows=[acc("CLAUDE-1")], blockers=["CLAUDE-1"], peer=P1,
            supplemental=["- CODEX-O1 (CLAUDE-1; fix): maintained — the retry duplicates committed exports"])
s2 = report(findings=[("CLAUDE-1", "Race")], blockers=["CLAUDE-1"], peer=A1,
            supplemental=["- CODEX-O1: rejected — RETRY_IS_IDEMPOTENT_AFTER_RECHECK"])
seq = [(P0, s0), (A0, t0), (P1, s1), (A1, t1), (P2, s2)]
rev = run(seq)
records = invocations(seq)
check("SD-I4-R1: the reversal adjudication (objection active) validates",
      rev["objections"]["CODEX-O1"]["state"] == "active"
      and gencr_adjudicate.validate(rev, records, "REQUEST CHANGES", "claude", "codex") == [])


def rederive(d):
    o = d["objections"]["CODEX-O1"]
    d["objections"]["CODEX-O1"] = gencr_adjudicate.objection("CODEX-O1", o["history"], o["responses"])
    f = d["findings"]["CLAUDE-1"]
    active = [oid for oid, x in d["objections"].items() if x["state"] == "active"]
    f["live"], f["status"], f["facets"], f["retained"] = gencr_adjudicate.derive("claude", "codex", f["positions"], active)
    f["objections"] = active
    d.update(gencr_adjudicate.flags(d))


for name, edit in (("responses stored in reverse order", lambda o: o["responses"].reverse()),
                   ("a duplicated response", lambda o: o["responses"].append(dict(o["responses"][0]))),
                   ("claimant rows stored in reverse order", lambda o: o["history"].reverse()),
                   ("a response that names a report it did not answer",
                    lambda o: o["responses"][-1].update(answered=A0)),
                   ("a response by the claimant itself", lambda o: o["responses"][-1].update(agent="codex", report=A1))):
    bad = copy.deepcopy(rev)
    edit(bad["objections"]["CODEX-O1"])
    rederive(bad)
    try:
        found = gencr_adjudicate.validate(bad, records, "REQUEST CHANGES", "claude", "codex")
    except Exception as error:  # noqa: BLE001
        found = "raised %s" % type(error).__name__
    check("SD-I4-R1: %s is rejected (chronology bound to the invocations)" % name, isinstance(found, list) and found != [],
          (found, bad["objections"]["CODEX-O1"]["state"]))

# Every adjudication built in this file validates against its own invocation records and roles.
bad_runs = [(a["primary_report"], gencr_adjudicate.validate(a, recs, a["primary_verdict"], p, q))
            for a, recs, p, q in PRODUCED if gencr_adjudicate.validate(a, recs, a["primary_verdict"], p, q)]
check("validate: all %d adjudications built by these tests validate" % len(PRODUCED), not bad_runs, bad_runs[:3])

print("\n%d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
