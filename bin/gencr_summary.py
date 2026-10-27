"""The GitHub-ready review comment of a gencr review: one deterministic, bounded, display-safe block rendered from the
final consolidated results. It is saved once in summary.md between BEGIN/END markers; the local terminal prints it and
the CI PR comment wraps it, byte for byte. Standard library only (Python 3.8+).

Contract (agreed design, round 3):
- The reserved part (verdict, convergence warning, mode and scope, reviewed SHA, models, merge-blocker total and
  overflow statement, closing instruction) is always present.
- Every merge blocker gets an index line with its attribution and finding-level assessment until the budget is full;
  beyond that the block states how many were not shown (with their IDs when they fit) and never implies completeness.
- A recommended fix is shown verbatim (plain lines, or a fenced block when it holds text GitHub would interpret) or
  omitted as a whole with a reference to the complete report; it is never cut or rewritten.
- Only prose (titles, file references, dispute lines, errors, model names) is neutralized, outside code spans.
"""

import re

BEGIN = "<!-- gencr:review-comment:begin -->"
END = "<!-- gencr:review-comment:end -->"
FRAME_BEGIN = "========== GITHUB REVIEW COMMENT =========="
FRAME_END = "========== END REVIEW COMMENT =========="
BUDGET = 40000  # characters; the CI wrapper needs < 2,000 of its 60,000-character comment limit
TITLE_LIMIT = 200
OTHER_LIMIT = 5
SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3, "unknown": 4}
NAMES = {"claude": "Claude", "codex": "Codex"}
ZWSP = "​"


def id_key(identifier):
    prefix, _, number = identifier.partition("-")
    return (prefix, int(number) if number.isdigit() else 0)


SHORTENED = " … (full value in the complete review report)"


def clip(text, limit):
    """(value, note): one line (any line break becomes a space) of at most `limit` characters, and the visible
    shortening note when it was cut."""
    text = re.sub(r"\s*[\r\n]+\s*", " ", text or "")
    return (text, "") if len(text) <= limit else (text[:limit], SHORTENED)


def escape_prose(text):
    """Text without backticks: GitHub renders exactly these characters (no HTML, entities, comments or backslash
    escapes) and mentions notify nobody."""
    text = text.replace("\\", "\\\\").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return re.sub(r"@(?=[A-Za-z0-9-])", "@" + ZWSP, text)


def literal(text):
    """Text as one inline code span whose rendered content is exactly `text`: the backtick delimiter is longer than
    any run inside, and one padding space on each side is stripped again by CommonMark renderers. Mentions and HTML
    are inert inside code, and no inner backtick can pair with anything outside."""
    fence = "`" * (max(len(run) for run in re.findall(r"`+", text)) + 1)
    return "%s %s %s" % (fence, text, fence)


def prose(text, limit=500):
    """Untrusted display text on one bounded line. A value containing backticks (code, or delimiters that would bind
    unpredictably) is shown as one literal code span; any other value is escaped so it renders as written."""
    value, note = clip(text, limit)
    shown = literal(value) if "`" in value else escape_prose(value)
    return ("\\" + shown if shown.startswith("==========") else shown) + note


def title_of(finding):
    return prose(finding.get("title") or "", TITLE_LIMIT)


def fix_lines(label, fix):
    """A recommended fix verbatim in a literal fenced block (GitHub renders nothing inside it), or a reference to the
    complete report when it cannot be shown unambiguously. Never cut or rewritten."""
    if fix is None or fix == "":
        return ["  - %s: not given" % label]
    lines = fix.split("\n")
    if "gencr:review-comment" in fix or any(line.strip() in (FRAME_BEGIN, FRAME_END) for line in lines):
        return ["  - %s: see the complete review report (it cannot be shown here unambiguously)" % label]
    longest = max((len(run) for run in re.findall(r"`+", fix)), default=0)
    fence = "`" * max(3, longest + 1)
    return (["  - %s:" % label, "", "    " + fence] + [("    " + line) if line else "" for line in lines]
            + ["    " + fence])


