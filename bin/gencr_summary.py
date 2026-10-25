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
