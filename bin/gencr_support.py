#!/usr/bin/env python3
"""Helpers for bin/gencr: reviewer invocation, previous-review lookup and report packaging.

Standard library only (Python 3.8+). Never contacts GitHub; CI publishing lives in bin/gencr-ci.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True  # never leave __pycache__ beside the installed scripts

SCHEMA = 1
CLAUDE_TOOLS = "Read,Grep,Glob"
CLAUDE_DENIED_TOOLS = "Bash,Edit,Write,NotebookEdit"
PACKAGE_FILES = ("summary.md", "full-report.md", "findings.json", "reconciliation.md", "metadata.json")
import gencr_report  # noqa: E402  (the one report grammar)
import gencr_summary  # noqa: E402  (the GitHub-ready review comment)
import gencr_adjudicate  # noqa: E402  (primary authority and the chronological claim ledger)
from gencr_report import FIELD_LABELS, OPTIONAL_LABELS, ID_RE  # noqa: E402
AGENT_NAMES = {"claude": "Claude", "codex": "Codex"}


def die(message, code=1):
    sys.stderr.write("gencr: error: %s\n" % message)
    sys.exit(code)


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def read_report(path):
    """A reviewer report exactly as written: LF is the only line boundary (CR is payload) and invalid UTF-8 raises
    ValueError instead of being replaced."""
    with open(path, "rb") as handle:
        data = handle.read()
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("%s is not valid UTF-8 text (byte %d)" % (os.path.basename(path), error.start))


# ── Atomic publication ────────────────────────────────────────────────────────

def publish(path, data):
    """Write data to a temp file beside path, then link it into place. Never overwrites."""
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix="." + os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data.encode("utf-8") if isinstance(data, str) else data)
            handle.flush()
            os.fsync(handle.fileno())
        os.link(tmp, path)  # fails with EEXIST if anything already exists at path
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    if sha256_file(path) != hashlib.sha256(data.encode("utf-8") if isinstance(data, str) else data).hexdigest():
        raise OSError("verification failed for %s" % path)


# ── Reviewer invocation ───────────────────────────────────────────────────────

def codex_banner_model(log_text):
    """The `model:` line of Codex's startup banner (between its first two dashed rules)."""
    lines = log_text.splitlines()
    rules = [i for i, line in enumerate(lines) if re.match(r"^-{4,}\s*$", line)]
    if len(rules) < 2:
        return None
    for line in lines[rules[0] + 1:rules[1]]:
        match = re.match(r"^model:\s*(\S+)\s*$", line)
        if match:
            return [match.group(1)]
    return None


def kill_group(proc):
    for sig, wait in ((signal.SIGTERM, 5), (signal.SIGKILL, 5)):
        try:
            os.killpg(proc.pid, sig)
        except OSError:
            return
        try:
            proc.wait(timeout=wait)
            return
        except subprocess.TimeoutExpired:
            continue


ELIGIBILITY_DISPOSITIONS = ("ELIGIBLE", "INELIGIBLE", "UNKNOWN")
# Never passed to a reviewer process: GitHub credentials and the CI eligibility channel.
REVIEWER_ENV_DENY = ("GH_TOKEN", "GITHUB_TOKEN", "GENCR_ELIGIBILITY_SOCKET")


def check_eligibility(pr_number, head_sha):
    """(disposition, reason) for launching a reviewer now. Only in CI, where the workflow sets GENCR_ELIGIBILITY_SOCKET
    to its eligibility broker (which holds the GitHub token): one bounded request per launch, never cached; any error
    is UNKNOWN. Locally the variable is unset: no check and no GitHub access."""
    path = os.environ.get("GENCR_ELIGIBILITY_SOCKET")
    if not path:
        return "ELIGIBLE", None
    import socket
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(20)
            conn.connect(path)
            conn.sendall((json.dumps({"pr_number": pr_number, "head_sha": head_sha}) + "\n").encode())
            reply = b""
            while not reply.endswith(b"\n") and len(reply) <= 4096:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                reply += chunk
        answer = json.loads(reply.decode("utf-8")) if len(reply) <= 4096 else None
    except (OSError, ValueError) as error:
        return "UNKNOWN", "the eligibility broker did not answer (%s)" % error
    if not isinstance(answer, dict) or answer.get("disposition") not in ELIGIBILITY_DISPOSITIONS \
            or not isinstance(answer.get("reason"), str):
        return "UNKNOWN", "the eligibility broker returned a malformed answer"
    return answer["disposition"], answer["reason"]


def cmd_invoke(args):
    if args.agent == "claude":
        argv = ["claude", "-p", "--output-format", "json", "--restricted", "--safe-mode", "--strict-mcp-config",
                "--permission-mode", "dontAsk", "--tools", CLAUDE_TOOLS, "--allowedTools", CLAUDE_TOOLS,
                "--disallowedTools", CLAUDE_DENIED_TOOLS]
        for directory in args.add_dir:
            argv += ["--add-dir", directory]
        if args.settings:
            argv += ["--settings", args.settings]
        if args.model:
            argv += ["--model", args.model]
        stdout_path = args.raw
    else:
        argv = ["codex", "exec", "--sandbox", "read-only", "--cd", args.repo,
                "--output-last-message", args.report, "-c", "project_doc_max_bytes=0"]
        if args.model:
            argv += ["--model", args.model]
        argv.append("-")
        stdout_path = args.log

    meta = {"agent": args.agent, "requested_model": args.model or None, "actual_models": None,
            "actual_source": None, "status": "failed", "exit_code": None, "error": None}
    started = time.time()
    # Immediately before every launch (CI): a pull request that is a draft or otherwise ineligible never gets a reviewer.
    disposition, reason = check_eligibility(args.eligibility_pr, args.eligibility_sha)
    if disposition != "ELIGIBLE":
        meta.update({"status": "ineligible" if disposition == "INELIGIBLE" else "eligibility-unknown",
                     "eligibility": disposition, "duration_s": 0.0,
                     "error": ("the pull request is not eligible for review: %s" if disposition == "INELIGIBLE"
                               else "the pull request's eligibility could not be verified: %s") % reason})
        with open(args.meta, "w", encoding="utf-8") as handle:
            json.dump(meta, handle, indent=2)
        sys.stderr.write(meta["error"] + "\n")
        return 30 if disposition == "INELIGIBLE" else 31
    environment = {key: value for key, value in os.environ.items()
                   if key not in REVIEWER_ENV_DENY and not key.startswith("GENCR_ELIGIBILITY_")}
    status = 21
    try:
        with open(args.prompt, "rb") as stdin, open(stdout_path, "wb") as stdout, \
                open(args.log, "ab") as stderr:
            proc = subprocess.Popen(argv, cwd=args.repo, stdin=stdin, stdout=stdout,
                                    stderr=(subprocess.STDOUT if stdout_path == args.log else stderr),
                                    start_new_session=True, env=environment)
            try:
                meta["exit_code"] = proc.wait(timeout=args.timeout or None)
            except subprocess.TimeoutExpired:
                kill_group(proc)
                meta["status"] = "timeout"
                meta["error"] = "timed out after %d seconds" % args.timeout
                status = 22
    except OSError as error:
        meta["error"] = "cannot run %s: %s" % (argv[0], error.strerror or error)

    if meta["status"] != "timeout" and meta["error"] is None:
        if meta["exit_code"] != 0:
            meta["error"] = "exited with status %s" % meta["exit_code"]
        if args.agent == "claude":
            try:
                result = json.loads(read_report(stdout_path))  # strict UTF-8: never replace report bytes
            except ValueError as error:
                result = None
                meta["error"] = meta["error"] or ("returned output that is not valid UTF-8 Claude JSON (%s)" % error
                                                  if "UTF-8" in str(error) else "returned output that is not Claude JSON")
            if isinstance(result, dict):
                usage = result.get("modelUsage")
                if isinstance(usage, dict) and usage:
                    # A model identifier is one line; a line break in reported output never reaches a report.
                    meta["actual_models"] = [" ".join(str(key).split()) for key in usage]
                    meta["actual_source"] = "claude --output-format json modelUsage"
                if result.get("is_error"):
                    meta["error"] = "reported an error: %s" % str(result.get("result", ""))[:300]
                elif meta["error"] is None:
                    text = result.get("result")
                    if isinstance(text, str) and text.strip():
                        with open(args.report, "w", encoding="utf-8", newline="") as handle:
                            handle.write(text if text.endswith("\n") else text + "\n")
        else:
            meta["actual_models"] = codex_banner_model(read_text(args.log))
            if meta["actual_models"]:
                meta["actual_source"] = "codex exec banner model line"
        if meta["error"] is None and not (os.path.isfile(args.report) and os.path.getsize(args.report) > 0):
            meta["error"] = "returned an empty report"
        if meta["error"] is None:
            meta["status"] = "ok"
            status = 0
    meta["duration_s"] = round(time.time() - started, 1)
    if args.model and meta["error"]:
        meta["error"] += " (requested model: %s)" % args.model
    if meta["error"]:
        meta["error"] = " ".join(meta["error"].split())
    with open(args.meta, "w", encoding="utf-8") as handle:
        json.dump(meta, handle, indent=2)
    if meta["error"]:
        meta["error"] = " ".join(meta["error"].split())
        sys.stderr.write(meta["error"] + "\n")
    return status


# ── Trusted user settings (local Claude defaults under --restricted) ──────────

