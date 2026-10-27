#!/usr/bin/env python3
"""Mock `claude` / `codex` CLI for gencr tests and the mock-reviewer CI workflow.

Invoked through symlinks named claude or codex. With MOCK_STATE set, each call N records its
argv, cwd, stdin, environment and any --settings file under MOCK_STATE/call-N.*, and honours:
  responses/N   report text to return        model-N     actual model to report
  raw-stdout-N  exact bytes Claude prints instead of its JSON envelope
  no-model-N    report no actual model       exit-N      exit status
  sleep-N       seconds to sleep first       hook-N      bash script run before responding
  error-N       Claude reports is_error      no-auto-dup-N  do not add a Duplication check section
Without a queued response it writes a valid report: APPROVED, or MOCK_VERDICT (MOCK_VERDICT_CLAUDE / _CODEX per agent).
"""

import json
import os
import re
import stat
import subprocess
import sys
import time

agent = os.path.basename(sys.argv[0])
args = sys.argv[1:]
state = os.environ.get("MOCK_STATE", "")


def option(name):
    for index, value in enumerate(args):
        if value == name and index + 1 < len(args):
            return args[index + 1]
    return None


def path(name):
    return os.path.join(state, name)


def read(name, default=None):
    try:
        # Queued responses pass through byte for byte (CR and invalid UTF-8 included).
        with open(path(name), encoding="utf-8", errors="surrogateescape", newline="") as handle:
            return handle.read()
    except OSError:
        return default


headless = (agent == "claude" and "-p" in args) or (agent == "codex" and args[:1] == ["exec"])
n = 0
if state:
    n = int(read("count", "0") or 0) + 1
    with open(path("count"), "w") as handle:
        handle.write(str(n))
    with open(path("call-%d.agent" % n), "w") as handle:
        handle.write(agent + "\n")
    with open(path("call-%d.cwd" % n), "w") as handle:
        handle.write(os.getcwd() + "\n")
    with open(path("call-%d.args" % n), "w") as handle:
        handle.write("".join(a + "\n" for a in args))
    with open(path("call-%d.env" % n), "w") as handle:
        handle.write("".join("%s=%s\n" % item for item in sorted(os.environ.items())))
    settings = option("--settings")
    if settings:
        with open(settings, encoding="utf-8") as source, open(path("call-%d.settings" % n), "w") as handle:
            handle.write(source.read())
        with open(path("call-%d.settings-mode" % n), "w") as handle:
            handle.write(oct(stat.S_IMODE(os.stat(settings).st_mode)) + "\n" + settings + "\n")

if not headless:
    if state and args:
        with open(path("call-%d.prompt" % n), "w", encoding="utf-8") as handle:
            handle.write(args[-1])
    sys.exit(int(read("exit-%d" % n, "0") or 0) if state else 0)

prompt = sys.stdin.read()
if state:
    with open(path("call-%d.stdin" % n), "w", encoding="utf-8") as handle:
        handle.write(prompt)
    hook = path("hook-%d" % n)
    if os.path.exists(hook):
        subprocess.call(["bash", hook])
    if os.path.exists(path("sleep-%d" % n)):
        time.sleep(float(read("sleep-%d" % n)))


def severity_class(text):
    lowered = (text or "").lower()
    if "blocker" in lowered or "critical" in lowered:
        return "critical"
    for name in ("high", "medium", "low"):
        if name in lowered:
            return name
    return "high"


def peer_positions(block):
    """The peer report's findings with their facets (severity, introduced, blocking), from its text in the prompt."""
    blockers_part = block.split("## Merge blockers", 1)[1] if "## Merge blockers" in block else ""
    blockers = set(re.findall(r"^- \**((?:CLAUDE|CODEX)-\d+)", blockers_part.split("\n## ", 1)[0], re.M))
    findings_part = block.split("## Findings", 1)[1].split("\n## ", 1)[0] if "## Findings" in block else ""
    found = []
    for match in re.finditer(r"^- \*\*((?:CLAUDE|CODEX)-\d+)[^\n]*\n((?:[ \t]+.*\n?)*)", findings_part, re.M):
        body = match.group(2)
        severity = re.search(r"^\s+- Severity:\s*(.*)$", body, re.M)
        introduced = re.search(r"^\s+- Introduced by this change:\s*(yes|no)", body, re.M | re.I)
        found.append((match.group(1), severity_class(severity.group(1) if severity else ""),
                      (introduced.group(1).lower() if introduced else "yes"), match.group(1) in blockers))
    return found


