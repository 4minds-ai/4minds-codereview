"""Reviewer report grammar for gencr: the one structural parser of findings and review notes, the structural check
run on every report, deterministic format normalization and its independent proof. Standard library only (Python 3.8+).

Grammar of a finding (inside "## Findings", up to the next heading or control line):
  - a heading line "- **<ID> <title>**" at column 0;
  - field headers "<F spaces>- <Label>: <value>", where F (1-4 spaces) is the indentation of the first non-blank
    line after the heading and is the same for every field of the finding; only lines at exactly F declare fields;
  - a field's value (see Value) is the text after "<Label>:" and its delimiting spaces and/or the block of lines
    directly below it indented at least A = F + 2 spaces, stored as line[A:] byte-exact, interior blank lines included.
    Severity, File and Duplicate of are single lines. Review-notes entries use the same value grammar at F = 0.
Normalization repairs only one form, moving nothing but the qualifier: a qualified label "<F>- <Label> (<qualifier>):"
becomes "<F>- <Label>: (<qualifier>) ...". Anything else that is invalid is irreparable: the report stays INCOMPLETE.
"""

import re

FIELD_LABELS = ("Severity", "Introduced by this change", "File", "Problem", "Evidence", "Expected vs actual", "Tests",
                "Fix")
OPTIONAL_LABELS = ("Duplicate of",)
LABELS = FIELD_LABELS + OPTIONAL_LABELS
ID_RE = r"(?:CLAUDE|CODEX)-[0-9]+"
CONTROL_RE = re.compile(r"^(## |VERDICT:|PEER-AGREEMENT:|PEER-REPORT:)")
HEADING_RE = re.compile(r"^- \*\*(" + ID_RE + r")\s*(.*?)\**\s*$")
LABEL_ALT = "|".join(re.escape(label) for label in LABELS)
HEADER_RE = re.compile(r"^- (" + LABEL_ALT + r")(?: \(([^()\n]*)\))?:(.*)$")
FIELD_LIKE_RE = re.compile(r"^- (" + LABEL_ALT + r")(?: \([^()\n]*\))?:")
LABEL_LIKE_RE = re.compile(r"^- [A-Za-z][A-Za-z ]*(?: \(.*\))?:")
NONE_RE = re.compile(r"^[-*]?\s*none\.?\s*$", re.I)
# Single-line fields: their consumers read one line, so they are text on the field line and nothing below it.
SCALAR_LABELS = ("Severity", "Introduced by this change", "File", "Duplicate of")
FINDING_HEADING_LIKE_RE = re.compile(r"^- \*\*" + ID_RE)
SECTION_LIKE_RE = re.compile(r"^## ")  # any "## " line, as the section rule (CONTROL_RE) reads it
CONTROL_LIKE_RE = re.compile(r"^(VERDICT|PEER-AGREEMENT|PEER-REPORT):")
FENCE_RE = re.compile(r"^(`{3,}|~{3,})")


def value_rule():
    """The field-value rule as stated to reviewers, built from the same constants the parser enforces."""
    scalars = ", ".join(SCALAR_LABELS[:-1]) + " and " + SCALAR_LABELS[-1]
    return ("%s are each one line of text on the field line, with nothing below it. Every other field, and every "
            "\"## Review notes\" entry, may put its value on its line, in a block of lines directly below it (no blank "
            "line before the first one) indented at least two spaces deeper than its bullet, or both; nested bullets, "
            "code and blank lines inside a value are kept exactly. A field with nothing on its line and nothing below "
            "it is empty and invalid. Inside a value, a line that looks like a field or entry label (\"- Tests:\"), a "
            "finding heading (\"- **CODEX-1\"), a section heading (\"## ...\") or a VERDICT:/PEER- line is not "
            "allowed unless it is inside a fenced code block (opened and closed by a line of ``` or ~~~); a bullet "
            "with any other label, such as \"- Confidence: likely\", is ordinary text." % scalars)