def details_lines(finding):
    lines = []
    if finding.get("file"):
        lines.append("  - File: " + prose(finding["file"], 300))
    fixes = finding["fixes"]
    for agent, fix in fixes:
        lines += fix_lines("Recommended fix" if len(fixes) == 1 else "Recommended fix (%s)" % NAMES[agent], fix)
    return lines


def index_line(finding):
    parts = ["listed as a merge blocker by " + " and ".join(NAMES[a] for a in finding["listed_by"])] \
        if finding["blocker"] else ["reported by " + " and ".join(NAMES[a] for a in finding["reporters"])]
    parts.append(finding["assessment"])
    if finding.get("differs"):
        parts.append("the reviewers' definitions differ (see the complete review report)")
    line = "- **%s** %s (%s) — %s" % (finding["id"], title_of(finding), finding["severity"], "; ".join(parts))
    if finding["blocker"] and finding.get("contested"):
        line += " — resolve before merge: fix it or settle the dispute"
    return line


OMITTED_NOTE = "  - Details: see the complete review report (too long for this comment)"
SECTION_NOTE_ROOM = 120  # reserved per optional section for its "+N more" / "not shown" line


def size(lines):
    return sum(len(line) + 1 for line in lines)


def blocker_total_line(total, shown):
    if shown == total:
        return "- Merge blockers: %d" % total
    return ("- Merge blockers: %d — this summary lists %d of %d; the other %d are not shown here (see the complete "
            "review report)" % (total, shown, total, total - shown))


def more_blockers_line(hidden, with_ids):
    if with_ids:
        return "- +%d more merge blockers: %s" % (len(hidden), ", ".join(f["id"] for f in hidden))
    return "- +%d more merge blockers (their IDs are in the complete review report)" % len(hidden)


def head_lines(data):
    outcome, convergence = data["outcome"], data.get("convergence")
    if outcome in ("APPROVED", "REQUEST CHANGES", "UNRESOLVED DISAGREEMENT"):
        head = ["## Code review: %s" % outcome]
    else:
        head = ["## Code review: %s — no valid approval or rejection was produced" % prose(outcome, 100)]
        if data.get("error"):
            head.append("- Reason: " + prose(data["error"], 500))
    if outcome == "UNRESOLVED DISAGREEMENT" or convergence == "limit":
        head.append("- **Claude and Codex did not reach agreement**: the reconciliation limit (%s rounds) was reached "
                    "with disagreement remaining.%s" % (data["max_rounds"], "" if data["disputes"] else
                                                       " No specific disputed findings were listed by either reviewer."))
    if outcome == "UNRESOLVED DISAGREEMENT":
        head.append("- Final verdicts: " + "; ".join("%s: %s" % (NAMES[a], data["verdicts"][a]) for a in data["agents"]))
    if convergence == "single":
        head.append("- Single reviewer (%s); there was no second assessment." % NAMES[data["agents"][0]])
    elif convergence == "agreed":
        head.append("- The reviewers reported overall agreement on the result; the position on each finding is shown "
                    "with it.")
    head += ["- Mode: %s — %s" % (prose(data["review_mode"], 20), prose(data["approval_scope_label"], 300)),
             "- Reviewed commit: %s" % prose(data["head_sha"], 64),
             "- Models: " + "; ".join("%s: %s" % (NAMES[a], prose(data["models"][a], 200)) for a in ("claude", "codex"))]
    return head