def generated_report():
    prefix = agent.upper()
    match = re.search(r"^- This report's ID: (\S+)$", prompt, re.M)
    peer = re.search(r"^- Report to respond to: (\d\d-round\S+) ", prompt, re.M)
    peer_id = peer.group(1) if peer else "N/A"
    positions, open_objections = [], []
    if peer:
        block = prompt.split("----- REPORT %s:" % peer_id)[-1].split("===== END PRIOR REPORTS")[0]
        positions = peer_positions(block)
        supplemental = block.split("## Supplemental objections", 1)[1].split("\n## ", 1)[0] if "## Supplemental objections" in block else ""
        open_objections = re.findall(r"^- ((?:CLAUDE|CODEX)-O\d+) \([^)]*\):\s*(?:raised|maintained)\b", supplemental, re.M)
    verdict = os.environ.get("MOCK_VERDICT_" + agent.upper(), os.environ.get("MOCK_VERDICT", "APPROVED"))
    rc = verdict == "REQUEST CHANGES"
    lines = ["Mock %s report %s." % (agent, match.group(1) if match else "?"), "", "## Findings"]
    if rc:
        lines += ["- **%s-1 Mock blocking finding**" % prefix, "  - Severity: High", "  - Introduced by this change: yes",
                  "  - File: README.md:1", "  - Problem: mock problem", "  - Evidence: mock evidence",
                  "  - Expected vs actual: mock", "  - Tests: none", "  - Fix: mock fix"]
    else:
        lines.append("- None")
    # Like a reviewer that stands by its earlier findings: restate each one the handoff lists, verbatim from its
    # latest earlier report (contract v2: leaving one out is invalid).
    listed = re.search(r"^- Your findings in this review so far \([^\n]*\): (.*)$", prompt, re.M)
    restated = []
    for fid in (listed.group(1).split(", ") if listed else []):
        if rc and fid == "%s-1" % prefix:
            continue
        prior = prompt.split("===== PRIOR REPORTS")[-1].split("\n")
        starts = [i for i, line in enumerate(prior) if line.startswith("- **%s " % fid)]
        if starts:
            # The whole definition: its heading and every following blank or indented line (fenced blocks included).
            block = [prior[starts[-1]]]
            for line in prior[starts[-1] + 1:]:
                if line and not line[0].isspace():
                    break
                block.append(line)
            while block and not block[-1].strip():
                block.pop()
            restated.append("\n".join(block))
    if restated:
        if lines[-1] == "- None":
            lines.pop()
        lines += restated
    lines += ["", "## Withdrawn findings", "- None", "", "## Disposition of peer findings"]
    blockers = ["%s-1" % prefix] if rc else []
    rows = []
    for fid, severity, introduced, blocking in positions:
        blocks = blocking and rc
        if blocks:
            blockers.append(fid)
        rows.append("- %s: accepted; introduced: %s; severity: %s; blocking: %s — verified by the mock"
                    % (fid, introduced, severity, "yes" if blocks else "no"))
    # Claims the handoff asks this reviewer to keep or withdraw: the mock concedes them.
    for fid, source in re.findall(r"- ((?:CLAUDE|CODEX)-\d+) \(report (\S+)\): (?:accepted|disputed); introduced: \.\.\.",
                                  prompt):
        rows.append("- %s (report %s): withdrawn — conceded by the mock" % (fid, source))
    lines += rows or ["- None"]
    lines += ["", "## Merge blockers"] + (["- " + b for b in blockers] or ["- None"])
    lines += ["", "## Supplemental objections"]
    # Its own open objections the handoff lists (leaving one out is invalid): the mock concedes them.
    own = re.search(r"^- Your open supplemental objections \([^\n]*\): (.*)$", prompt, re.M)
    conceded = ["- %s (%s): conceded — conceded by the mock" % (oid, where)
                for oid, where in re.findall(r"((?:CLAUDE|CODEX)-O\d+) \(([^)]*)\)", own.group(1) if own else "")]
    lines += (["- %s: accepted — conceded by the mock" % oid for oid in open_objections] + conceded) or ["- None"]
    lines += ["", "## Outstanding disputed findings", "- None"]
    previous = re.search(r"^- Previous findings still open \(verify each one\): (.*)$", prompt, re.M)
    if "## Previous findings verification" in prompt or previous:
        ids = previous.group(1).split() if previous else []
        lines += ["", "## Previous findings verification"]
        lines += ["- %s: fixed — verified by the mock" % i for i in ids] or ["- None"]
    lines += ["", "## Review notes", "- Verified clean: None", "- Unresolved risks: None", "- Disproven claims: None",
              "- Test gaps: None", "- Out-of-scope ownership changes: None", "- Other observations: None"]
    lines += ["", "VERDICT: %s" % ("REQUEST CHANGES" if blockers else "APPROVED"),
              "PEER-AGREEMENT: %s" % ("N/A" if peer_id == "N/A" else "YES"), "PEER-REPORT: %s" % peer_id]
    return "\n".join(lines) + "\n"