class Value:
    """One field or review-notes value: text on its header line and/or a block of lines directly below it, each
    indented at least `anchor` spaces and stored as line[anchor:] byte-exact. Interior blank lines belong to the value;
    trailing blank lines are separators. Outside a fenced code block (``` or ~~~, closed by a run of at least the same
    length of the same character), a value line may not look like report structure — a header of the enclosing
    grammar (`reserved`), a finding heading, a "## " section heading or a VERDICT/PEER line: nothing in a value can
    stand for or swallow structure, whether or not the real item also exists."""

    def __init__(self, label, inline, index, anchor, reserved, where):
        self.label, self.index, self.anchor, self.reserved, self.where = label, index, anchor, reserved, where
        self.inline = inline
        self.lines = [inline] if inline else []
        self.body, self.pending, self.fence, self.errors, self.field_lines = 0, [], None, [], {index}

    def blank(self, index):
        self.pending.append(index)

    def add(self, index, line, lines):
        """A line indented at least the anchor below this header."""
        if self.body == 0 and self.pending:
            self.errors.append("%s: the %s value must start on the line directly below its label, without a blank "
                               "line" % (self.where, self.label))
        for blank in self.pending:
            self.lines.append(lines[blank][min(indent_of(lines[blank]), self.anchor):])
            self.field_lines.add(blank)
        self.pending = []
        self.body += 1
        self.lines.append(line[self.anchor:])
        self.field_lines.add(index)
        text = line.lstrip(" ")
        if self.fence:
            closing = re.match(r"^(" + re.escape(self.fence[0]) + r"{%d,}) *$" % len(self.fence), text)
            if closing:
                self.fence = None
            return
        opening = FENCE_RE.match(text)
        if opening:
            self.fence = opening.group(1)
            return
        kind = ("a label" if self.reserved.match(text) else "a finding heading" if FINDING_HEADING_LIKE_RE.match(text)
                else "a section heading" if SECTION_LIKE_RE.match(text)
                else "a VERDICT/PEER line" if CONTROL_LIKE_RE.match(text) else None)
        if kind:
            self.errors.append("%s: line %d inside the %s value looks like %s (%s): write it at its own level, or "
                               "put literal text in a fenced code block" % (self.where, index + 1, self.label, kind,
                                                                           text.strip()[:60]))

    def close(self):
        """Errors of the complete value; sets layout and the value text."""
        if self.fence:
            self.errors.append("%s: unclosed code fence in the %s value" % (self.where, self.label))
        # The inline slot is whatever follows "<Label>:" and its delimiting spaces (a CR, tab or other whitespace there
        # is payload on that line, never moved below it); emptiness is a property of the whole value.
        has_inline = self.inline != ""
        has_body = self.body > 0
        self.value = "\n".join(self.lines)
        self.layout = ("empty" if not self.value.strip() else "inline+block" if has_inline and has_body else
                       "inline" if has_inline else "block")
        return self.errors


SECTIONS = ("Findings", "Withdrawn findings", "Disposition of peer findings", "Merge blockers",
            "Supplemental objections", "Outstanding disputed findings", "Previous findings verification",
            "Duplication check", "Review notes")
# "## Review notes": what the review instructions ask for that is not a finding, as these entries, once each, in order.
NOTE_LABELS = ("Verified clean", "Unresolved risks", "Disproven claims", "Test gaps", "Out-of-scope ownership changes",
               "Other observations")
NOTE_RE = re.compile(r"^- ([A-Za-z][A-Za-z -]*?):(.*)$")
NOTE_LIKE_RE = re.compile(r"^- (" + "|".join(re.escape(label) for label in NOTE_LABELS) + r")(?: \([^()\n]*\))?:")
# A disputed row starts with exactly one finding ID: "- CODEX-2: ...", "- **CODEX-2** ...", "- CODEX-2 — ...".
DISPUTE_RE = re.compile(r"^- \**(" + ID_RE + r")\**(?![0-9A-Za-z_-])(.*)$")
SEPARATORS = " \t:\u2014\u2013-"
ONLY_DISPUTES = ("'## Outstanding disputed findings' lists only disputes about a finding, one row per finding ID; "
                 "observations go under '## Review notes'")


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def findings_span(lines):
    """(start, end) line indexes of the body of the "## Findings" section, or None."""
    for index, line in enumerate(lines):
        if line == "## Findings":
            end = index + 1
            while end < len(lines) and not CONTROL_RE.match(lines[end]):
                end += 1
            return index + 1, end
    return None