def render(data, budget=BUDGET):
    """Returns the review-comment block (without markers) for `data` (assembled by gencr_support.build_package)."""
    if data.get("adjudication"):
        return render_adjudicated(data, budget)
    outcome = data["outcome"]
    head = head_lines(data)
    if outcome not in ("APPROVED", "REQUEST CHANGES", "UNRESOLVED DISAGREEMENT"):
        if data["surviving_findings"]:
            head.append("- %d findings were reported before the review stopped; they are in the complete review "
                        "report and are not a review result." % data["surviving_findings"])
        return finish(head + ["", "Re-run the review: this result is neither an approval nor a rejection."], budget)
    footer = ("No merge blockers were reported. The complete review report lists any remaining lower-severity notes."
              if outcome == "APPROVED" else
              "Please address every finding in the complete review report, not only those listed here: fix it, or "
              "reply with the reason it does not apply. Disputed findings need a decision before merge.")

    findings = sorted(data["findings"], key=lambda f: (SEVERITY_ORDER.get(f["severity"], 4), id_key(f["id"])))
    blockers = [f for f in findings if f["blocker"]]
    others = [f for f in findings if not f["blocker"] and f["severity"] in ("critical", "high", "medium")]
    disputes = ["- %s (%s)" % (prose(line, 500), NAMES[agent]) for agent, line in data["disputes"]]
    total = len(blockers)

    # 1. Reserved: head, the worst-case total line, headings, the worst-case "+N more" line, room for each optional
    #    section's own note, footer. 2. Index lines (each with room for its omitted-details note) in rank order.
    worst_more = more_blockers_line(blockers, False) if total else ""
    reserved = (size(head) + size([blocker_total_line(total, 0)]) + size(["", "### Merge blockers", ""])
                + size([worst_more]) + 2 * SECTION_NOTE_ROOM + size(["", footer]))
    rest = budget - reserved
    shown = []
    for f in blockers:
        cost = size([index_line(f), OMITTED_NOTE])
        if cost > rest:
            break
        shown.append(f)
        rest -= cost
    hidden = blockers[len(shown):]
    more = []
    if hidden:
        with_ids = more_blockers_line(hidden, True)
        if size([with_ids]) <= size([worst_more]) + rest:
            rest -= max(0, size([with_ids]) - size([worst_more]))
            more = [with_ids]
        else:
            more = [more_blockers_line(hidden, False)]

    # 3. Details (file + verbatim fix) of shown blockers in rank order, each as a whole unit or replaced by the note.
    body = ["", "### Merge blockers", ""] if total else []
    for f in shown:
        body.append(index_line(f))
        detail = details_lines(f)
        extra = size(detail) - size([OMITTED_NOTE])
        if extra <= rest:
            body += detail
            rest -= extra
        else:
            body.append(OMITTED_NOTE)
    body += more

    # 4./5. Optional sections, whole units only, with explicit accounting of what is not shown.
    rest += 2 * SECTION_NOTE_ROOM
    for heading, items, beyond, noun in (
            ("Other significant findings", others[:OTHER_LIMIT], max(0, len(others) - OTHER_LIMIT), "significant findings"),
            ("Disputed or unresolved", disputes, 0, "disputed items")):
        if not items:
            continue
        rest -= SECTION_NOTE_ROOM
        section = ["", "### " + heading, ""]
        if size(section) > rest:
            body += ["", "- %d %s are not shown here (see the complete review report)." % (len(items) + beyond, noun)]
            continue
        rest -= size(section)
        cut = 0
        for item in items:
            if isinstance(item, dict):
                unit = [index_line(item)] + details_lines(item)
                if size(unit) > rest:
                    unit = [index_line(item), OMITTED_NOTE]
            else:
                unit = [item]
            if size(unit) > rest:
                cut += 1
                continue
            section += unit
            rest -= size(unit)
        if cut + beyond:
            section.append("- +%d more %s in the complete review report" % (cut + beyond, noun))
        body += section

    return finish(head + [blocker_total_line(total, len(shown))] + body + ["", footer], budget)


def finish(lines, budget):
    """The block, after the invariants every consumer relies on: within budget, no structural or frame marker line."""
    block = "\n".join(lines) + "\n"
    if len(block) > budget:
        raise ValueError("review comment exceeds its budget (%d > %d)" % (len(block), budget))
    if any(line in (BEGIN, END) or line.strip() in (FRAME_BEGIN, FRAME_END) for line in block.split("\n")):
        raise ValueError("review comment would contain a marker line")
    return block