def with_duplication_check(report):
    """Adds the incremental Duplication check, built from the subjects/candidates in this prompt."""
    subjects = re.findall(r"^  - (SUBJ-\d+) \[", prompt, re.M)
    candidates = re.findall(r"^  - (DUP-\d+) \(", prompt, re.M)
    incremental = '"## Duplication check": one bullet' in prompt
    if (not subjects and not incremental) or "## Duplication check" in report \
            or (state and os.path.exists(path("no-auto-dup-%d" % n))):
        return report
    lines = ["## Duplication check"] + ([] if subjects or candidates else ["- None"])
    lines += ["- %s: no duplicate found — searched: mock query for %s; compared: none" % (s, s) for s in subjects]
    lines += ["- %s: not duplicate — mock comparison of both snippets" % c for c in candidates]
    # Before "## Review notes" (the last section) when the report has one, else before the control lines.
    head, sep, tail = report.partition("\n## Review notes\n" if "\n## Review notes\n" in report else "\nVERDICT:")
    return head.rstrip("\n") + "\n\n" + "\n".join(lines) + "\n" + sep + tail


report = read("responses/%d" % n) if state else None
if report is None:
    report = generated_report()
report = with_duplication_check(report)
requested = option("--model")
if state and os.path.exists(path("no-model-%d" % n)):
    actual = None
elif state and os.path.exists(path("model-%d" % n)):
    actual = read("model-%d" % n).strip()
else:
    actual = requested or "mock-%s-default" % agent
status = int(read("exit-%d" % n, "0") or 0) if state else 0

if agent == "claude" and state and os.path.exists(path("raw-stdout-%d" % n)):
    with open(path("raw-stdout-%d" % n), "rb") as handle:  # a verbatim (possibly corrupt) CLI output envelope
        sys.stdout.buffer.write(handle.read())
elif agent == "claude":
    result = {"type": "result", "subtype": "success", "is_error": bool(state and os.path.exists(path("error-%d" % n))),
              "result": report}
    if actual:
        result["modelUsage"] = {actual: {"inputTokens": 1, "outputTokens": 1}}
    sys.stdout.write(json.dumps(result))
else:
    sys.stdout.write("OpenAI Codex (mock)\n--------\nworkdir: %s\n" % os.getcwd())
    if actual:
        sys.stdout.write("model: %s\n" % actual)
    sys.stdout.write("provider: mock\n--------\nuser\n%s\n" % (prompt.splitlines()[0] if prompt else ""))
    out = option("--output-last-message")
    if out and status == 0:
        with open(out, "w", encoding="utf-8", errors="surrogateescape", newline="") as handle:
            handle.write(report)
sys.exit(status)