def section_body(lines, name):
    """(start, end) line indexes of the body of the first "## <name>" section, or None."""
    if "## " + name not in lines:
        return None
    start = lines.index("## " + name) + 1
    end = start
    while end < len(lines) and not CONTROL_RE.match(lines[end]):
        end += 1
    return start, end


def parse_notes(lines, offset=0):
    """The "## Review notes" entries of a section body: ({label: value (byte-exact)}, errors). Entries are headers
    "- <Label>:" at column 0 with the shared value grammar (Value) at anchor 2."""
    entries, errors, current, pending = [], [], None, []
    for index, line in enumerate(lines):
        if not line.strip():
            if current is not None:
                pending.append(index)
            continue
        header = NOTE_RE.match(line)
        if header:
            if current is not None:
                errors.extend(current.close())
            current = Value(header.group(1), header.group(2).lstrip(" "), offset + index, 2, NOTE_LIKE_RE,
                            "'## Review notes'")
            entries.append(current)
            pending = []
        elif current is not None and indent_of(line) >= 2 and "\t" not in line[:indent_of(line) + 1]:
            for blank in pending:
                current.blank(offset + blank)
            pending = []
            current.add(offset + index, line, [""] * offset + lines)
        else:
            errors.append("'## Review notes' line is not part of a labelled entry: %s" % line.strip())
            if current is not None:
                errors.extend(current.close())
            current, pending = None, []
    if current is not None:
        errors.extend(current.close())
    found = [entry.label for entry in entries]
    if found != list(NOTE_LABELS):
        errors.append("'## Review notes' must list exactly these entries, once each and in this order: %s (found: %s)"
                      % (", ".join(NOTE_LABELS), ", ".join(found) or "none"))
    values = {}
    for entry in entries:
        if not hasattr(entry, "layout"):
            entry.close()
        content = [line for line in entry.value.split("\n") if line.strip()]
        if entry.layout == "empty":
            errors.append("'## Review notes': %s has no value (write None when there is nothing)" % entry.label)
        elif any(NONE_RE.match(line.strip()) for line in content[:1]) and len(content) > 1:
            errors.append("'## Review notes': %s is None but has more content; None must be the whole value"
                          % entry.label)
        values.setdefault(entry.label, entry.value)
    return values, errors


def parse_disputes(lines, known=None):
    """The rows of "## Outstanding disputed findings": ([{"id", "text", "item"}], errors). Every line must belong to a row
    about one finding ID (continuations indented 2+) unless the section is just "- None"; with known (a set of IDs),
    each row's ID must be one of them."""
    content = [line for line in lines if line.strip()]
    if len(content) == 1 and NONE_RE.match(content[0]) and content[0].startswith("- "):
        return [], []
    rows, errors, current = [], [], None
    for line in lines:
        if not line.strip():
            if current is not None:
                current["lines"].append("")
            continue
        match = DISPUTE_RE.match(line)
        if match:
            rest = match.group(2)
            if re.match(r"\s*,|\s+\**" + ID_RE, rest):  # "- CODEX-1, CODEX-2 ..." / "- CODEX-1 CODEX-2 ..."
                errors.append("'## Outstanding disputed findings': one finding per row: %s" % line.strip())
                current = None
                continue
            if rest and rest[0] not in SEPARATORS:
                errors.append("%s: %s" % (ONLY_DISPUTES, line.strip()))
                current = None
                continue
            current = {"id": match.group(1), "head": line[2:], "first": rest.lstrip(SEPARATORS), "lines": []}
            rows.append(current)
        elif current is not None and indent_of(line) >= 2:
            current["lines"].append(line[2:])
        else:
            errors.append("%s: %s" % (ONLY_DISPUTES, line.strip()))
            current = None
    seen = set()
    for row in rows:
        body = row.pop("lines")
        while body and not body[-1].strip():
            body = body[:-1]
        row["text"] = "\n".join(([row["first"]] if row["first"] else []) + body)  # the content after the ID
        row["item"] = "\n".join([row.pop("head")] + body)  # the row as written, without its "- "
        del row["first"]
        if not row["text"].strip():
            errors.append("'## Outstanding disputed findings': the row for %s has no content" % row["id"])
        if row["id"] in seen:
            errors.append("'## Outstanding disputed findings' has more than one row for %s" % row["id"])
        seen.add(row["id"])
        if known is not None and row["id"] not in known:
            errors.append("'## Outstanding disputed findings': %s is not a finding of this review" % row["id"])
    return rows, errors