def safe_render(data, budget=BUDGET):
    """render(), or — should its invariants ever fail — a minimal block worded only by gencr, so that presentation can
    never cost the review its saved package."""
    try:
        return render(data, budget)
    except ValueError:
        adj = data.get("adjudication")
        if adj:
            # Never degrades to a plain or unanimous verdict: the qualification, the count and the disclosure stay.
            return ("## Code review: %s\n- %s\n- Verdicts: %s\n- Attacker objections: %d\n- The review comment could "
                    "not be rendered safely within its limits; every attacker objection and finding is in the complete "
                    "review report.\n\nPlease read the complete review report.\n" % (
                        prose(adj["primary_verdict"], 40), prose(qualification(adj), 300), prose(verdicts_line(adj), 300),
                        adj["counts"]["attacker_objections"]))
        blockers = len({f["id"] for f in data["findings"] if f["blocker"]})
        return ("## Code review: %s\n- The review comment could not be rendered safely within its limits; see the "
                "complete review report.\n- Mode: %s\n- Merge blockers: %d\n\nPlease address every finding in the "
                "complete review report.\n" % (prose(data["outcome"], 40), prose(data["review_mode"], 20), blockers))


def extract(summary_text):
    """The block between the single BEGIN/END marker pair of summary.md; ValueError if malformed."""
    lines = summary_text.split("\n")
    if lines.count(BEGIN) != 1 or lines.count(END) != 1 or lines.index(BEGIN) > lines.index(END):
        raise ValueError("summary.md has no single well-formed review comment block")
    start, end = lines.index(BEGIN), lines.index(END)
    return "\n".join(lines[start + 1:end]) + "\n"


# ── Primary-reviewer authority (adjudicated two-reviewer reviews) ─────────────
#
# One adjudication object (gencr_adjudicate) feeds every view. The comment always shows the verdict with its
# qualification (unanimous or "APPROVED by primary reviewer — NOT UNANIMOUS; N attacker objections remain."), both
# verdicts and the total objection count; then the complete objection index (ranked first), bounded excerpts (evidence,
# fix, the primary's response, the attacker's latest dated statement), the primary's merge blockers and other
# findings. Whatever does not fit is disclosed with numbers; the full report and findings.json are never shortened.

EXCERPT = 800
FACET_LABELS = (("existence", "exists"), ("introduced", "introduced by this change"), ("severity", "severity"),
                ("blocking", "blocks merge"))


def qualification(adj):
    verdict, n = adj["primary_verdict"], adj["counts"]["attacker_objections"]
    if adj["unanimous"]:
        return "%s — unanimous: both reviewers %s and agree on every finding." % (
            verdict, "approve" if verdict == "APPROVED" else "request changes")
    return "%s by primary reviewer — NOT UNANIMOUS; %d attacker objections remain." % (verdict, n)


def verdicts_line(adj):
    return "%s (primary): %s; %s (attacker): %s" % (NAMES[adj["primary"]], adj["primary_verdict"],
                                                     NAMES[adj["attacker"]], adj["attacker_verdict"])


def _value(position, facet):
    if position is None:
        return "not assessed"
    value = position.get(facet)
    if facet == "existence":
        return value or "—"
    if value is None:
        return "—"
    return ("yes" if value else "no") if facet == "blocking" else str(value)


def facet_line(f, adj, facet, label):
    order = [adj["primary"], adj["attacker"]]
    parts = ", ".join("%s: %s" % (NAMES[a], _value(f["positions"].get(a), facet)) for a in order)
    state = f["facets"].get(facet, "n/a")
    peer = f["positions"].get([a for a in order if a != f["author"]][0]) or {}
    if state in ("agreed", "opposed") and not f["withdrawn"] and peer.get("assessed_version") == "earlier":
        state += " on an earlier version"  # the facet was compared with the version assessed, never the current one
    return "%s — %s%s" % (label, parts, "" if state in ("n/a",) else " (%s)" % state)


def assessment_label(f, adj):
    """The version caveat of the other reviewer's latest position, or None."""
    peer = [a for a in (adj["primary"], adj["attacker"]) if a != f["author"]][0]
    pos = f["positions"].get(peer)
    if pos is None:
        return "the current version was not assessed by %s" % NAMES[peer]
    if pos.get("assessed_version") == "earlier":
        verb = "opposed" if f["retained"] else pos["existence"]
        return "%s: %s an earlier version (report %s); the current version was not assessed by %s" % (
            NAMES[peer], verb, pos.get("assessed_report"), NAMES[peer])
    return None


