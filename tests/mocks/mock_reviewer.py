#!/usr/bin/env python3
"""Mock `claude` / `codex` CLI for gencr tests and the mock-reviewer CI workflow.

Invoked through symlinks named claude or codex. With MOCK_STATE set, each call N records its
argv, cwd, stdin, environment and any --settings file under MOCK_STATE/call-N.*, and honours:
  responses/N   report text to return        model-N     actual model to report
  raw-stdout-N  exact bytes Claude prints instead of its JSON envelope
  no-model-N    report no actual model       exit-N      exit status
  sleep-N       seconds to sleep first       hook-N      bash script run before responding
  error-N       Claude reports is_error      no-auto-dup-N  do not add a Duplication check section
Without a queued response it writes a valid report: APPROVED, or MOCK_VERDICT.
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


def generated_report():
    prefix = agent.upper()
    match = re.search(r"^- This report's ID: (\S+)$", prompt, re.M)
    peer = re.search(r"^- Report to respond to: (\d\d-round\S+) ", prompt, re.M)
    peer_id = peer.group(1) if peer else "N/A"
    peer_ids = []
    if peer:
        block = prompt.split("----- REPORT %s:" % peer_id)[-1]
        block = block.split("## Disposition of peer findings")[0]
        peer_ids = sorted(set(re.findall(r"^- \*\*((?:CLAUDE|CODEX)-\d+)", block, re.M)))
    verdict = os.environ.get("MOCK_VERDICT", "APPROVED")
    lines = ["Mock %s report %s." % (agent, match.group(1) if match else "?"), "", "## Findings"]
    if verdict == "REQUEST CHANGES":
        lines += ["- **%s-1 Mock blocking finding**" % prefix, "  - Severity: High", "  - File: README.md:1",
                  "  - Problem: mock problem", "  - Evidence: mock evidence", "  - Expected vs actual: mock",
                  "  - Tests: none", "  - Fix: mock fix"]
    else:
        lines.append("- None")
    lines += ["", "## Disposition of peer findings"]
    lines += ["- %s: accepted — verified by the mock" % i for i in peer_ids] or ["- None"]
    lines += ["", "## Merge blockers", "- %s-1" % prefix if verdict == "REQUEST CHANGES" else "- None",
              "", "## Outstanding disputed findings", "- None"]
    previous = re.search(r"^- Previous findings still open \(verify each one\): (.*)$", prompt, re.M)
    if "## Previous findings verification" in prompt or previous:
        ids = previous.group(1).split() if previous else []
        lines += ["", "## Previous findings verification"]
        lines += ["- %s: fixed — verified by the mock" % i for i in ids] or ["- None"]
    lines += ["", "## Review notes", "- Verified clean: None", "- Unresolved risks: None", "- Disproven claims: None",
              "- Test gaps: None", "- Out-of-scope ownership changes: None", "- Other observations: None"]
    lines += ["", "VERDICT: %s" % verdict,
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