def structure_errors(text, known=None):
    """Section-level rules: no unknown heading after the first recognized section (nothing is silently dropped);
    "## Review notes" is the last section and well formed; disputed rows name one known finding each."""
    lines = text.split("\n")
    errors = []
    headings = [(index, line[3:]) for index, line in enumerate(lines) if line.startswith("## ")]
    known_at = [index for index, name in headings if name in SECTIONS]
    for index, name in headings:
        if known_at and index > known_at[0] and name not in SECTIONS:
            errors.append("unknown section '## %s' (line %d): the report's sections are fixed; observations that are "
                          "not findings go under '## Review notes'" % (name, index + 1))
    notes = section_body(lines, "Review notes")
    if notes is not None:
        later = [name for index, name in headings if index >= notes[0]]
        if later:
            errors.append("'## Review notes' must be the last section ('## %s' follows it)" % later[0])
        errors += parse_notes(lines[notes[0]:notes[1]], notes[0])[1]
    disputes = section_body(lines, "Outstanding disputed findings")
    if disputes is not None:
        errors += parse_disputes(lines[disputes[0]:disputes[1]], known)[1]
    return errors


def parse(text, repairable=False):
    """Parses the findings of a report.

    Returns {"findings": [...], "errors": [...], "repairs": [...], "field_lines": set of line indexes}.
    Each finding has id, title, heading (the exact line), line, level, and fields: an ordered list of
    {"label", "lines" (the value, byte-exact), "line"}; "values" maps label -> "\\n".join(lines).
    Each field also has "layout" (inline, block or inline+block; see Value) and each finding "layouts".
    With repairable=True, a label qualifier (form (b)) is recorded in "repairs" (with the value it denotes) instead of
    an error; nothing in the text is changed.
    """
    lines = text.split("\n")
    result = {"findings": [], "errors": [], "repairs": [], "field_lines": set()}
    for name in SECTIONS:
        if lines.count("## " + name) > 1:  # every reader uses the first one; a second would be silently ignored
            result["errors"].append("the report has more than one '## %s' section" % name)
    span = findings_span(lines)
    if span is None:
        return result
    start, end = span
    body = [line for line in lines[start:end] if line.strip()]
    if len(body) <= 1 and all(NONE_RE.match(line) for line in body):
        return result
    errors, repairs, field_lines = result["errors"], result["repairs"], result["field_lines"]

    def close_field(owner, value):
        errors.extend(value.close())
        if value.layout == "empty":
            errors.append("finding %s has an empty %s field" % (owner["id"], value.label))
        elif value.label in SCALAR_LABELS and value.layout != "inline":
            errors.append("finding %s: %s must be a single line on its field line" % (owner["id"], value.label))
        field_lines.update(value.field_lines)
        owner["fields"].append({"label": value.label, "lines": value.lines, "line": value.index,
                                "layout": value.layout})

    finding = field = None
    pending = []  # blank-line indexes after the last value line of the current field
    level = None
    for index in range(start, end):
        line = lines[index]
        heading = HEADING_RE.match(line)
        if heading:
            if field is not None:
                close_field(finding, field)
            finding = {"id": heading.group(1), "title": heading.group(2).strip("* ").strip(), "heading": line,
                       "line": index, "level": None, "fields": []}
            result["findings"].append(finding)
            field, level, pending = None, None, []
            continue
        if finding is None:
            if line.strip():  # a non-empty "## Findings" holds findings only, from its first line
                errors.append("'## Findings' line %d is not part of a finding: %s; observations that are not findings "
                              "go under '## Review notes'" % (index + 1, line.strip()))
            continue
        where = "finding %s: line %d" % (finding["id"], index + 1)
        if "\t" in line[:indent_of(line) + 1]:
            errors.append("%s is indented with a tab" % where)
            if field is not None:
                close_field(finding, field)
            field, pending = None, []
            continue
        if not line.strip():
            if field is not None:
                pending.append(index)
            continue
        depth = indent_of(line)
        if level is None:
            if not 1 <= depth <= 4:
                errors.append("%s is not a field of the finding: %s" % (where, line.strip()))
                continue
            level = finding["level"] = depth
        header = HEADER_RE.match(line[level:]) if depth == level else None
        if header:
            label, qualifier, inline = header.group(1), header.group(2), header.group(3).lstrip(" ")
            if field is not None:
                close_field(finding, field)
            pending = []
            if any(f["label"] == label for f in finding["fields"]):
                errors.append("%s repeats the field %s" % (where, label))
                field = None
                continue
            if qualifier is not None:
                if not (repairable and qualifier.strip()):
                    errors.append("%s labels the field %s with a qualifier; write \"%s: (%s) ...\"" % (
                        where, label, label, qualifier))
                    field = None
                    continue
                # Normalization form (b) moves the qualifier to the start of the value on the field line.
                repairs.append({"id": finding["id"], "label": label, "form": "qualifier", "line": index})
                inline = "(%s)" % qualifier + (" " + inline if inline else "")
            field = Value(label, inline, index, level + 2, FIELD_LIKE_RE, "finding %s" % finding["id"])
            continue
        if depth >= level + 2 and field is not None:
            for blank in pending:
                field.blank(blank)
            pending = []
            field.add(index, line, lines)
            continue
        if depth == level and LABEL_LIKE_RE.match(line[level:]):
            errors.append("%s has an unknown field label: %s" % (where, line.strip()))
        else:
            errors.append("%s is outside any field: %s" % (where, line.strip()))
        if field is not None:
            close_field(finding, field)
        field, pending = None, []
    if field is not None:
        close_field(finding, field)
    for finding in result["findings"]:
        labels = [f["label"] for f in finding["fields"]]
        for label in FIELD_LABELS:
            if label not in labels:
                errors.append("finding %s has no %s field" % (finding["id"], label))
        finding["values"] = {f["label"]: "\n".join(f["lines"]) for f in finding["fields"]}
        finding["layouts"] = {f["label"]: f["layout"] for f in finding["fields"]}
    seen = set()
    for finding in result["findings"]:
        if finding["id"] in seen:
            errors.append("finding %s is defined more than once" % finding["id"])
        seen.add(finding["id"])
    return result