def facet_summary(f, adj):
    parts = ["status %s" % f["status"]] + [facet_line(f, adj, facet, label) for facet, label in FACET_LABELS]
    caveat = assessment_label(f, adj)
    if caveat:
        parts.append(caveat)
    if f["withdrawn"]:
        parts.append("withdrawn by %s in report %s" % (NAMES[f["author"]], f["withdrawn"]["report"]))
    if f["objections"]:
        parts.append("open supplemental objections: %s" % ", ".join(f["objections"]))
    return "; ".join(parts)


def objection_units(final_findings, adj):
    """The attacker objections (live findings whose adjudicated status is opposed), ranked by severity then ID."""
    units, seen = [], set()
    for finding in final_findings:
        f = finding.get("adjudication")
        if not f or f["status"] != "opposed" or finding["id"] in seen:
            continue  # one unit per finding (a shared lineage finding has one copy per reviewer)
        seen.add(finding["id"])
        attacker = adj["attacker"]
        statements = [s for s in f["statements"] if s["agent"] == attacker]
        units.append({"id": finding["id"], "title": finding["title"], "author": f["author"],
                      "severity": finding["severity"], "file": finding.get("file"),
                      "evidence": finding["fields"].get("Evidence"), "fix": finding["fields"].get("Fix"),
                      "adjudication": f, "statement": statements[-1] if statements else None,
                      "supplemental": [adj["objections"][oid] for oid in f["objections"]]})
    return sorted(units, key=lambda u: (SEVERITY_ORDER.get(u["severity"], 4), id_key(u["id"])))


def objection_index(unit, adj):
    """The always-budgeted index entry of one objection (Operator OP-1): ID, title, original author, file and each
    reviewer's position on every facet; the bounded details follow only when they fit."""
    f = unit["adjudication"]
    parts = (["File: " + (unit.get("file") or "not stated")]
             + [facet_line(f, adj, facet, label) for facet, label in FACET_LABELS])
    caveat = assessment_label(f, adj)
    if f["retained"] and caveat:
        parts.append(caveat)
    return "- **%s** %s (%s's finding) — %s" % (unit["id"], prose(unit["title"] or "", TITLE_LIMIT), NAMES[unit["author"]],
                                               "; ".join(prose(p, 400) for p in parts))


def objection_details(unit, adj, fix_verbatim=True):
    """The bounded details of one objection. Evidence, responses and statements are excerpts with a visible note; the
    recommended fix is shown verbatim (a fenced block) or replaced as a whole by a pointer — never cut or rewritten."""
    f = unit["adjudication"]
    lines = []
    if f["withdrawn"]:
        lines.append("  - Withdrawn by %s (report %s): %s" % (NAMES[f["author"]], f["withdrawn"]["report"],
                                                              prose(f["withdrawn"]["reason"], EXCERPT)))
    if unit.get("evidence"):
        lines.append("  - Evidence: " + prose(unit["evidence"], EXCERPT))
    if unit.get("fix"):
        lines += (fix_lines("Recommended fix", unit["fix"]) if fix_verbatim else
                  ["  - Recommended fix: see the complete review report (too long for this comment)"])
    response = f.get("primary_response")
    if response and response.get("text"):
        lines.append("  - Primary response (%s, report %s): %s" % (NAMES[adj["primary"]], response["report"],
                                                                   prose(response["text"], EXCERPT)))
    statement = unit.get("statement")
    if statement:
        later = statement.get("answered_later_by")
        lines.append("  - %s's latest statement (report %s%s): %s" % (
            NAMES[statement["agent"]], statement["report"],
            "; answered later by %s in report %s" % (NAMES[later["agent"]], later["report"]) if later else "",
            prose(statement["text"], EXCERPT)))
    for o in unit["supplemental"]:
        lines.append("  - Supplemental objection %s (%s, %s; open): %s" % (o["id"], NAMES[o["claimant"]], o["topic"],
                                                                         prose(o["text"], EXCERPT)))
        answer = o.get("latest_response")
        if answer:
            lines.append("    - Response by %s (report %s; %s%s): %s" % (
                NAMES[answer["agent"]], answer["report"], answer["status"],
                "" if answer["version"] == "current" else ", to an earlier version of the objection",
                prose(answer["text"], EXCERPT)))
        else:
            lines.append("    - No response by %s yet" % NAMES[[a for a in NAMES if a != o["claimant"]][0]])
    return lines