def cmd_trusted_settings(args):
    """Copy only `env` and `model` from the user's ~/.claude/settings.json into a private file.

    --restricted ignores settings files, which can hold the user's provider (e.g. Bedrock)
    configuration and default model. Project and local settings are never read."""
    source = os.path.join(os.path.expanduser("~"), ".claude", "settings.json")
    if not os.path.isfile(source):
        return 0
    try:
        data = json.loads(read_text(source))
    except ValueError:
        die("cannot parse %s" % source)
    subset = {}
    env = data.get("env") if isinstance(data, dict) else None
    if isinstance(env, dict):
        subset["env"] = {str(k): str(v) for k, v in env.items()}
    if isinstance(data, dict) and isinstance(data.get("model"), str):
        subset["model"] = data["model"]
    if not subset:
        return 0
    directory = tempfile.mkdtemp(prefix="gencr-settings-", dir=args.tmpdir)
    path = os.path.join(directory, "settings.json")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(subset, handle)
    print(path)
    return 0


# ── Report parsing ────────────────────────────────────────────────────────────

CONTROL_RE = re.compile(r"^(## |VERDICT:|PEER-AGREEMENT:|PEER-REPORT:)")


def section(text, heading):
    lines, found = [], False
    for line in text.split("\n"):
        if line == "## " + heading:
            found = True
            continue
        if found and CONTROL_RE.match(line):
            break
        if found:
            lines.append(line)
    return lines


def is_none(lines):
    content = [line for line in lines if line.strip()]
    return len(content) <= 1 and all(re.match(r"^[-*]?\s*none\.?\s*$", line, re.I) for line in content)


def severity_class(text):
    lowered = (text or "").lower()
    for name in ("blocker", "critical"):
        if name in lowered:
            return "critical"
    for name in ("high", "medium", "low"):
        if name in lowered:
            return name
    return "unknown"


def parse_findings(text):
    """Findings with their complete (multiline, byte-exact) field values, from the shared report grammar."""
    findings = []
    for parsed in gencr_report.parse(text)["findings"]:
        fields = parsed["values"]
        findings.append({"id": parsed["id"], "title": parsed["title"], "fields": fields,
                         "layouts": parsed["layouts"],
                         "severity": severity_class(fields.get("Severity")),
                         "file": fields.get("File", "").split("\n")[0].strip()})
    return findings


def field_lines(indent, label, value, layout="inline"):
    """Renders a field bullet with its value in the report grammar (value anchor = indent + 2), in the reviewer's
    layout: a block value stays below its label (never lifted onto it). A missing layout (older packages) is inline."""
    first, *rest = (value or "").split("\n")
    if layout == "block":
        first, rest = "", [first] + rest
    head = "%s- %s:%s" % (indent, label, " " + first if first else "")
    return [head] + [(indent + "  " + line) if line else "" for line in rest]


def parse_ids(lines):
    ids = []
    for line in lines:
        match = re.match(r"^- \**(" + ID_RE + r")", line)
        if match:
            ids.append(match.group(1))
    return ids


def parse_dispositions(lines, words):
    """Disposition/verification entries with their complete evidence, including continuation lines."""
    entry = re.compile(r"^- \**(" + ID_RE + r")\**:\s*(" + words + r")\b *(?:[\u2014\u2013:,]|-(?= ))? *(.*)$", re.I)
    result = []
    for match, body in gencr_report.continued_entries(lines, entry):
        evidence = "\n".join(([match.group(3)] if match.group(3) else []) + body[1:])
        # Finding IDs are upper case by the report grammar; a row written in another case names the same finding.
        result.append({"id": match.group(1).upper(), "status": match.group(2).lower(), "evidence": evidence})
    return result


# ── Previous review lookup (incremental) ──────────────────────────────────────

def normalize_repository(url, root):
    if not url:
        return "path:" + os.path.realpath(root)
    value = url.strip()
    value = re.sub(r"^[a-z+]+://", "", value)
    value = re.sub(r"^[^@/]+@", "", value)
    value = value.replace(":", "/", 1) if re.match(r"^[^/]+:[^/]", value) else value
    value = re.sub(r"\.git/?$", "", value).rstrip("/")
    return value.lower()


def cmd_repo_id(args):
    print(normalize_repository(args.url, args.root))
    return 0


def load_package(path):
    """Returns (metadata, findings) of a complete package, or raises ValueError with a reason."""
    run_dir = path[:-len("/manifest.json")] if path.endswith("/manifest.json") else path.rstrip("/")
    manifest_path = os.path.join(run_dir, "manifest.json")
    if os.path.islink(run_dir) or not os.path.isfile(manifest_path):
        raise ValueError("no complete review package (manifest.json missing)")
    manifest = json.loads(read_text(manifest_path))
    if not isinstance(manifest, dict) or not isinstance(manifest.get("files"), dict):
        raise ValueError("manifest.json is not a package manifest object")
    if manifest.get("schema") != SCHEMA or manifest.get("complete") is not True:
        raise ValueError("unsupported or incomplete package manifest")
    for name, digest in (manifest.get("files") or {}).items():
        target = os.path.join(run_dir, name)
        if "/" in name or os.path.islink(target) or not os.path.isfile(target) or sha256_file(target) != digest:
            raise ValueError("package file %s is missing or modified" % name)
    for name in ("metadata.json", "findings.json", "full-report.md"):
        if name not in (manifest.get("files") or {}):
            raise ValueError("package lacks %s" % name)
    metadata = json.loads(read_text(os.path.join(run_dir, "metadata.json")))
    findings = json.loads(read_text(os.path.join(run_dir, "findings.json")))
    if not isinstance(metadata, dict) or not isinstance(findings, dict):
        raise ValueError("metadata.json or findings.json is not a JSON object")
    if metadata.get("schema") != SCHEMA:
        raise ValueError("unsupported metadata schema")
    final = findings.get("final_findings") or []
    if not isinstance(final, list) or not all(isinstance(f, dict) for f in final):
        raise ValueError("findings.json final_findings is not a list of findings")
    open_ids = {f.get("id") for f in final}
    blockers = findings.get("blockers") or {}
    if not isinstance(blockers, dict) or not all(isinstance(v, list) for v in blockers.values()):
        raise ValueError("findings.json blockers is not a mapping of finding-ID lists")
    for agent_blockers in blockers.values():
        missing = set(agent_blockers) - open_ids
        if missing:
            raise ValueError("inconsistent package: merge blockers %s are not open findings" % ", ".join(sorted(missing)))
    return run_dir, metadata, findings