def structure(parsed):
    """The comparable content of parsed findings: IDs, exact headings, label order, byte-exact values and each value's
    layout (the qualifier repair keeps a value's layout: the qualifier joins the field line in both parses)."""
    return [(f["id"], f["heading"], [(field["label"], list(field["lines"]), field["layout"]) for field in f["fields"]])
            for f in parsed["findings"]]


def normalize(text):
    """Returns (normalized_text, repairs, errors). errors non-empty means irreparable (normalized_text is None)."""
    parsed = parse(text, repairable=True)
    if parsed["errors"]:
        return None, parsed["repairs"], parsed["errors"]
    if not parsed["repairs"]:
        return None, [], ["no repairable formatting problem was found"]
    lines = text.split("\n")
    for repair in parsed["repairs"]:
        finding = next(f for f in parsed["findings"] if f["id"] == repair["id"])
        field = next(f for f in finding["fields"] if f["label"] == repair["label"])
        level = finding["level"]
        header = HEADER_RE.match(lines[field["line"]][level:])
        inline = header.group(3).lstrip(" ")
        lines[field["line"]] = "%s- %s: (%s)%s" % (" " * level, field["label"], header.group(2),
                                                    " " + inline if inline else "")
    normalized = "\n".join(lines)
    return normalized, parsed["repairs"], []