def render_adjudicated(data, budget=BUDGET):
    adj = data["adjudication"]
    units = data["objections"]
    total = len(units)
    head = ["## Code review: %s" % adj["primary_verdict"], "- " + prose(qualification(adj), 300),
            "- Verdicts: " + prose(verdicts_line(adj), 300), "- Attacker objections: %d" % total,
            "- Merge blockers (primary reviewer): %d" % len([f for f in data["findings"] if (
                f.get("adjudication_positions") or {}).get(adj["primary"], {}).get("blocking")])]
    if adj["counts"]["not_reassessed"]:
        head.append("- Not reassessed: %d findings changed after the other reviewer's last assessment (see the "
                    "complete review report)." % adj["counts"]["not_reassessed"])
    head += ["- Mode: %s — %s" % (prose(data["review_mode"], 20), prose(data["approval_scope_label"], 300)),
             "- Reviewed commit: %s" % prose(data["head_sha"], 64),
             "- Models: " + "; ".join("%s: %s" % (NAMES[a], prose(data["models"][a], 200)) for a in ("claude", "codex"))]
    if adj["primary_verdict"] == "APPROVED" and adj["unanimous"]:
        footer = "No merge blockers were reported. The complete review report lists any remaining lower-severity notes."
    elif adj["primary_verdict"] == "APPROVED":
        footer = ("The primary reviewer approved. The attacker's objections above are recorded for the developer and the "
                  "human reviewer to decide; every objection, with its complete evidence, is in the complete review "
                  "report.")
    else:
        footer = ("Please address every finding in the complete review report, not only those listed here: fix it, or "
                  "reply with the reason it does not apply. The attacker's objections are recorded with both positions.")
    disclosure_room = 2 * SECTION_NOTE_ROOM
    rest = budget - size(head) - size(["", footer]) - disclosure_room
    body = []
    shown = []
    if units:
        body += ["", "### Attacker objections", ""]
        rest -= size(body)
        for unit in units:
            line = objection_index(unit, adj)
            if size([line]) > rest:
                break
            shown.append((unit, line))
            rest -= size([line])
    # Details of the shown objections, whole units in rank order, then the primary's blockers and other findings.
    detailed, objection_body = 0, []
    for unit, line in shown:
        objection_body.append(line)
        detail = objection_details(unit, adj)
        if size(detail) > rest:
            detail = objection_details(unit, adj, fix_verbatim=False)
        if size(detail) <= rest:
            objection_body += detail
            rest -= size(detail)
            detailed += 1
    body += objection_body
    notes = []
    if len(shown) < total:
        notes.append("- %d of %d attacker objections are not shown in this comment; every objection is in the complete "
                     "review report (full-report.md and findings.json in the review package)." % (total - len(shown), total))
    if detailed < len(shown):
        notes.append("- %d of %d attacker objections are not shown in full in this comment: their evidence, fixes and "
                     "responses are in the complete review report." % (len(shown) - detailed, total))
    body += notes
    rest += disclosure_room - size(notes)
    primary = adj["primary"]
    blockers = [f for f in data["findings"]
                if (f.get("adjudication_positions") or {}).get(primary, {}).get("blocking")]
    objection_ids = {u["id"] for u in units}
    if blockers:
        section = ["", "### Merge blockers (primary reviewer)", ""]
        if size(section) <= rest:
            rest -= size(section)
            hidden = 0
            for f in sorted(blockers, key=lambda f: (SEVERITY_ORDER.get(f["severity"], 4), id_key(f["id"]))):
                unit = [index_line(f)] + ([] if f["id"] in objection_ids else details_lines(f))
                if size(unit) > rest:
                    unit = [index_line(f)]
                if size(unit) > rest:
                    hidden += 1
                    continue
                section += unit
                rest -= size(unit)
            if hidden:
                section.append("- +%d more merge blockers of the primary reviewer in the complete review report" % hidden)
            body += section
        else:
            body.append("- %d merge blockers of the primary reviewer are listed in the complete review report." % len(blockers))
    others = [f for f in data["findings"] if f["id"] not in objection_ids and f not in blockers
              and f["severity"] in ("critical", "high", "medium")]
    if others:
        section, cut = ["", "### Other significant findings", ""], 0
        if size(section) <= rest:
            rest -= size(section)
            for f in others[:OTHER_LIMIT]:
                unit = [index_line(f)]
                if size(unit) > rest:
                    cut += 1
                    continue
                section += unit
                rest -= size(unit)
            cut += max(0, len(others) - OTHER_LIMIT)
            if cut:
                section.append("- +%d more significant findings in the complete review report" % cut)
            body += section
    return finish(head + body + ["", footer], budget)