def git_is_ancestor(repo, older, newer):
    return subprocess.call(["git", "-C", repo, "merge-base", "--is-ancestor", older, newer],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0


def scope_check(identity, args):
    """The previous review's anchor must come from the same method and evidence as the current one.
    Packages written before scope methods existed are merge-base reviews."""
    method = identity.get("scope_method") or "merge-base"
    if method == "explicit-range":
        raise ValueError("it reviewed an explicit range, which is not an incremental baseline; run a fresh review "
                         "with --range instead")
    if method == "merge-commit":
        recorded = identity.get("merge_commit") or ""
        if args.scope_method != "merge-commit" or args.merge_commit != recorded:
            raise ValueError("the previous review's merge commit %s no longer matches HEAD %s (the branch changed "
                             "after it was merged); run --fresh" % (recorded[:12], args.head[:12]))
    elif args.scope_method != method:
        raise ValueError("it used the %s scope method, but HEAD now resolves by %s" % (method, args.scope_method))


COMPLETED_OUTCOMES = ("APPROVED", "REQUEST CHANGES", "UNRESOLVED DISAGREEMENT")
ISO_UTC_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")


def valid_utc(value):
    """value if it is a calendar-valid UTC time as gencr writes it, else None."""
    if not isinstance(value, str) or not ISO_UTC_RE.match(value):
        return None
    try:
        datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return None
    return value


def count(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def adjudication_problem(metadata, findings):
    """Why a package's stored adjudication cannot be trusted, or None. Absent (older or single-reviewer packages) is
    fine; present but malformed, inconsistent with the outcome, roles and invocation records, or different between
    metadata.json and findings.json, is never trusted (no approval, no baseline)."""
    adjudication, copy = metadata.get("adjudication"), (findings or {}).get("adjudication")
    if adjudication is None and copy is None:
        return None
    if adjudication is not None:
        problems = gencr_adjudicate.validate(adjudication, metadata.get("invocations"), metadata.get("outcome"),
                                             metadata.get("primary"), metadata.get("adversary"))
        if problems:
            return "its adjudication is invalid (%s)" % "; ".join(problems[:2])
    if json.dumps(copy, sort_keys=True) != json.dumps(adjudication, sort_keys=True):
        return "its adjudication differs between metadata.json and findings.json"
    return None


def metadata_problem(metadata, findings):
    """Why a compatible package's own metadata cannot be trusted for selection, or None. Absent additive fields (older
    schema-1 packages) are fine; present fields of the wrong type or value are not, and are never coerced."""
    problem = adjudication_problem(metadata, findings)
    if problem:
        return problem
    run_id = metadata.get("run_id")
    if not isinstance(run_id, str) or not run_id or re.search(r"[\x00-\x1f\x7f/]", run_id):
        return "its run ID is missing or invalid"
    if not count(metadata.get("rounds", 0)):
        return "its round count is not a non-negative integer"
    previous = metadata.get("previous_review")
    if previous is None:
        return None
    if not isinstance(previous, dict):
        return "its previous_review is not an object"
    sha = previous.get("reviewed_sha")
    if not isinstance(previous.get("id"), str) or not previous["id"] or not isinstance(sha, str) \
            or not re.match(r"^[0-9a-f]{40}$", sha) or not isinstance(previous.get("path"), (str, type(None))):
        return "its previous_review identity is invalid"
    if "outcome" in previous and previous["outcome"] not in COMPLETED_OUTCOMES:
        return "its previous_review outcome is invalid"
    if "rounds_used" in previous and not count(previous["rounds_used"]):
        return "its previous_review rounds_used is not a non-negative integer"
    if "newer_unresolved" in previous and (not isinstance(previous["newer_unresolved"], str)
                                           or not previous["newer_unresolved"].strip()):
        return "its previous_review newer_unresolved is invalid"
    return None


def evaluate_previous(candidate, args):
    """A candidate package checked against the current review identity: (record, None) or (None, reason). Every
    failure, including valid JSON of the wrong shape, is a rejection reason; nothing here aborts discovery."""
    try:
        run_dir, metadata, findings = load_package(candidate)
        if not isinstance(metadata, dict) or not isinstance(findings, dict):
            raise ValueError("metadata.json or findings.json is not a JSON object")
        identity = metadata.get("identity")
        if not isinstance(identity, dict):
            raise ValueError("metadata has no review identity")
        outcome = metadata.get("outcome")
        checks = (
            (outcome in COMPLETED_OUTCOMES, "outcome %s is not a completed review" % outcome),
            (identity.get("repository") == args.repository, "different repository"),
            (metadata.get("developer") == args.dev, "different developer"),
            (identity.get("pr_number") == (args.pr_number or None), "different pull request"),
            (identity.get("branch") == args.branch, "different branch"),
            (identity.get("base_branch") == args.base_branch, "different base branch"),
            ((identity.get("instructions_version"), identity.get("instructions_sha256"))
             == (args.instructions_version, args.instructions_sha256), "different review instructions"),
        )
        for ok, reason in checks:
            if not ok:
                raise ValueError(reason)
        scope_check(identity, args)
        if identity.get("merge_base") != args.merge_base:
            raise ValueError("the merge-base changed (base merged or rebased)")
        reviewed = identity.get("head_sha") or ""
        if not isinstance(reviewed, str) or not re.match(r"^[0-9a-f]{40}$", reviewed):
            raise ValueError("no reviewed commit SHA recorded")
        if not git_is_ancestor(args.repo, reviewed, args.head):
            raise ValueError("reviewed commit %s is not an ancestor of HEAD (force push or rebase)" % reviewed[:12])
        open_findings = findings.get("final_findings") or []
        if not isinstance(open_findings, list) or not all(isinstance(f, dict) for f in open_findings):
            raise ValueError("findings.json final_findings is not a list of findings")
        # A compatible review on HEAD's history with untrustworthy metadata stays in the history (it may be the
        # latest review, e.g. an UNRESOLVED barrier) but can never be selected: "invalid" stops the selection.
        try:
            invalid = metadata_problem(metadata, findings)
        except Exception as error:  # never the candidate-drop path below: an unvalidatable package stays a barrier
            invalid = "its metadata could not be validated (%s)" % type(error).__name__
        return {"path": run_dir, "metadata": metadata, "findings": findings,
                "id": metadata.get("run_id") if not invalid else os.path.basename(run_dir.rstrip("/")),
                "reviewed_sha": reviewed, "outcome": outcome, "open_findings": open_findings,
                "completed_at": valid_utc(metadata.get("completed_at")),
                "rounds": None if invalid else metadata.get("rounds", 0), "invalid": invalid}, None
    except (ValueError, OSError, TypeError, AttributeError, KeyError) as error:
        return None, "%s: %s" % (os.path.basename(candidate.rstrip("/")), error)


def review_frontier(records, repo):
    """(frontier, ambiguous): the completed reviews furthest along HEAD's history. A review whose reviewed commit is
    a proper ancestor of another's is superseded; several reviews of one commit are ordered by their validated
    completion time, and a missing time or a tie for the latest is ambiguous (a tie among older reviews is not).
    Several distinct commits on the frontier (a merge DAG) are ambiguous too: gencr never guesses."""
    by_sha = {}
    for record in records:
        by_sha.setdefault(record["reviewed_sha"], []).append(record)
    shas = list(by_sha)
    maximal = [a for a in shas if not any(a != b and git_is_ancestor(repo, a, b) for b in shas)]
    frontier, ambiguous = [], len(maximal) > 1
    for sha in maximal:
        group = by_sha[sha]
        if len(group) > 1:
            times = [r["completed_at"] for r in group]
            if None in times or times.count(max(times)) > 1:
                ambiguous = True
                frontier += group
                continue
            group = sorted(group, key=lambda r: r["completed_at"])[-1:]
        frontier += group
    return frontier, ambiguous


def write_previous(args, chosen, extra):
    open_findings = chosen["open_findings"]
    findings = chosen["findings"]
    lineage = sorted(set(findings.get("lineage_ids") or []) | {f.get("id") for f in open_findings if f.get("id")})
    result = dict({
        "id": chosen["id"], "path": chosen["path"], "reviewed_sha": chosen["reviewed_sha"],
        "merge_base": chosen["metadata"]["identity"].get("merge_base"), "outcome": chosen["outcome"],
        "review_mode": chosen["metadata"].get("review_mode"), "completed_at": chosen["completed_at"],
        "rounds_used": chosen["rounds"], "open_findings": open_findings, "lineage_ids": lineage,
    }, **extra)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2)
    with open(args.out + ".fields", "wb") as handle:
        for value in (result["id"], result["reviewed_sha"], result["path"], result["outcome"],
                      "" if result["rounds_used"] is None else result["rounds_used"],
                      extra.get("newer_unresolved") or ""):
            handle.write(str(value).encode("utf-8") + b"\0")
    with open(args.out + ".ids", "w", encoding="utf-8") as handle:
        handle.write("".join(i + "\n" for i in sorted({f["id"] for f in open_findings if f.get("id")}, key=id_sort_key)))
    with open(args.out + ".lineage", "w", encoding="utf-8") as handle:
        handle.write("".join(i + "\n" for i in sorted(lineage, key=id_sort_key)))
    with open(args.out + ".files", "wb") as handle:
        for finding in open_findings:
            path = re.sub(r":[0-9][0-9,\-]*$", "", str(finding.get("file") or "").strip().strip("`"))
            if path and not path.startswith("/") and ".." not in path.split("/"):
                handle.write(path.encode("utf-8") + b"\0")


def describe(record):
    return "%s (reviewed %s, %s)" % (record["id"], record["reviewed_sha"][:12], record["outcome"])


def cmd_no_review(args):
    """Writes the covered-HEAD no-review receipt atomically; refuses to replace anything."""
    if os.path.lexists(args.out):
        die("%s already exists" % args.out)
    record = {"schema": SCHEMA, "kind": "covered", "previous_id": args.previous_id,
              "previous_reviewed_sha": args.previous_sha, "previous_outcome": args.previous_outcome,
              "head_sha": args.head, "written_by": "gencr"}
    temporary = args.out + ".tmp"
    with open(temporary, "x", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2)
    os.link(temporary, args.out)  # fails if a receipt appeared meanwhile; never overwrites
    os.unlink(temporary)
    return 0


def cmd_previous(args):
    """Selects the review baseline. --mode incremental (explicit --incremental), auto (no scope option) or fresh-check
    (explicit --fresh: is there a previous review to confirm against?). Writes <out>.decision (one word) and, for a
    baseline, the selected package files. Exit 0 = run incremental from the baseline, 3 = no compatible previous review
    (auto: FRESH), 4 = the baseline already covers HEAD (no new review needed), 5 = stop: a decision is required; a
    fatal error dies with the reason."""
    def decide(word, message=None, code=0):
        with open(args.out + ".decision", "w", encoding="utf-8") as handle:
            handle.write(word + "\n" + (message or "") + "\n")
        return code

    scanned, reasons = [], []
    if os.path.isdir(args.search_dir):
        for name in sorted(os.listdir(args.search_dir)):
            if name.startswith("review-"):
                record, reason = evaluate_previous(os.path.join(args.search_dir, name), args)
                (scanned.append(record) if record else reasons.append(reason))
    frontier, ambiguous = review_frontier(scanned, args.repo)
    if args.mode == "fresh-check":
        return decide("previous", describe(frontier[0]) if frontier else "") if scanned else decide("none", "", 3)
    stop_hint = ("Add --incremental --previous=<package> to choose a baseline, or --fresh to start over. "
                 "No reviewer was launched.")
    if args.previous:
        chosen, reason = evaluate_previous(os.path.realpath(args.previous), args)
        if chosen and chosen["invalid"]:
            chosen, reason = None, "%s: %s" % (chosen["id"], chosen["invalid"])
        if not chosen:
            die("cannot use %s as the incremental baseline (%s). Run with --fresh instead." % (args.previous, reason))
        newer = [r for r in scanned if r["outcome"] == "UNRESOLVED DISAGREEMENT" and r["path"] != chosen["path"]
                 and (git_is_ancestor(args.repo, chosen["reviewed_sha"], r["reviewed_sha"]))
                 and (r["reviewed_sha"] != chosen["reviewed_sha"]
                      or (r["completed_at"] or "") > (chosen["completed_at"] or ""))]
        extra = {"newer_unresolved": ", ".join(sorted(r["id"] for r in newer)) or None}
    else:
        if not frontier:
            if args.mode == "auto":
                detail = reasons[-1] if reasons else "none found in %s" % args.search_dir
                return decide("none", detail, 3)
            detail = "; ".join(reasons[-5:]) if reasons else "no previous review packages found in %s" % args.search_dir
            die("cannot establish a reliable incremental baseline (%s). Run with --fresh instead." % detail)
        untrusted = [r for r in frontier if r["invalid"]]
        if untrusted:
            message = ("the latest previous review cannot be trusted as a baseline: %s. %s"
                       % ("; ".join("%s at %s (%s)" % (r["id"], r["path"], r["invalid"]) for r in untrusted), stop_hint))
            if args.mode == "auto":
                return decide("invalid", message, 5)
            die(message)
        if ambiguous:
            listing = "; ".join(describe(r) + " at " + r["path"] for r in frontier)
            message = ("several previous reviews could be the baseline and none is unambiguously the latest: %s. %s"
                       % (listing, stop_hint))
            if args.mode == "auto":
                return decide("ambiguous", message, 5)
            die(message)
        chosen = frontier[0]
        if chosen["outcome"] == "UNRESOLVED DISAGREEMENT" and args.mode == "auto":
            return decide("unresolved", "review %s ended UNRESOLVED DISAGREEMENT; gencr does not continue it "
                          "automatically. Add --incremental to continue it (its open findings are kept) or --fresh to "
                          "start over. No reviewer was launched." % describe(chosen), 5)
        extra = {"newer_unresolved": None}
    write_previous(args, chosen, extra)
    if chosen["reviewed_sha"] == args.head and chosen["outcome"] != "UNRESOLVED DISAGREEMENT":
        return decide("covered", "", 4)
    return decide("baseline", "", 0)


def id_sort_key(identifier):
    agent, _, number = identifier.partition("-")
    return (agent, int(number) if number.isdigit() else 0)


# ── Packaging ─────────────────────────────────────────────────────────────────

def read_state(path):
    with open(path, "rb") as handle:
        parts = handle.read().split(b"\0")
    state = {"inv": [], "scope": []}
    for key, value in zip(parts[0::2], parts[1::2]):
        key, value = key.decode("utf-8", "replace"), value.decode("utf-8", "replace")
        if key in ("inv", "scope"):
            state[key].append(value.split("\x1f"))
        else:
            state[key] = value
    return state


def model_record(agent, state, invocations):
    participated = agent in (state.get("primary"), state.get("adversary"))
    requested = state.get(agent + "_requested") or None
    record = {"participated": participated, "requested": requested,
              "requested_source": "--%s-model" % agent if requested else "CLI configured default",
              "invocations": []}
    for inv in invocations:
        if inv["agent"] == agent:
            record["invocations"].append({"report_id": inv["id"], "round": inv["round"], "phase": inv["phase"],
                                          "actual": inv["actual_models"], "source": inv["actual_source"]})
    record["display"] = model_display(record)
    return record


def model_display(record):
    if not record["participated"]:
        return "Not used"
    requested = record["requested"] or "CLI default"
    observed = [inv for inv in record["invocations"] if inv["actual"]]
    if not observed:
        return "Not reported (requested: %s)" % requested
    groups = []
    for inv in record["invocations"]:
        label = "+".join(inv["actual"]) if inv["actual"] else "Not reported"
        for group in groups:
            if group[0] == label:
                group[1].append(inv["round"])
                break
        else:
            groups.append([label, [inv["round"]]])
    if len(groups) == 1:
        actual = groups[0][0]
        if record["requested"] and record["requested"] != actual:
            return "%s (requested: %s)" % (actual, record["requested"])
        return actual
    parts = []
    for label, rounds in groups:
        unique = []
        for value in rounds:
            if value not in unique:
                unique.append(value)
        parts.append("%s (round%s %s)" % (label, "s" if len(unique) > 1 else "", ", ".join(unique)))
    return "Multiple: %s (requested: %s)" % ("; ".join(parts), requested)


def scope_lines(metadata):
    """How the review range was derived; nothing for packages written before scope methods existed."""
    identity = metadata["identity"]
    if not identity.get("scope_method"):
        return []
    method = identity["scope_method"]
    if identity.get("scope_evidence"):
        method += " (%s)" % identity["scope_evidence"]
    merge = ", merge commit %s" % identity["merge_commit"][:12] if identity.get("merge_commit") else ""
    reviewed = "%s..%s" % (identity["review_base"][:12], identity["head_sha"][:12])
    if metadata.get("review_mode") == "INCREMENTAL":
        return ["- Review Scope: incremental %s (anchor %s %s%s)" % (
            reviewed, method, identity["merge_base"][:12], merge)]
    return ["- Review Scope: %s, target %s, %s%s" % (method, identity.get("scope_target"), reviewed, merge)]


def render_header(metadata):
    identity = metadata["identity"]
    lines = ["- Review Mode: %s" % metadata["review_mode"]]
    previous = metadata.get("previous_review")
    if previous:
        lines.append("- Previous Review ID: %s" % previous["id"])
        lines.append("- Previous Reviewed SHA: %s" % previous["reviewed_sha"])
    lines += [
        "- Approval Scope: %s" % metadata["approval_scope_label"],
        "- Reviewed HEAD SHA: %s" % identity["head_sha"],
        "- Base Branch: origin/%s (tip %s)" % (identity["base_branch"], identity["base_tip"]),
        "- Merge-base SHA: %s" % identity["merge_base"],
    ] + scope_lines(metadata) + (["- Duplication Index: %s" % metadata["duplication_index"]] if metadata.get("duplication_index") else []) + [
        "- Claude Model: %s" % metadata["models"]["claude"]["display"],
        "- Codex Model: %s" % metadata["models"]["codex"]["display"],
        "- Primary Reviewer: %s; Adversarial Reviewer: %s" % (
            AGENT_NAMES.get(metadata["primary"], metadata["primary"]),
            AGENT_NAMES.get(metadata["adversary"], "None (single reviewer)")),
        "- Final Verdict: %s" % metadata["final_verdict"],
        "- Claude Verdict: %s" % metadata["verdicts"]["claude"],
        "- Codex Verdict: %s" % metadata["verdicts"]["codex"],
        "- Reconciliation Rounds: %s (maximum %s)" % (metadata["rounds"], metadata["max_rounds"]),
        "- Outcome: %s (%s)" % (metadata["outcome"], metadata["category"]),
        "- Ended By: %s" % metadata["end_reason"],
        "- Review Instructions: %s (%s, sha256 %s)" % (
            metadata["instructions"]["label"], os.path.basename(metadata["instructions"]["file"]),
            identity["instructions_sha256"][:12]),
        "- Run ID: %s" % metadata["run_id"],
    ]
    return "\n".join(lines) + "\n"


def approval_scope(state, incremental):
    """incremental | range (explicit range) | partial (known partial current delta) | full."""
    method = state.get("scope_method") or "merge-base"
    if incremental:
        return "incremental"
    if method == "explicit-range":
        return "range"
    return "partial" if method == "merge-base" and state.get("scope_note") else "full"


def bullets(lines):
    return "\n".join(lines).strip("\n") + "\n" if any(line.strip() for line in lines) else "- None\n"


def cmd_package(args):
    try:
        return build_package(args)
    except (OSError, ValueError, KeyError) as error:
        die("could NOT save the review package in %s: %s" % (args.run_dir, error), 23)


def normalization_record(run_dir, inv_id):
    path = os.path.join(run_dir, inv_id + ".normalization.json")
    return json.loads(read_text(path)) if os.path.isfile(path) else None


def normalization_note(inv):
    record = inv.get("format_normalization")
    if not record:
        return None
    repairs = ", ".join("%s %s (%s)" % (r["id"], r["label"], r["form"]) for r in record["repairs"]) or "none"
    if record["result"] == "normalized":
        return "%s: format normalized by gencr (%s); original response kept as %s" % (
            inv["id"], repairs, record["original"])
    return "%s: format normalization %s (%s); original response kept as %s" % (
        inv["id"], record["result"], "; ".join(record.get("errors") or []), record["original"])


def assessment(finding, peer, finals, dispositions, peer_reports, run_dir):
    """(label, contested) from the other reviewer's explicit finding-level disposition, tied to the report version
    it assessed. Verdicts and PEER-AGREEMENT are never evidence of agreement on a finding."""
    name = AGENT_NAMES[peer]
    if peer not in finals:
        return "not assessed by %s" % name, False
    entry = next((d for d in dispositions.get(peer) or [] if d["id"] == finding["id"]), None)
    if entry is None:
        return "not assessed by %s" % name, False
    status = entry["status"]
    # A source-qualified row assessed the version in its source report; a plain row, the report it answered.
    assessed = entry.get("source") or peer_reports.get(finals[peer][0]) or ""
    current = assessed == finding["report_id"]
    if not current and assessed:
        path = os.path.join(run_dir, assessed + ".report.md")
        if os.path.isfile(path):
            then = [f for f in parse_findings(read_report(path)) if f["id"] == finding["id"]]
            current = bool(then) and (then[0]["title"], then[0]["fields"]) == (finding["title"], finding["fields"])
    if current:
        return "%s: %s" % (name, status), status in ("rejected", "disputed")
    return ("%s: %s an earlier version (report %s); the current version was not assessed by %s"
            % (name, status, assessed, name), status in ("rejected", "disputed"))


def comment_data(state, metadata, final_findings, blockers, dispositions, finals, invocations, disputes, run_dir):
    """The inputs of the GitHub-ready review comment, from the validated final state only."""
    agents = [a for a in (state.get("primary"), state.get("adversary")) if a]
    peer_reports = {inv["id"]: inv.get("peer_report") for inv in invocations}
    copies = {}
    for f in final_findings:
        copies.setdefault(f["id"], []).append(f)
    findings = []
    for identifier, group in copies.items():
        labels, contested = [], False
        for f in group:
            peers = [a for a in agents if a != f["reported_by"]]
            if peers:
                label, against = assessment(f, peers[0], finals, dispositions, peer_reports, run_dir)
            else:
                label, against = "single reviewer", False
            contested = contested or against
            labels.append(label if len(group) == 1 else "%s (%s's definition)" % (label, AGENT_NAMES[f["reported_by"]]))
        first = group[0]
        versions = {(f["title"], tuple(sorted(f["fields"].items()))) for f in group}
        fixes = [(f["reported_by"], f["fields"].get("Fix")) for f in group]
        if len({fix for _, fix in fixes}) == 1:
            fixes = fixes[:1]
        severity = min((f["severity"] for f in group), key=lambda s: ["critical", "high", "medium", "low", "unknown"].index(s))
        findings.append({"id": identifier, "title": first["title"], "severity": severity, "file": first["file"],
                         "fixes": fixes, "blocker": any(f["blocker"] for f in group),
                         "reporters": [f["reported_by"] for f in group], "differs": len(versions) > 1,
                         "listed_by": [a for a in agents if identifier in (blockers.get(a) or [])],
                         "assessment": "; ".join(labels), "contested": contested,
                         "adjudication_positions": (first.get("adjudication") or {}).get("positions")})
    return {"final_verdict": metadata["final_verdict"], "outcome": metadata["outcome"],
            "convergence": state.get("convergence") or None, "error": metadata.get("error"),
            "max_rounds": metadata["max_rounds"], "agents": agents, "verdicts": metadata["verdicts"],
            "review_mode": metadata["review_mode"], "approval_scope_label": metadata["approval_scope_label"],
            "head_sha": metadata["identity"]["head_sha"],
            "models": {a: metadata["models"][a]["display"] for a in ("claude", "codex")},
            "findings": findings, "disputes": disputes, "surviving_findings": len(copies)}


def cmd_review_comment(args):
    """Prints the review-comment block of a saved summary.md (exactly one well-formed marker pair required)."""
    try:
        sys.stdout.write(gencr_summary.extract(read_report(args.summary)))
    except ValueError as error:
        die(str(error))
    return 0


def build_package(args):
    state = read_state(args.state)
    run_dir = args.run_dir
    invocations = []
    for parts in state["inv"]:
        inv_id, agent, role, rnd, phase, verdict, agreement, peer = (parts + [""] * 8)[:8]
        meta_path = os.path.join(run_dir, inv_id + ".invoke.json")
        meta = json.loads(read_text(meta_path)) if os.path.isfile(meta_path) else {}
        invocations.append({"id": inv_id, "agent": agent, "role": role, "round": rnd, "phase": phase,
                            "verdict": verdict or None, "agreement": agreement or None, "peer_report": peer or None,
                            "status": meta.get("status"), "actual_models": meta.get("actual_models"),
                            "actual_source": meta.get("actual_source"), "requested_model": meta.get("requested_model"),
                            "duration_s": meta.get("duration_s"), "error": meta.get("error"),
                            "format_normalization": normalization_record(run_dir, inv_id)})

    incremental = state.get("review_mode") == "INCREMENTAL"
    previous = None
    if incremental:
        previous = {"id": state.get("previous_id"), "reviewed_sha": state.get("previous_sha"),
                    "path": state.get("previous_path")}
        # Additive fields (absent in packages written before automatic review selection).
        if state.get("previous_outcome"):
            previous["outcome"] = state["previous_outcome"]
        if (state.get("previous_rounds") or "").isdigit():
            previous["rounds_used"] = int(state["previous_rounds"])
        if state.get("previous_newer_unresolved"):
            previous["newer_unresolved"] = state["previous_newer_unresolved"]
    outcome = state["outcome"]
    adversary = state.get("adversary") or None
    verdicts = {}
    for agent in ("claude", "codex"):
        if agent not in (state.get("primary"), adversary):
            verdicts[agent] = "Not used"
        else:
            verdicts[agent] = state.get("last_verdict_" + agent) or "None (no valid report)"
    if incremental:
        scope_label = "Incremental only: changes since %s; not a full PR approval" % state.get("previous_sha")
    elif (state.get("scope_method") or "merge-base") == "merge-base" and state.get("scope_note"):
        scope_label = ("Current branch delta only (merge-base %s .. HEAD %s); part of the branch is already in the "
                       "base and is not covered, so this is not a full PR approval" % (
                           state["merge_base"][:12], state["head"][:12]))
    elif (state.get("scope_method") or "merge-base") == "merge-base":
        scope_label = "Full PR (merge-base %s .. HEAD %s)" % (state["merge_base"][:12], state["head"][:12])
    elif state["scope_method"] == "merge-commit":
        scope_label = "Full PR as proposed before merge commit %s (review base %s .. HEAD %s)" % (
            state["merge_commit"][:12], state["merge_base"][:12], state["head"][:12])
    else:
        scope_label = "Explicit range only (%s .. HEAD %s)" % (state["merge_base"][:12], state["head"][:12])
    files = []
    for parts in state["scope"]:
        files.append({"status": parts[0], "path": parts[-1], "old_path": parts[1] if len(parts) > 2 else None})

    finals = {}
    final_findings, blockers, dispositions, verification, dup_dispositions = [], {}, {}, {}, {}
    duplication = None
    if state.get("duplication"):
        duplication = json.loads(read_text(os.path.join(run_dir, state["duplication"])))
        duplication.pop("head_files", None)
    for agent in ("claude", "codex"):
        report_id = state.get("final_report_" + agent)
        report_path = os.path.join(run_dir, (report_id or "") + ".report.md")
        if not report_id or not os.path.isfile(report_path):
            continue
        text = read_report(report_path)
        finals[agent] = (report_id, text)
        agent_blockers = parse_ids(section(text, "Merge blockers"))
        blockers[agent] = agent_blockers
        for finding in parse_findings(text):
            finding.update({"reported_by": agent, "report_id": report_id, "blocker": finding["id"] in agent_blockers})
            final_findings.append(finding)
        # Contract-v2 rows: status, facets and source; "evidence" is the row's rationale.
        dispositions[agent] = [{"id": r["id"], "status": r["status"], "evidence": r["rationale"], "source": r["source"],
                                "introduced": r["introduced"], "severity": r["severity"], "blocking": r["blocking"]}
                               for r in gencr_report.parse_positions(text)["rows"]]
        if incremental:
            verification[agent] = parse_dispositions(section(text, "Previous findings verification"),
                                                     "not fixed|fixed|obsolete")
            dup_dispositions[agent] = [line for line in section(text, "Duplication check") if line.strip()]

    # Every final merge blocker must be in the open-finding set, even when its definition is in an
    # earlier report of the run (reviewers may cite a finding without repeating it).
    all_blockers = {i for ids in blockers.values() for i in ids}
    defined = {f["id"] for f in final_findings}
    history = []
    for inv in invocations:
        path = os.path.join(run_dir, inv["id"] + ".report.md")
        if inv["verdict"] and os.path.isfile(path):
            history.append((inv["id"], inv["agent"], read_report(path)))
    for blocker in sorted(all_blockers - defined, key=id_sort_key):
        for report_id, agent, text in reversed(history):
            match = [f for f in parse_findings(text) if f["id"] == blocker]
            if match:
                match[0].update({"reported_by": agent, "report_id": report_id, "defined_in_earlier_report": True})
                final_findings.append(match[0])
                break
        else:
            raise ValueError("merge blocker %s has no finding definition in this review" % blocker)
    # An accepted peer finding stays open even when its author no longer lists it: its definition is taken from the
    # exact peer report the acceptance assessed (its source report, or the report it answered; validated to define
    # it), never from another version.
    peer_reports = {inv["id"]: inv.get("peer_report") for inv in invocations}
    for agent, (report_id, _) in finals.items():
        assessed = peer_reports.get(report_id)
        for entry in dispositions[agent]:
            identifier, source = entry["id"], entry.get("source") or assessed
            if entry["status"] != "accepted" or identifier in {f["id"] for f in final_findings}:
                continue
            path = os.path.join(run_dir, (source or "") + ".report.md")
            match = []
            if source and os.path.isfile(path):
                match = [f for f in parse_findings(read_report(path)) if f["id"] == identifier]
            if not match:
                raise ValueError("accepted finding %s has no definition in the assessed report %s" % (identifier, source))
            author = next((inv["agent"] for inv in invocations if inv["id"] == source and inv["verdict"]), None)
            if author is None:
                raise ValueError("the assessed report %s of accepted finding %s is not a valid report of this review"
                                 % (source, identifier))
            match[0].update({"reported_by": author, "report_id": source,
                             "accepted_by": {"agent": agent, "report_id": report_id},
                             "author_final_report": (finals.get(author) or (None,))[0]})
            final_findings.append(match[0])
    for finding in final_findings:
        finding["blocker"] = finding["id"] in all_blockers

    # Primary-reviewer authority and the chronological claim ledger (contract v2), for completed two-reviewer runs.
    adjudication = None
    valid_ids = [inv["id"] for inv in invocations if inv["verdict"]]
    if adversary and outcome in ("APPROVED", "REQUEST CHANGES"):
        adjudication = gencr_adjudicate.adjudicate(run_reports(run_dir, valid_ids), state["primary"], adversary)
        problems = gencr_adjudicate.validate(adjudication, invocations, outcome, state["primary"], adversary)
        if problems:
            raise ValueError("inconsistent adjudication: %s" % "; ".join(problems))
        # Every live finding stays open with its author's latest definition (also after the author withdrew it while
        # the other reviewer keeps its claim); findings no claim keeps alive leave the open set.
        texts = {rid: read_report(os.path.join(run_dir, rid + ".report.md")) for rid in valid_ids}
        live = {identifier: f for identifier, f in adjudication["findings"].items() if f["live"]}
        kept = []
        for identifier in sorted(live, key=id_sort_key):
            f = live[identifier]
            match = [d for d in parse_findings(texts[f["definition"]["report"]]) if d["id"] == identifier]
            if not match:
                raise ValueError("finding %s has no definition in report %s" % (identifier, f["definition"]["report"]))
            match[0].update({"reported_by": f["author"], "report_id": f["definition"]["report"],
                             "blocker": identifier in all_blockers, "adjudication": f})
            kept.append(match[0])
            # A previous finding both reviewers carry forward keeps the other reviewer's definition too (its copy).
            for agent, (report_id, text) in finals.items():
                if agent == f["author"]:
                    continue
                copy = [d for d in parse_findings(text) if d["id"] == identifier]
                if copy:
                    copy[0].update({"reported_by": agent, "report_id": report_id, "blocker": identifier in all_blockers,
                                    "adjudication": f})
                    kept.append(copy[0])
        final_findings = kept

    lineage = set(state.get("lineage", "").split()) | {f["id"] for f in final_findings}
    metadata = {
        "schema": SCHEMA, "run_id": state["run_id"], "tool": "gencr", "review_mode": state["review_mode"],
        "approval_scope": approval_scope(state, incremental), "approval_scope_label": scope_label,
        "identity": {
            "repository": state["repository"], "pr_number": state.get("pr_number") or None,
            "branch": state["branch"], "base_branch": state["base_branch"], "base_tip": state["base_tip"],
            "merge_base": state["merge_base"], "head_sha": state["head"],
            "review_base": state.get("review_base") or state["merge_base"],
            "scope_method": state.get("scope_method") or "merge-base",
            "scope_evidence": state.get("scope_evidence") or None, "scope_target": state.get("scope_target") or None,
            "merge_commit": state.get("merge_commit") or None, "git_merge_base": state.get("git_merge_base") or None,
            "instructions_version": state.get("instructions_version") or None,
            "instructions_sha256": state["instructions_sha256"],
        },
        "previous_review": previous,
        "duplication_index": (("%s (%s)" % (duplication["index"].get("status"), duplication["index"].get("reason"))
                               if duplication["index"].get("reason") else duplication["index"].get("status"))
                              if duplication else None),
        "developer": state.get("dev"),
        "instructions": {"label": state["instructions_label"], "file": state["instructions_file"]},
        "primary": state["primary"], "adversary": adversary,
        "models": {agent: model_record(agent, state, invocations) for agent in ("claude", "codex")},
        "rounds": int(state.get("rounds") or 0), "max_rounds": int(state.get("max_rounds") or 3),
        "end_reason": state.get("end_reason"), "final_verdict": state["final_verdict"],
        "verdicts": verdicts, "outcome": outcome, "category": state["category"],
        "exit_code": int(state["exit_code"]), "error": state.get("error") or None,
        "eligibility": state.get("eligibility") or None,
        "files_examined": files, "invocations": invocations,
        "started_at": state.get("started_at"), "completed_at": now_utc(),
        "report_contract": 2, "adjudication": adjudication,
    }
    header = render_header(metadata)

    counts = {"critical": 0, "high": 0, "medium": 0, "low": 0, "unknown": 0}
    for finding in final_findings:
        counts[finding["severity"]] += 1
    title = "Code Review: %s" % state["branch"]
    disputes, dispute_items = [], []
    for f in final_findings if adjudication else []:
        if f["adjudication"]["status"] == "opposed":
            disputes.append("%s (%s's finding): %s" % (f["id"], AGENT_NAMES[f["reported_by"]],
                                                       gencr_summary.facet_summary(f["adjudication"], adjudication)))
    for agent, (report_id, text) in ([] if adjudication else finals.items()):
        # One item per disputed row (its continuation lines included), never one per line.
        for row in gencr_report.parse_disputes(section(text, "Outstanding disputed findings"))[0]:
            item = row["item"]
            disputes.append("%s (%s)" % (" ".join(item.split()), AGENT_NAMES[agent]))
            dispute_items.append((agent, item))

    data = comment_data(state, metadata, final_findings, blockers, dispositions, finals, invocations, dispute_items, run_dir)
    data["adjudication"] = adjudication
    data["objections"] = gencr_summary.objection_units(final_findings, adjudication) if adjudication else []
    comment = gencr_summary.safe_render(data)
    summary = ["# %s — summary" % title, "", gencr_summary.BEGIN] + comment.rstrip("\n").split("\n") + [
        gencr_summary.END, "", "## Review details", "", header.rstrip("\n"), "",
        "## Findings by severity", "",
        "- Critical: %d" % counts["critical"], "- High: %d" % counts["high"],
        "- Medium: %d" % counts["medium"], "- Low: %d" % counts["low"], "",
        "## Unresolved disagreements", "", bullets(disputes).rstrip("\n"), "",
        "Full report: full-report.md (findings, evidence, dispositions); machine-readable: findings.json, metadata.json.",
        ""]
    if metadata["error"]:
        summary.insert(summary.index("## Review details") + 2, "- Error: %s" % " ".join(metadata["error"].split()))
    # Only the block's own markers may appear as whole lines (the details part quotes reviewer text).
    tail = summary.index(gencr_summary.END) + 1
    summary[tail:] = [("\\" + line) if line in (gencr_summary.BEGIN, gencr_summary.END) else line
                      for line in "\n".join(summary[tail:]).split("\n")]

    full = ["# %s" % title, "", header.rstrip("\n"),
            "- Developer: %s" % (state.get("dev") or ""),
            "- Transcripts: %s" % run_dir,
            "- Findings and evidence below are as reported by the reviewers; gencr validates the report format, not the findings.",
            "- Reviewers ran read-only: any claim that needs a test run is unverified unless the reviewer says otherwise."]
    if adjudication:
        full += ["- " + gencr_summary.qualification(adjudication),
                 "- Verdicts: %s" % gencr_summary.verdicts_line(adjudication),
                 "- Attacker objections: %d" % adjudication["counts"]["attacker_objections"],
                 "- Adjudication: the primary reviewer's latest valid verdict decides; every finding below carries both "
                 "reviewers' explicit positions (see '## Adjudication')."]
    if metadata["error"]:
        full.append("- Error: %s" % metadata["error"])
    for inv in invocations:
        if normalization_note(inv):
            full.append("- Format: %s" % normalization_note(inv))
    full += ["", "## Files examined", ""]
    for entry in files:
        if entry["old_path"]:
            full.append("- %s %s -> %s" % (entry["status"], entry["old_path"], entry["path"]))
        else:
            full.append("- %s %s" % (entry["status"], entry["path"]))
    if not files:
        full.append("- None")
    for agent in (state["primary"], adversary):
        if not agent or agent not in finals:
            continue
        report_id, text = finals[agent]
        full += ["", "## %s's final position (report %s)" % (AGENT_NAMES[agent], report_id), ""]
        headings = ["Merge blockers", "Outstanding disputed findings", "Disposition of peer findings"]
        if incremental:
            headings.append("Previous findings verification")
        for heading in headings + ["Findings", "Review notes"]:
            full += ["### " + heading, bullets(section(text, heading)).rstrip("\n"), ""]
    if adjudication:
        full += gencr_summary.adjudication_section(final_findings, adjudication)
    # The canonical open-finding set (what the next incremental review must verify), with full evidence,
    # including blockers whose definition is in an earlier report of the run.
    full += ["## Open findings (canonical)", ""]
    for finding in final_findings:
        provenance = "defined by %s in report %s" % (AGENT_NAMES.get(finding["reported_by"], finding["reported_by"]),
                                                     finding["report_id"])
        claims = finding.get("adjudication") or {}
        if claims.get("withdrawn"):
            peer = [a for a in claims["positions"] if a != claims["author"]]
            provenance += "; withdrawn by %s in report %s; kept open by %s's claim (report %s)" % (
                AGENT_NAMES[claims["author"]], claims["withdrawn"]["report"],
                AGENT_NAMES[peer[0]] if peer else "the other reviewer", claims["positions"][peer[0]]["report"] if peer else "?")
        elif finding.get("defined_in_earlier_report"):
            provenance += " (an earlier report; cited as a merge blocker in the final reports)"
        elif finding.get("accepted_by"):
            provenance += " (accepted by %s in its final report %s; not in %s's final report %s)" % (
                AGENT_NAMES[finding["accepted_by"]["agent"]], finding["accepted_by"]["report_id"],
                AGENT_NAMES[finding["reported_by"]], finding["author_final_report"])
        full.append("- **%s %s**%s" % (finding["id"], finding["title"], " — merge blocker" if finding["blocker"] else ""))
        full.append("  - Provenance: %s" % provenance)
        if finding.get("adjudication"):
            full.append("  - Adjudication: %s" % gencr_summary.facet_summary(finding["adjudication"], adjudication))
        for label in FIELD_LABELS + OPTIONAL_LABELS:
            if finding["fields"].get(label):
                full += field_lines("  ", label, finding["fields"][label], (finding.get("layouts") or {}).get(label))
    if not final_findings:
        full.append("- None")
    full.append("")
    if duplication:
        full += ["## Duplication check", "",
                 "- Textual index: %s" % metadata["duplication_index"],
                 "- Subjects: %d; textual candidates: %d%s" % (
                     len(duplication["subjects"]), len(duplication["candidates"]),
                     " (more matches than shown)" if duplication.get("candidates_truncated") else ""),
                 "- Dispositions are reviewer attestations of targeted searches; gencr validates their structure and "
                 "paired locations, not semantic recall."]
        for cand in duplication["candidates"]:
            full.append("- %s (%s) for %s: new %s:%d-%d; existing %s" % (
                cand["id"], cand["kind"], cand["subject"], cand["path"], cand["start"], cand["end"], "; ".join(
                    "%s:%d-%d (merge-base: %s; previous review: %s)" % (
                        o["path"], o["start"], o["end"], o["provenance"]["merge_base"], o["provenance"]["previous_review"])
                    for o in cand["originals"])))
        for agent in (state["primary"], adversary):
            if agent and dup_dispositions.get(agent):
                full += ["", "### %s's duplication check" % AGENT_NAMES[agent]] + dup_dispositions[agent]
        full.append("")
    full += ["## Review history", ""]
    for inv in invocations:
        full.append("- %s: %s (%s reviewer), round %s, %s, VERDICT: %s, model: %s" % (
            inv["id"], AGENT_NAMES.get(inv["agent"], inv["agent"]), inv["role"], inv["round"], inv["phase"],
            inv["verdict"] or "none", "+".join(inv["actual_models"]) if inv["actual_models"] else "Not reported"))
    if not invocations:
        full.append("- None")
    full.append("")

    recon = ["# Reconciliation: %s" % state["branch"], "", header.rstrip("\n"), "", "## Invocations", ""]
    for inv in invocations:
        recon.append("- %s" % inv["id"])
        recon.append("  - Reviewer: %s (%s), round %s, phase %s" % (
            AGENT_NAMES.get(inv["agent"], inv["agent"]), inv["role"], inv["round"], inv["phase"]))
        recon.append("  - Verdict: %s; peer agreement: %s; answering: %s" % (
            inv["verdict"] or "none", inv["agreement"] or "none", inv["peer_report"] or "none"))
        if normalization_note(inv):
            recon.append("  - Format: %s" % normalization_note(inv))
        recon.append("  - Requested model: %s; actual: %s" % (
            inv["requested_model"] or "CLI default",
            "+".join(inv["actual_models"]) if inv["actual_models"] else "Not reported"))
        if inv["error"]:
            recon.append("  - Error: %s" % inv["error"])
    if not invocations:
        recon.append("- None")
    recon += ["", "## End", "", "- %s" % metadata["end_reason"], ""]

    findings_doc = {"schema": SCHEMA, "run_id": state["run_id"], "review_mode": state["review_mode"],
                    "final_findings": final_findings, "blockers": blockers, "dispositions": dispositions,
                    "previous_verification": verification if incremental else None,
                    "duplication": dict(duplication, dispositions=dup_dispositions) if duplication else None,
                    "lineage_ids": sorted(lineage, key=id_sort_key), "adjudication": adjudication,
                    # Observations that are not findings, per final report; never findings, blockers or disputes.
                    "review_notes": {agent: gencr_report.parse_notes(section(text, "Review notes"))[0]
                                     for agent, (_, text) in finals.items()}}

    documents = {
        "summary.md": "\n".join(summary),
        "full-report.md": "\n".join(full),
        "findings.json": json.dumps(findings_doc, indent=2) + "\n",
        "reconciliation.md": "\n".join(recon),
        "metadata.json": json.dumps(metadata, indent=2) + "\n",
    }
    try:
        for name in PACKAGE_FILES:
            publish(os.path.join(run_dir, name), documents[name])
        if args.legacy_report:
            publish(args.legacy_report, documents["full-report.md"])
        manifest = {"schema": SCHEMA, "run_id": state["run_id"], "complete": True,
                    "files": {name: sha256_file(os.path.join(run_dir, name)) for name in PACKAGE_FILES}}
        publish(os.path.join(run_dir, "manifest.json"), json.dumps(manifest, indent=2) + "\n")
    except OSError as error:
        die("could NOT save the review package in %s: %s" % (run_dir, error), 23)
    return 0


def cmd_duplicates(args):
    import gencr_duplicates
    try:
        result = gencr_duplicates.analyze(args.repo, args.previous_sha, args.previous_id, args.merge_base, args.head)
    except RuntimeError as error:
        die("duplication pre-search failed: %s" % error)
    gencr_duplicates.save(result, args.out)
    with open(args.prompt_out, "w", encoding="utf-8") as handle:
        handle.write(gencr_duplicates.render_prompt(result))
    print("too-many-subjects" if result["too_many_subjects"] else
          ("subjects-incomplete" if result.get("subjects_incomplete") else "ok"))
    return 0


def cmd_check_report(args):
    """The structural check of the shared grammar, run on every report after the legacy validator."""
    try:
        text = read_report(args.report)
        known = set(args.known.split()) if args.known is not None else None
        errors = gencr_report.parse(text)["errors"] + gencr_report.structure_errors(text, known)
    except ValueError as error:
        errors = [str(error)]
    if errors:
        die("; ".join(errors[:3]) + ("; and %d more" % (len(errors) - 3) if len(errors) > 3 else ""))
    return 0


def run_reports(run_dir, ids):
    """The run's valid reports in invocation order, as the adjudication reads them."""
    reports = []
    for rid in ids:
        path = os.path.join(run_dir, rid + ".report.md")
        if not os.path.isfile(path):
            raise ValueError("cannot check the dispositions: missing report %s" % path)
        text = read_report(path)
        peer = re.search(r"^PEER-REPORT: *(\S+) *$", text, re.M)
        reports.append({"id": rid, "agent": rid.split("-")[2], "text": text,
                        "peer_report": None if not peer or peer.group(1) == "N/A" else peer.group(1)})
    return reports


def cmd_check_positions(args):
    """Contract-v2 positions of a new report against the run's valid prior reports (gencr_adjudicate.check_report)."""
    try:
        text = read_report(args.report)
        prior = run_reports(args.run_dir, args.reports.split())
    except ValueError as error:
        die(str(error))
    peer = args.attacker if args.agent == args.primary else args.primary
    errors = gencr_adjudicate.check_report(text, args.agent, peer, None if args.peer_report == "N/A" else args.peer_report,
                                           prior, set(args.known.split()))
    if errors:
        die("; ".join(errors[:3]) + ("" if len(errors) <= 3 else " (and %d more)" % (len(errors) - 3)))
    return 0


def cmd_handoff_state(args):
    """The handoff lines of contract v2: what the reviewer must restate, keep, withdraw or answer."""
    peer = args.attacker if args.agent == args.primary else args.primary
    try:
        prior = run_reports(args.run_dir, args.reports.split())
    except ValueError as error:
        die(str(error))
    state = gencr_adjudicate.handoff(prior, args.agent, peer, None if args.peer_report == "N/A" else args.peer_report)
    name = AGENT_NAMES[peer]
    if state["own_live"]:
        print("- Your findings in this review so far (each must be in your '## Findings' with its current version, or "
              "under '## Withdrawn findings' as '- <ID>: withdrawn — <reason>'; leaving one out is invalid): %s"
              % ", ".join(state["own_live"]))
    if state["kept_claims"]:
        print("- Your claims on findings that %s's latest report no longer defines (keep each with its source-qualified "
              "row, or withdraw it): %s" % (name, "; ".join(
                  "- %s (report %s): %s; introduced: ...; severity: ...; blocking: ... — <rationale>   or   - %s (report "
                  "%s): withdrawn — <reason>" % (k["id"], k["source"], k["status"], k["id"], k["source"])
                  for k in state["kept_claims"])))
    if state["own_objections"]:
        print("- Your open supplemental objections (restate each as maintained, conceded or withdrawn): %s" % ", ".join(
            "%s (%s; %s)" % (o["id"], o["finding"], o["topic"]) for o in state["own_objections"]))
    if state["peer_objections"]:
        print("- %s's open supplemental objections to answer (one '- <ID>: accepted|rejected — <rationale>' row each "
              "under '## Supplemental objections'): %s" % (name, ", ".join(
                  "%s (%s; %s)" % (o["id"], o["finding"], o["topic"]) for o in state["peer_objections"])))
    return 0


def cmd_adjudicate(args):
    """The adjudication of the run so far (stop gate): one JSON object on stdout."""
    adj = gencr_adjudicate.adjudicate(run_reports(args.run_dir, args.reports.split()), args.primary, args.attacker)
    print(json.dumps({key: adj[key] for key in ("needs_another_round", "unanimous", "positions_agree", "verdicts_agree",
                                                "primary_verdict", "attacker_verdict", "counts")}))
    print("decision=%s" % ("continue" if adj["needs_another_round"] else "stop"), file=sys.stderr)
    return 0


def cmd_verdict_line(args):
    """The final verdict with its adjudicated qualification, from a saved package (terminal line)."""
    metadata = json.loads(read_text(os.path.join(args.run_dir, "metadata.json")))
    adjudication = metadata.get("adjudication")
    print(gencr_summary.qualification(adjudication).rstrip(".") if adjudication else metadata["outcome"])
    return 0


def cmd_normalize_report(args):
    """Deterministic format normalization (no reviewer call). Writes --out and --record; exit 0 when the normalized
    report is proven to change only formatting, 3 when the original is irreparable."""
    try:
        original = read_report(args.original)
    except ValueError as error:
        original, (normalized, repairs, errors) = None, (None, [], [str(error)])
    else:
        normalized, repairs, errors = gencr_report.normalize(original)
    record = {"original": os.path.basename(args.original), "original_sha256": sha256_file(args.original),
              "repairs": [{"id": r["id"], "label": r["label"], "form": r["form"], "line": r["line"] + 1}
                          for r in repairs]}
    if not errors:
        errors = gencr_report.prove(original, normalized)
        if errors:
            errors = ["the normalization could not be proven formatting-only: " + "; ".join(errors)]
    if errors:
        record.update({"result": "irreparable", "errors": errors})
    else:
        with open(args.out, "w", encoding="utf-8", newline="") as handle:
            handle.write(normalized)
        # The engine saves this output as the canonical report (--canonical) after the same validation.
        record.update({"result": "normalized", "normalized": args.canonical, "normalized_sha256": sha256_file(args.out)})
    with open(args.record, "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2)
    if errors:
        sys.stderr.write("; ".join(errors[:3]) + "\n")
        return 3
    print(", ".join("%s %s: %s" % (r["id"], r["label"], r["form"]) for r in repairs))
    return 0


def cmd_note_normalization(args):
    """Records that a normalized report failed validation (the original stays the report)."""
    record = json.loads(read_text(args.record))
    record.update({"result": args.result, "errors": [args.error]})
    with open(args.record, "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2)
    return 0


def cmd_validate_duplication(args):
    import gencr_duplicates
    result = json.loads(read_text(args.dup))
    text = read_report(args.report)
    if "## Duplication check" not in text.split("\n"):
        die("missing required section '## Duplication check'")
    findings = {f["id"]: f["fields"] for f in parse_findings(text)}
    error = gencr_duplicates.validate(text, result, findings, section(text, "Duplication check"), args.repo)
    if error:
        die(error)
    return 0


def cmd_introduction(args):
    """Prints the oldest commit on the first-parent history of --base-ref that contains --head (nothing if none).
    Containment is monotonic along a first-parent chain, so a binary search needs only log2(n) ancestry checks;
    unlike `rev-list --first-parent --ancestry-path`, it also finds a merge that brought HEAD in indirectly."""
    proc = subprocess.run(["git", "-C", args.repo, "rev-list", "--first-parent", "--reverse", args.base_ref],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        die("cannot read the first-parent history of %s" % args.base_ref)
    chain = proc.stdout.decode().split()
    low, high = 0, len(chain)
    while low < high:
        middle = (low + high) // 2
        if git_is_ancestor(args.repo, args.head, chain[middle]):
            high = middle
        else:
            low = middle + 1
    if low < len(chain):
        print(chain[low])
    return 0


def cmd_outside_repo(args):
    """Exit 0 if --path is outside --repo, 1 if it or any existing ancestor is the repository directory.

    Compares filesystem identity (device + inode), not strings, so case-insensitive or other aliases of the repository
    count as inside; components that do not exist yet are judged by their nearest existing ancestor."""
    repo = os.stat(os.path.realpath(args.repo))
    current = os.path.realpath(os.path.abspath(args.path))
    while True:
        try:
            if os.path.samestat(os.stat(current), repo):
                return 1
        except OSError:
            pass
        parent = os.path.dirname(current)
        if parent == current:
            return 0
        current = parent


def main():
    parser = argparse.ArgumentParser(prog="gencr_support.py")
    sub = parser.add_subparsers(dest="command")
    invoke = sub.add_parser("invoke")
    invoke.add_argument("--agent", choices=("claude", "codex"), required=True)
    for name in ("--prompt", "--report", "--log", "--meta", "--repo"):
        invoke.add_argument(name, required=True)
    invoke.add_argument("--raw", default="")
    invoke.add_argument("--model", default="")
    invoke.add_argument("--settings", default="")
    invoke.add_argument("--add-dir", action="append", default=[])
    invoke.add_argument("--timeout", type=int, default=0)
    invoke.add_argument("--eligibility-pr", default="")
    invoke.add_argument("--eligibility-sha", default="")
    settings = sub.add_parser("trusted-settings")
    settings.add_argument("--tmpdir", default=None)
    repo_id = sub.add_parser("repo-id")
    repo_id.add_argument("--url", default="")
    repo_id.add_argument("--root", required=True)
    no_review = sub.add_parser("no-review")
    for name in ("--out", "--previous-id", "--previous-sha", "--previous-outcome", "--head"):
        no_review.add_argument(name, required=True)
    previous = sub.add_parser("previous")
    for name in ("--search-dir", "--repo", "--repository", "--branch", "--base-branch", "--merge-base", "--head",
                 "--instructions-sha256", "--out"):
        previous.add_argument(name, required=True)
    previous.add_argument("--instructions-version", default=None)
    previous.add_argument("--pr-number", default=None)
    previous.add_argument("--previous", default="")
    previous.add_argument("--scope-method", default="merge-base")
    previous.add_argument("--merge-commit", default="")
    previous.add_argument("--dev", required=True)
    previous.add_argument("--mode", choices=("incremental", "auto", "fresh-check"), default="incremental")
    review_comment = sub.add_parser("review-comment")
    review_comment.add_argument("--summary", required=True)
    sub.add_parser("value-rule")
    check_report = sub.add_parser("check-report")
    check_report.add_argument("--report", required=True)
    check_report.add_argument("--known", default=None)
    positions = sub.add_parser("check-positions")
    for flag in ("--report", "--agent", "--peer-report", "--run-dir", "--reports", "--primary", "--attacker", "--known"):
        positions.add_argument(flag, required=flag not in ("--reports", "--known"), default="")
    handoff = sub.add_parser("handoff-state")
    for flag in ("--agent", "--peer-report", "--run-dir", "--reports", "--primary", "--attacker"):
        handoff.add_argument(flag, required=flag != "--reports", default="")
    verdict_line = sub.add_parser("verdict-line")
    verdict_line.add_argument("--run-dir", required=True)
    adjudicate = sub.add_parser("adjudicate")
    for flag in ("--run-dir", "--reports", "--primary", "--attacker"):
        adjudicate.add_argument(flag, required=True)
    normalize_report = sub.add_parser("normalize-report")
    for name in ("--original", "--out", "--record", "--canonical"):
        normalize_report.add_argument(name, required=True)
    note = sub.add_parser("note-normalization")
    for name in ("--record", "--result", "--error"):
        note.add_argument(name, required=True)
    introduction = sub.add_parser("introduction")
    for name in ("--repo", "--base-ref", "--head"):
        introduction.add_argument(name, required=True)
    package = sub.add_parser("package")
    package.add_argument("--run-dir", required=True)
    package.add_argument("--state", required=True)
    package.add_argument("--legacy-report", default="")
    duplicates = sub.add_parser("duplicates")
    for name in ("--repo", "--previous-sha", "--previous-id", "--merge-base", "--head", "--out", "--prompt-out"):
        duplicates.add_argument(name, required=True)
    validate_dup = sub.add_parser("validate-duplication")
    validate_dup.add_argument("--report", required=True)
    validate_dup.add_argument("--dup", required=True)
    validate_dup.add_argument("--repo", default=None)
    outside = sub.add_parser("outside-repo")
    outside.add_argument("--path", required=True)
    outside.add_argument("--repo", required=True)
    real = sub.add_parser("realpath")
    real.add_argument("path")
    digest = sub.add_parser("sha256")
    digest.add_argument("file")
    args = parser.parse_args()
    if args.command == "previous":
        args.instructions_version = args.instructions_version or None
        args.pr_number = args.pr_number or None
    handlers = {"invoke": cmd_invoke, "trusted-settings": cmd_trusted_settings, "repo-id": cmd_repo_id,
                "previous": cmd_previous, "no-review": cmd_no_review, "package": cmd_package, "duplicates": cmd_duplicates,
                "validate-duplication": cmd_validate_duplication,
                "sha256": lambda a: print(sha256_file(a.file)) or 0,
                "realpath": lambda a: print(os.path.realpath(a.path)) or 0, "outside-repo": cmd_outside_repo,
                "introduction": cmd_introduction, "check-report": cmd_check_report,
                "value-rule": lambda a: print(gencr_report.value_rule()) or 0,
                "check-positions": cmd_check_positions, "handoff-state": cmd_handoff_state,
                "adjudicate": cmd_adjudicate, "verdict-line": cmd_verdict_line,
                "normalize-report": cmd_normalize_report, "note-normalization": cmd_note_normalization,
                "review-comment": cmd_review_comment}
    if args.command not in handlers:
        parser.print_usage(sys.stderr)
        return 2
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