def _outside(text, field_lines):
    return [line for i, line in enumerate(text.split("\n")) if i not in field_lines]


def _stream(text):
    return re.sub(r"\s+", "", text)


def prove(original, normalized):
    """Independent check that `normalized` changes only the formatting of `original`. Returns a list of problems."""
    before = parse(original, repairable=True)
    after = parse(normalized)
    problems = []
    if before["errors"]:
        problems.append("the original report is not repairable: %s" % "; ".join(before["errors"][:3]))
    if after["errors"]:
        problems.append("the normalized report is not well formed: %s" % "; ".join(after["errors"][:3]))
    if structure(before) != structure(after):
        problems.append("finding IDs, headings, fields or field values differ")
    if _outside(original, before["field_lines"]) != _outside(normalized, after["field_lines"]):
        problems.append("text outside the finding fields differs")
    a, b = _stream(original), _stream(normalized)
    if sorted(a) != sorted(b) or a.replace(":", "") != b.replace(":", ""):
        problems.append("the report's characters differ beyond whitespace and moved label colons")
    return problems


def continued_entries(lines, entry_re):
    """Column-0 "- <ID>: ..." entries of a section with their continuation lines (indented 2+) stored as line[2:],
    byte-exact, including interior blank lines; trailing blank lines are separators. Returns [(match, lines)]."""
    entries, current, pending = [], None, []
    for line in lines:
        match = entry_re.match(line)
        if match:
            current, pending = [match, [line]], []
            entries.append(current)
        elif current is not None and not line.strip():
            pending.append(line)
        elif current is not None and indent_of(line) >= 2:
            current[1] += [blank[min(indent_of(blank), 2):] for blank in pending] + [line[2:]]
            pending = []
        else:
            current, pending = None, []
    return [(match, body) for match, body in entries]


# ── Contract v2: explicit positions ───────────────────────────────────────────
#
# A reviewer's position on every finding is explicit and machine-readable; prose is rationale only.
# - Own findings: Severity, "Introduced by this change: yes|no" and membership in its own "## Merge blockers".
# - "## Disposition of peer findings": "- ID: accepted|disputed; introduced: yes|no; severity: critical|high|medium|low;
#   blocking: yes|no — <rationale>", "- ID: rejected — <rationale>"; source-qualified rows "- ID (report <ID>): ..."
#   keep a claim on a finding the other reviewer's latest report no longer defines (accepted, disputed, or withdrawn).
# - "## Withdrawn findings": "- ID: withdrawn — <reason>" for own findings the reviewer no longer stands behind.
# - "## Supplemental objections": the claimant's "- CLAUDE-O1 (CODEX-1; fix): raised|maintained|conceded|withdrawn —
#   <rationale>" and the other reviewer's response "- CLAUDE-O1: accepted|rejected — <rationale>".

REPORT_ID_RE = r"[0-9]{2}-round[0-9]+-(?:claude|codex)-(?:initial|attack|reconcile|respond)"
SEVERITIES = ("critical", "high", "medium", "low")
TOPICS = ("evidence", "fix", "scope", "other")
DASH = r"(?:\u2014|\u2013| - )"
ROW_RE = re.compile(r"^- \**(" + ID_RE + r")\**(?:\s*\(report (" + REPORT_ID_RE + r")\))?\**:\s*"
                    r"(accepted|disputed|rejected|withdrawn)\b(.*)$", re.I)
# Only spaces around the rationale separator: a CR, tab or U+2028 right after it is payload (as in contract v1).
FACETS_RE = re.compile(r"^;\s*introduced:\s*(yes|no)\s*;\s*severity:\s*(critical|high|medium|low)\s*;\s*"
                       r"blocking: *(yes|no) *" + DASH + r" *(.*)$", re.I)