def adjudication_section(final_findings, adj):
    """The full report's complete adjudication: every finding of the run (all severities), unshortened."""
    out = ["", "## Adjudication", "",
           "- Rule: the primary reviewer (%s) decides the verdict; %s's unresolved objections are recorded, never a veto."
           % (NAMES[adj["primary"]], NAMES[adj["attacker"]]),
           "- " + qualification(adj), "- Verdicts: " + verdicts_line(adj),
           "- Counts (one per finding): %s" % ", ".join("%s %d" % (k.replace("_", " "), v) for k, v in adj["counts"].items()),
           ""]
    titles = {f["id"]: f["title"] for f in final_findings}
    order = sorted(adj["findings"].values(), key=lambda f: (not f["live"], id_key(f["id"])))
    for f in order:
        out.append("- **%s %s** — %s's finding; %s" % (f["id"], titles.get(f["id"], f["definition"]["title"]),
                                                      NAMES[f["author"]], "status: " + f["status"] if f["live"]
                                                      else "resolved (history only; no reviewer keeps a claim)"))
        for facet, label in FACET_LABELS:
            out.append("  - " + facet_line(f, adj, facet, label))
        caveat = assessment_label(f, adj)
        if caveat and f["live"]:
            out.append("  - " + caveat)
        if f["withdrawn"]:
            out.append("  - Withdrawn by %s in report %s: %s" % (NAMES[f["author"]], f["withdrawn"]["report"],
                                                                 f["withdrawn"]["reason"]))
        if f.get("primary_response"):
            out.append("  - Primary response (%s, report %s): %s" % (NAMES[adj["primary"]], f["primary_response"]["report"],
                                                                     f["primary_response"]["text"] or "(maintained)"))
        for s in f["statements"]:
            later = s.get("answered_later_by")
            out.append("  - Statement by %s, report %s (%s%s): %s" % (
                NAMES[s["agent"]], s["report"], s["kind"],
                "; answered later by %s in report %s" % (NAMES[later["agent"]], later["report"]) if later else "",
                s["text"].replace("\n", "\n    ")))
        out.append("  - History: " + "; ".join("%s (%s, %s)" % (h["event"], NAMES[h["agent"]], h["report"])
                                                for h in f["history"]))
    for oid, o in sorted(adj["objections"].items()):
        out.append("- Supplemental objection %s by %s on %s (%s): %s — %s%s" % (
            oid, NAMES[o["claimant"]], o["finding"], o["topic"], o["state"], o["text"].replace("\n", "\n    "),
            "; " + o["resolution"] if o["resolution"] else ""))
        for r in o["responses"]:
            out.append("  - Response by %s, report %s: %s — %s" % (NAMES[r["agent"]], r["report"], r["status"], r["text"]))
    out.append("")
    return out
