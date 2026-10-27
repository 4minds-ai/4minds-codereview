"""Contract-v2 reviewer report builder shared by the adjudication tests (unit and end-to-end)."""

NOTES = ["## Review notes", "- Verified clean: None", "- Unresolved risks: None", "- Disproven claims: None",
         "- Test gaps: None", "- Out-of-scope ownership changes: None", "- Other observations: None"]
ACC = "%s: %s; introduced: %s; severity: %s; blocking: %s — %s"


def finding(fid, title, severity="High", introduced="yes", problem="problem", evidence=None, fix=None, file="app.py:1"):
    return ["- **%s %s**" % (fid, title), "  - Severity: %s" % severity, "  - Introduced by this change: %s" % introduced,
            "  - File: %s" % file, "  - Problem: %s" % problem, "  - Evidence: %s" % (evidence or "evidence for " + fid),
            "  - Expected vs actual: expected vs actual", "  - Tests: none", "  - Fix: %s" % (fix or "fix " + fid)]


def report(findings=(), rows=(), blockers=(), withdrawn=(), supplemental=(), disputes=(), verdict=None,
           peer="N/A", agreement=None, extra_sections=()):
    lines = ["Report.", "", "## Findings"]
    for f in findings:
        lines += finding(*f) if isinstance(f, tuple) else finding(**f)
    if not findings:
        lines.append("- None")
    lines += ["", "## Withdrawn findings"] + (list(withdrawn) or ["- None"])
    lines += ["", "## Disposition of peer findings"] + (list(rows) or ["- None"])
    lines += ["", "## Merge blockers"] + (["- " + b for b in blockers] or ["- None"])
    lines += ["", "## Supplemental objections"] + (list(supplemental) or ["- None"])
    lines += ["", "## Outstanding disputed findings"] + (list(disputes) or ["- None"])
    for section in extra_sections:
        lines += [""] + list(section)
    lines += [""] + NOTES
    verdict = verdict or ("REQUEST CHANGES" if blockers else "APPROVED")
    agreement = agreement or ("N/A" if peer == "N/A" else "NO")
    lines += ["", "VERDICT: " + verdict, "PEER-AGREEMENT: " + agreement, "PEER-REPORT: " + peer]
    return "\n".join(lines) + "\n"


def acc(fid, introduced="yes", severity="high", blocking="yes", why="verified", status="accepted", source=None):
    head = fid if source is None else "%s (report %s)" % (fid, source)
    return "- " + ACC % (head, status, introduced, severity, blocking, why)


def schedule(primary, attacker):
    """The engine's full invocation schedule (cap of three rounds): [(report ID, agent, answered report or "N/A")]."""
    steps = [(0, primary, "initial"), (0, attacker, "attack"), (1, primary, "reconcile")]
    for rnd in (1, 2, 3):
        steps += [(rnd, attacker, "respond"), (rnd, primary, "reconcile")]
    out, previous = [], "N/A"
    for index, (rnd, agent, phase) in enumerate(steps, 1):
        rid = "%02d-round%d-%s-%s" % (index, rnd, agent, phase)
        out.append((rid, agent, previous))
        previous = rid
    return out