PLAIN_REST_RE = re.compile(r"^ *(?:\u2014|\u2013|:| - |- ) *(.*)$")
WITHDRAWN_RE = re.compile(r"^- \**(" + ID_RE + r")\**:\s*withdrawn\b(.*)$", re.I)
OBJECTION_ID_RE = r"(?:CLAUDE|CODEX)-O[0-9]+"
CLAIM_RE = re.compile(r"^- (" + OBJECTION_ID_RE + r")\s*\((" + ID_RE + r");\s*([a-z]+)\):\s*"
                      r"(raised|maintained|conceded|withdrawn)\b(.*)$", re.I)
RESPONSE_RE = re.compile(r"^- (" + OBJECTION_ID_RE + r"):\s*(accepted|rejected)\b(.*)$", re.I)


def severity_class(text):
    lowered = (text or "").lower()
    if "blocker" in lowered or "critical" in lowered:
        return "critical"
    for name in ("high", "medium", "low"):
        if name in lowered:
            return name
    return "unknown"


def fingerprint(finding):
    """A finding definition's identity: its title and every field value, byte-exact."""
    return [finding["title"], sorted(finding["values"].items())]


def _rest(rest, body, where, errors):
    """The rationale after the separator: first-line text plus continuation lines; it must not be empty."""
    match = PLAIN_REST_RE.match(rest)
    text = "\n".join(([match.group(1)] if match and match.group(1) else []) + body[1:])
    if not match or not text.strip():
        errors.append("%s needs \" — <rationale>\" after its status" % where)
    return text


def _section_entries(lines, name, entry_res, errors):
    """The entries of one section: [(regex index, match, body)]; any other non-blank top-level line is an error."""
    body = section_body(lines, name)
    if body is None:
        return None
    content = [line for line in lines[body[0]:body[1]] if line.strip()]
    if len(content) == 1 and NONE_RE.match(content[0]) and content[0].startswith("- "):
        return []
    entries, current = [], None
    for line in lines[body[0]:body[1]]:
        if not line.strip():
            if current is not None:
                current[2].append("")
            continue
        for kind, entry_re in enumerate(entry_res):
            match = entry_re.match(line)
            if match:
                current = [kind, match, [line]]
                entries.append(current)
                break
        else:
            if current is not None and indent_of(line) >= 2:
                current[2].append(line[2:])
            else:
                errors.append("'## %s' line is not a valid entry: %s" % (name, line.strip()))
                current = None
    for entry in entries:
        while len(entry[2]) > 1 and not entry[2][-1].strip():
            entry[2].pop()
    return [tuple(entry) for entry in entries]


def parse_positions(text):
    """One report's explicit positions (contract v2): {findings, blockers, rows, withdrawn, objections, responses,
    disputes, verdict, agreement, peer_report, errors}. Every rule that can be checked inside one report is checked
    here; rules that need the run's history are checked by gencr_adjudicate.check_report."""
    lines = text.split("\n")
    errors = []
    parsed = parse(text)
    errors += parsed["errors"]
    blockers = []
    body = section_body(lines, "Merge blockers")
    if body is not None:
        for line in lines[body[0]:body[1]]:
            match = re.match(r"^- \**(" + ID_RE + r")", line)
            if match:
                blockers.append(match.group(1))
    findings = []
    for f in parsed["findings"]:
        introduced = (f["values"].get("Introduced by this change") or "").strip().lower()
        if "Introduced by this change" in f["values"] and introduced not in ("yes", "no"):
            errors.append("finding %s: 'Introduced by this change' must be yes or no" % f["id"])
        findings.append({"id": f["id"], "title": f["title"], "values": f["values"],
                         "severity": severity_class(f["values"].get("Severity")), "introduced": introduced or None,
                         "blocking": f["id"] in blockers})
    rows = []
    for _, match, row_body in _section_entries(lines, "Disposition of peer findings", [ROW_RE], errors) or []:
        identifier, source, status, rest = match.group(1).upper(), match.group(2), match.group(3).lower(), match.group(4)
        where = "disposition row %s" % identifier
        row = {"id": identifier, "source": source, "status": status, "introduced": None, "severity": None,
               "blocking": None, "rationale": ""}
        if status in ("accepted", "disputed"):
            facets = FACETS_RE.match(rest)
            if not facets:
                errors.append("%s: write '- %s: %s; introduced: yes|no; severity: critical|high|medium|low; blocking: "
                              "yes|no — <rationale>' (every facet is required)" % (where, identifier, status))
            else:
                row.update(introduced=facets.group(1).lower(), severity=facets.group(2).lower(),
                           blocking=facets.group(3).lower() == "yes")
                row["rationale"] = "\n".join(([facets.group(4)] if facets.group(4) else []) + row_body[1:])
                if not row["rationale"].strip():
                    errors.append("%s needs a rationale after its facets" % where)
        else:
            if status == "withdrawn" and source is None:
                errors.append("%s: only a source-qualified row '- %s (report <ID>): withdrawn — <reason>' can withdraw "
                              "a claim (withdraw your own finding under '## Withdrawn findings')" % (where, identifier))
            row["rationale"] = _rest(rest, row_body, where, errors)
        rows.append(row)
    withdrawn = []
    for _, match, w_body in _section_entries(lines, "Withdrawn findings", [WITHDRAWN_RE], errors) or []:
        withdrawn.append({"id": match.group(1).upper(),
                          "reason": _rest(match.group(2), w_body, "withdrawn finding %s" % match.group(1), errors)})
    objections, responses = [], []
    for kind, match, o_body in _section_entries(lines, "Supplemental objections", [CLAIM_RE, RESPONSE_RE], errors) or []:
        if kind == 0:
            topic = match.group(3).lower()
            if topic not in TOPICS:
                errors.append("supplemental objection %s: topic must be one of %s" % (match.group(1), ", ".join(TOPICS)))
            objections.append({"id": match.group(1).upper(), "finding": match.group(2).upper(), "topic": topic,
                               "status": match.group(4).lower(),
                               "text": _rest(match.group(5), o_body, "supplemental objection %s" % match.group(1), errors)})
        else:
            responses.append({"id": match.group(1).upper(), "status": match.group(2).lower(),
                              "text": _rest(match.group(3), o_body, "response to %s" % match.group(1), errors)})
    disputes_body = section_body(lines, "Outstanding disputed findings")
    disputes = parse_disputes(lines[disputes_body[0]:disputes_body[1]])[0] if disputes_body else []
    tail = [line.strip() for line in lines if line.strip()][-3:]
    control = {}
    for line in tail:
        key, _, value = line.partition(": ")
        control[key] = value.strip()

    # Consistency inside the report.
    seen = {}
    for kind, items in (("disposition row", rows), ("withdrawn finding", withdrawn), ("objection", objections),
                        ("response", responses)):
        for item in items:
            key = (kind, item["id"])
            if key in seen:
                errors.append("%s %s appears more than once" % (kind, item["id"]))
            seen[key] = True
    own = {f["id"] for f in findings}
    for item in withdrawn:
        if item["id"] in own:
            errors.append("finding %s is both defined and withdrawn" % item["id"])
    blocking_rows = {r["id"] for r in rows if r["blocking"]}
    for row in rows:
        if row["status"] in ("rejected", "withdrawn") and row["id"] in blockers:
            errors.append("merge blocker %s is %s in your disposition row" % (row["id"], row["status"]))
        elif row["blocking"] is False and row["id"] in blockers:
            errors.append("disposition row %s says blocking: no, but %s is listed under '## Merge blockers'"
                          % (row["id"], row["id"]))
        elif row["blocking"] and row["id"] not in blockers:
            errors.append("disposition row %s says blocking: yes; list it under '## Merge blockers'" % row["id"])
    for identifier in blockers:
        if identifier not in own and identifier not in blocking_rows:
            errors.append("merge blocker %s is neither your finding nor a peer finding you mark blocking: yes"
                          % identifier)
    return {"findings": findings, "blockers": blockers, "rows": rows, "withdrawn": withdrawn, "objections": objections,
            "responses": responses, "disputes": disputes, "verdict": control.get("VERDICT"),
            "agreement": control.get("PEER-AGREEMENT"), "peer_report": control.get("PEER-REPORT"), "errors": errors}
