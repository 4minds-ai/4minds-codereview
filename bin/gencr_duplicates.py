"""Incremental duplication pre-search for gencr (standard library only, Python 3.8+).

For an INCREMENTAL review this module lists every change subject (one per changed hunk, including deletion-only hunks)
and searches the recorded HEAD snapshot for textual duplicates of newly added code: exact copies and identifier-renamed
copies (similarity hints, not proof). Semantic duplication is left to the reviewers' targeted searches, which every
subject must account for. Only raw regular blobs of HEAD are read (no working tree, symlinks, submodules, filters or
textconv), within cumulative bounds; hitting a bound makes the index "partial", never "none found".
"""

import hashlib
import json
import os
import re
import subprocess
import time

MAX_SUBJECTS = 200
MAX_CANDIDATES = 12
MAX_PER_SUBJECT = 3
MAX_ORIGINALS = 3
MAX_PAIRS = 50000
# "not applicable" needs a no-code basis: deleted/rename-only/binary subjects or these documentation/text files.
NON_CODE_EXTENSIONS = {"md", "markdown", "rst", "txt", "adoc", "asciidoc", "csv", "tsv", "log"}
NON_CODE_NAMES = {"license", "licence", "notice", "authors", "changelog", "readme", "codeowners"}
SNIPPET_LINES = 15
WINDOW = 4
LIMITS = {"files": 20000, "bytes": 50 * 1024 * 1024, "file_bytes": 1024 * 1024, "windows": 2000000, "seconds": 60}
HASH_FAMILY = {"py", "sh", "bash", "zsh", "rb", "pl", "pm", "yaml", "yml", "toml", "r", "ps1", "tf", "mk"}
C_FAMILY = {"c", "h", "cc", "cpp", "cxx", "hpp", "java", "js", "jsx", "mjs", "cjs", "ts", "tsx", "go", "rs", "cs",
            "kt", "kts", "swift", "php", "scala", "dart", "groovy", "m", "mm"}
KEYWORDS = set("""and as assert async await break case catch class const continue def default defer del delete do elif
else enum except export extends final finally fn for from func function go goto if impl implements import in instanceof
interface is lambda let loop match mod module mut new nil none not null of or package pass private protected pub public
raise return self static struct super switch this throw throws trait true false try type typeof union unsafe use using
var void where while with yield None True False""".split())
IMPORT_RE = re.compile(r"^(import|from|#include|#import|using|use|require|package)\b")
TRIVIAL_RE = re.compile(r"^[\s{}()\[\];,.:]*$")
TOKEN_RE = re.compile(r"""("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)|([A-Za-z_][A-Za-z0-9_]*)|(\S)""")


class Deadline(Exception):
    pass


def blob_size(repo, commit, path, deadline):
    """(mode, size) of a path's entry at a commit, or None when absent; raises RuntimeError on failure."""
    code, listing = git(repo, ["ls-tree", "-z", "-l", commit, "--", path], deadline)
    if code != 0:
        raise RuntimeError("cannot list %s at %s" % (path, commit[:12]))
    for record in listing.decode("utf-8", "surrogateescape").split("\0"):
        if record and record.split("\t", 1)[1] == path:
            mode, kind, _, size = record.split("\t", 1)[0].split()
            return mode, (int(size) if size.isdigit() else -1)
    return None


def read_regular(repo, commit, path, deadline):
    """Raw bytes of a regular file at a commit within the per-file limit; None if absent/not regular/too large."""
    entry = blob_size(repo, commit, path, deadline)
    if not entry or entry[0] not in ("100644", "100755") or not 0 <= entry[1] <= LIMITS["file_bytes"]:
        return None
    code, blob = git(repo, ["cat-file", "blob", "%s:%s" % (commit, path)], deadline)
    return blob if code == 0 else None


def check_deadline(deadline):
    if time.time() > deadline:
        raise Deadline("time budget exhausted")


def git(repo, args, deadline, data=None):
    remaining = deadline - time.time()
    if remaining <= 0:
        raise Deadline("time budget exhausted")
    try:
        proc = subprocess.run(["git", "-C", repo] + args, input=data, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=remaining)
    except subprocess.TimeoutExpired:
        raise Deadline("time budget exhausted")
    return proc.returncode, proc.stdout


# ── normalization ─────────────────────────────────────────────────────────────

def family(path):
    ext = path.rsplit(".", 1)[-1].lower() if "." in os.path.basename(path) else ""
    if ext in HASH_FAMILY:
        return "hash"
    if ext in C_FAMILY:
        return "c"
    return "none"


def strip_comments(text, kind):
    """Removes comments outside string literals; returns the text with the same line count."""
    if kind == "none":
        return text
    out, i, n, quote, block = [], 0, len(text), None, False
    while i < n:
        ch = text[i]
        if block:
            if text.startswith("*/", i):
                block, i = False, i + 2
            else:
                out.append("\n" if ch == "\n" else "")
                i += 1
            continue
        if quote:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if text.startswith(quote, i):
                out.append(quote[1:])
                i += len(quote)
                quote = None
                continue
            if ch == "\n" and len(quote) == 1 and quote != "`":
                quote = None
            i += 1
            continue
        if kind == "hash" and (text.startswith('"""', i) or text.startswith("'''", i)):
            quote = text[i:i + 3]
            out.append(quote)
            i += 3
            continue
        if ch in "\"'" or (ch == "`" and kind == "c"):
            quote = ch
            out.append(ch)
            i += 1
            continue
        if (kind == "hash" and ch == "#") or (kind == "c" and text.startswith("//", i)):
            while i < n and text[i] != "\n":
                i += 1
            continue
        if kind == "c" and text.startswith("/*", i):
            block, i = True, i + 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def normalize_lines(text, path):
    """[(line_no, exact, renamed)] for the non-trivial lines of a file."""
    stripped = strip_comments(text, family(path)).split("\n")
    result = []
    for number, line in enumerate(stripped, 1):
        exact = " ".join(line.split())
        if (not exact or TRIVIAL_RE.match(exact) or IMPORT_RE.match(exact)
                or len(exact.replace(" ", "")) < 8):
            continue
        tokens = []
        for literal, ident, other in TOKEN_RE.findall(exact):
            if literal:
                tokens.append(literal)
            elif ident:
                tokens.append(ident if ident in KEYWORDS or ident[0].isdigit() else "ID")
            else:
                tokens.append(other)
        result.append((number, exact, " ".join(tokens)))
    return result


def windows(lines):
    for k in range(len(lines) - WINDOW + 1):
        chunk = lines[k:k + WINDOW]
        yield (chunk[0][0], chunk[-1][0], [c[0] for c in chunk],
               hashlib.sha1("\n".join(c[1] for c in chunk).encode()).hexdigest(),
               hashlib.sha1("\n".join(c[2] for c in chunk).encode()).hexdigest())


# ── change subjects ───────────────────────────────────────────────────────────

HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@ ?(.*)$")


def change_subjects(repo, previous, head, deadline):
    code, out = git(repo, ["-c", "core.quotePath=false", "diff", "-z", "--name-status", "--find-renames",
                           "--no-ext-diff", "--no-textconv", previous, head], deadline)
    if code != 0:
        raise RuntimeError("cannot list the incremental changes")
    parts = out.decode("utf-8", "surrogateescape").split("\0")
    entries, i = [], 0
    while i < len(parts) and parts[i]:
        status = parts[i]
        if status[0] in "RC":
            entries.append((status[0], parts[i + 1], parts[i + 2]))
            i += 3
        else:
            entries.append((status[0], parts[i + 1], parts[i + 1]))
            i += 2
    subjects, added = [], {}
    for status, old, new in entries:
        if status == "D":
            subjects.append({"kind": "deleted", "path": old, "start": None, "end": None, "label": "file deleted"})
            continue
        if status == "A":
            blob = read_regular(repo, head, new, deadline)
            if blob is None:
                # Too large, a symlink or not a regular file: still a subject, its whole content.
                subjects.append({"kind": "added", "path": new, "start": 1, "end": None,
                                 "label": "new file (not indexed: too large or not a regular file)"})
                continue
            count = blob.count(b"\n") + (0 if blob.endswith(b"\n") or not blob else 1)
            subjects.append({"kind": "added", "path": new, "start": 1, "end": max(count, 1), "label": "new file"})
            added[new] = set(range(1, count + 1))
            continue
        sizes = [blob_size(repo, previous, old, deadline), blob_size(repo, head, new, deadline)]
        if any(entry is None or entry[1] < 0 or entry[1] > LIMITS["file_bytes"] for entry in sizes):
            # Too large (or not a blob) to diff within bounds: the whole file is the subject, unread.
            subjects.append({"kind": "modified", "path": new, "start": 1, "end": None,
                             "label": "modified file (not diffed: too large or not a regular file)"})
            continue
        code, diff = git(repo, ["diff", "-U3", "--no-ext-diff", "--no-textconv", "--no-color",
                                "%s:%s" % (previous, old), "%s:%s" % (head, new)], deadline)
        if code not in (0, 1):
            raise RuntimeError("cannot diff %s" % new)
        lines = diff.decode("utf-8", "replace").split("\n")
        k = 0
        while k < len(lines):
            match = HUNK_RE.match(lines[k])
            if not match:
                k += 1
                continue
            start, length = int(match.group(1)), int(match.group(2) if match.group(2) is not None else 1)
            label = match.group(3).strip()
            k += 1
            head_line, plus, has_plus = start, set(), False
            while k < len(lines) and not lines[k].startswith("@@"):
                line = lines[k]
                if line.startswith("+"):
                    plus.add(head_line)
                    has_plus = True
                    head_line += 1
                elif line.startswith(" "):
                    head_line += 1
                k += 1
            begin, end = (start, start + length - 1) if length else (max(start, 1), max(start, 1))
            kind = "modified" if has_plus else "deletion-only"
            subjects.append({"kind": kind, "path": new, "start": begin, "end": max(end, begin), "label": label})
            added.setdefault(new, set()).update(plus)
        if not any(s["path"] == new for s in subjects):
            # A rename without content changes, a mode change or a binary file: no hunks, still a subject.
            label = "renamed from %s" % old if status == "R" else "changed without text hunks (binary or mode)"
            subjects.append({"kind": "renamed" if status == "R" else "binary-or-mode", "path": new,
                             "start": None, "end": None, "label": label})
    for number, subject in enumerate(subjects, 1):
        subject["id"] = "SUBJ-%d" % number
    return subjects, added


# ── HEAD index ────────────────────────────────────────────────────────────────

def head_blobs(repo, head, deadline, scan):
    code, out = git(repo, ["ls-tree", "-r", "-z", "-l", "--full-tree", head], deadline)
    if code != 0:
        raise RuntimeError("cannot list HEAD")
    entries = []
    for record in out.decode("utf-8", "surrogateescape").split("\0"):
        if not record:
            continue
        meta, path = record.split("\t", 1)
        mode, kind, sha, size = meta.split()
        if mode == "120000":
            scan["skipped"]["symlink"] += 1
        elif mode == "160000" or kind != "blob":
            scan["skipped"]["submodule"] += 1
        elif mode not in ("100644", "100755"):
            scan["skipped"]["other"] += 1
        elif int(size) > LIMITS["file_bytes"]:
            scan["skipped"]["too_large"] += 1
        else:
            entries.append((path, sha, int(size)))
    if entries:
        code, out = git(repo, ["check-attr", "-z", "--stdin", "linguist-generated", "linguist-vendored"], deadline,
                        data=b"".join(p.encode("utf-8", "surrogateescape") + b"\0" for p, _, _ in entries))
        flagged = set()
        fields = out.decode("utf-8", "surrogateescape").split("\0")
        for k in range(0, len(fields) - 2, 3):
            if fields[k + 2] in ("set", "true"):
                flagged.add(fields[k])
        scan["skipped"]["generated_or_vendored"] += len(flagged)
        entries = [e for e in entries if e[0] not in flagged]
    return entries


def read_blobs(repo, entries, deadline):
    """Yields (path, bytes) of the given blobs via one cat-file --batch process."""
    if not entries:
        return
    remaining = deadline - time.time()
    if remaining <= 0:
        raise Deadline("time budget exhausted")
    proc = subprocess.Popen(["git", "-C", repo, "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        out, _ = proc.communicate(b"".join(sha.encode() + b"\n" for _, sha, _ in entries), timeout=remaining)
    except subprocess.TimeoutExpired:
        proc.kill()
        raise Deadline("time budget exhausted")
    pos = 0
    for path, sha, size in entries:
        header_end = out.index(b"\n", pos)
        pos = header_end + 1
        yield path, out[pos:pos + size]
        pos += size + 1


def build_index(repo, head, deadline):
    scan = {"status": "complete", "reason": None, "files_scanned": 0, "bytes": 0, "windows": 0,
            "skipped": {"symlink": 0, "submodule": 0, "other": 0, "too_large": 0, "binary": 0,
                        "generated_or_vendored": 0, "not_utf8": 0}}
    index = {"exact": {}, "renamed": {}}
    texts = {}
    try:
        entries = head_blobs(repo, head, deadline, scan)
        budget, chosen = 0, []
        for entry in entries:
            if len(chosen) >= LIMITS["files"]:
                scan["status"], scan["reason"] = "partial", "file limit (%d) reached" % LIMITS["files"]
                break
            if budget + entry[2] > LIMITS["bytes"]:
                scan["status"], scan["reason"] = "partial", "byte limit (%d MB) reached" % (LIMITS["bytes"] // 1048576)
                break
            budget += entry[2]
            chosen.append(entry)
        for path, data in read_blobs(repo, chosen, deadline):
            if time.time() > deadline:
                raise Deadline("time budget exhausted")
            if b"\0" in data[:8192]:
                scan["skipped"]["binary"] += 1
                continue
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                scan["skipped"]["not_utf8"] += 1
                continue
            texts[path] = text
            scan["files_scanned"] += 1
            scan["bytes"] += len(data)
            lines = normalize_lines(text, path)
            for start, end, numbers, exact, renamed in windows(lines):
                scan["windows"] += 1
                if scan["windows"] > LIMITS["windows"]:
                    raise Deadline("window limit (%d) reached" % LIMITS["windows"])
                for key, digest in (("exact", exact), ("renamed", renamed)):
                    bucket = index[key].setdefault(digest, [])
                    if len(bucket) < 20:
                        bucket.append((path, start, end, numbers))
    except Deadline as error:
        scan["status"], scan["reason"] = "partial", str(error)
    return index, texts, scan


# ── candidates ────────────────────────────────────────────────────────────────

def provenance(repo, commit, path, region, deadline):
    try:
        entry = blob_size(repo, commit, path, deadline)
        if entry is None:
            return "not found at this path"
        blob = read_regular(repo, commit, path, deadline)
        if blob is None:
            return "unknown"
        return "exact region present at this path" if region.encode("utf-8") in blob else "not found at this path"
    except (Deadline, RuntimeError):
        return "unknown"


def find_candidates(repo, subjects, added, index, texts, merge_base, previous, previous_id, deadline):
    """(candidates, truncated, partial_reason). Stops matching at the shared deadline and reports it."""
    pairs, partial = [], None
    try:
        collect_pairs(added, index, texts, pairs, deadline)
    except Deadline as error:
        partial = "matching stopped: %s" % error
    try:
        candidates, truncated = select_candidates(repo, subjects, pairs, texts, merge_base, previous, deadline)
    except Deadline as error:
        return [], False, "candidate selection stopped: %s" % error
    return candidates, truncated, partial


def collect_pairs(added, index, texts, pairs, deadline):
    for path, numbers in sorted(added.items()):
        text = texts.get(path)
        if text is None:
            continue
        # Checked on the first window of every file and every 256 windows after.
        for count, (start, end, lines, exact, renamed) in enumerate(windows(normalize_lines(text, path))):
            if count % 256 == 0:
                check_deadline(deadline)
            if sum(1 for n in lines if n in numbers) < WINDOW - 1:
                continue
            for kind, digest in (("exact", exact), ("renamed", renamed)):
                # An original is existing code: it overlaps no added line of its file and, in the same file,
                # not the new window itself (so a block never matches its own overlapping windows).
                hits = [h for h in index[kind].get(digest, [])
                        if not set(h[3]) & (added.get(h[0], set()) | (set(lines) if h[0] == path else set()))]
                if hits:
                    for hit in hits:
                        pairs.append([kind, path, start, end, hit[0], hit[1], hit[2]])
                    if len(pairs) > MAX_PAIRS:
                        raise Deadline("match limit (%d pairs) reached" % MAX_PAIRS)
                    break


def select_candidates(repo, subjects, pairs, texts, merge_base, previous, deadline):
    # pairs is bounded by MAX_PAIRS; the deadline is checked on the first pair and every 1024 after.
    pairs.sort(key=lambda p: (p[1], p[4], p[2], p[5]))
    merged = []
    for count, pair in enumerate(pairs):
        if count % 1024 == 0:
            check_deadline(deadline)
        last = merged[-1] if merged else None
        if (last and last[1] == pair[1] and last[4] == pair[4] and pair[2] <= last[3] + 1
                and pair[5] <= last[6] + 1 and pair[5] >= last[5]):
            last[3], last[6] = max(last[3], pair[3]), max(last[6], pair[6])
            if pair[0] == "renamed":
                last[0] = "renamed" if last[0] == "renamed" else last[0]
        else:
            merged.append(list(pair))
    groups = {}
    check_deadline(deadline)
    for kind, path, start, end, opath, ostart, oend in merged:
        subject = next((s for s in subjects if s["path"] == path and s["start"] is not None
                        and s["start"] <= end and start <= (s["end"] or float("inf"))), None)
        if subject is None:
            continue
        key = (subject["id"], path, start, end)
        groups.setdefault(key, {"subject": subject["id"], "kind": kind, "path": path, "start": start, "end": end,
                                "originals": []})["originals"].append((opath, ostart, oend))
    ranked = sorted(groups.values(), key=lambda g: (-(g["end"] - g["start"]), g["path"], g["start"]))
    chosen, per_subject = [], {}
    # Round-robin across subjects so one boilerplate-heavy block cannot take every slot.
    while len(chosen) < MAX_CANDIDATES:
        progressed = False
        for subject in [s["id"] for s in subjects]:
            for group in ranked:
                if group["subject"] == subject and group not in chosen and per_subject.get(subject, 0) < MAX_PER_SUBJECT:
                    if len(chosen) < MAX_CANDIDATES:
                        chosen.append(group)
                        per_subject[subject] = per_subject.get(subject, 0) + 1
                        progressed = True
                    break
        if not progressed:
            break
    candidates = []
    for number, group in enumerate(chosen, 1):
        new_lines = texts[group["path"]].split("\n")
        originals = []
        for opath, ostart, oend in group["originals"][:MAX_ORIGINALS]:
            olines = texts[opath].split("\n")
            region = "\n".join(olines[ostart - 1:oend])
            originals.append({"path": opath, "start": ostart, "end": oend,
                              "snippet": "\n".join(olines[ostart - 1:min(oend, ostart + SNIPPET_LINES - 1)]),
                              "provenance": {"merge_base": provenance(repo, merge_base, opath, region, deadline),
                                             "previous_review": provenance(repo, previous, opath, region, deadline)}})
        candidates.append({"id": "DUP-%d" % number, "subject": group["subject"], "kind": group["kind"],
                           "path": group["path"], "start": group["start"], "end": group["end"],
                           "snippet": "\n".join(new_lines[group["start"] - 1:min(group["end"], group["start"] + SNIPPET_LINES - 1)]),
                           "originals": originals})
    return candidates, len(ranked) > len(chosen)


def apply_limit_overrides(spec):
    """GENCR_DUP_LIMITS="files=10,bytes=1000,windows=50,seconds=5" lowers the index bounds (used by tests)."""
    for item in filter(None, (spec or "").split(",")):
        key, _, value = item.partition("=")
        if key in LIMITS and value.isdigit():
            LIMITS[key] = int(value)


def analyze(repo, previous, previous_id, merge_base, head):
    apply_limit_overrides(os.environ.get("GENCR_DUP_LIMITS"))
    deadline = time.time() + LIMITS["seconds"]
    try:
        subjects, added = change_subjects(repo, previous, head, deadline)
    except Deadline as error:
        return {"schema": 1, "previous_sha": previous, "previous_id": previous_id, "merge_base": merge_base,
                "head": head, "subjects": [], "candidates": [], "candidates_truncated": False,
                "too_many_subjects": False, "subjects_incomplete": "listing the change subjects stopped: %s" % error,
                "max_subjects": MAX_SUBJECTS, "head_files": {}, "index": {"status": "not built", "reason": str(error)}}
    result = {"schema": 1, "previous_sha": previous, "previous_id": previous_id, "merge_base": merge_base,
              "head": head, "subjects": subjects, "candidates": [], "candidates_truncated": False,
              "too_many_subjects": len(subjects) > MAX_SUBJECTS, "subjects_incomplete": None,
              "max_subjects": MAX_SUBJECTS, "head_files": {}}
    if result["too_many_subjects"]:
        result["index"] = {"status": "not built", "reason": "%d subjects exceed the limit of %d" % (len(subjects), MAX_SUBJECTS)}
        return result
    index, texts, scan = build_index(repo, head, deadline)
    result["candidates"], result["candidates_truncated"], partial = find_candidates(
        repo, subjects, added, index, texts, merge_base, previous, previous_id, deadline)
    if partial:
        scan["status"], scan["reason"] = "partial", (scan["reason"] + "; " if scan["reason"] else "") + partial
    result["index"] = scan
    result["head_files"] = {path: text.count("\n") + (0 if text.endswith("\n") or not text else 1)
                            for path, text in texts.items()}
    return result


def indent(text):
    return "\n".join("      " + line for line in text.split("\n"))


def render_prompt(result):
    index = result["index"]
    lines = ["Duplication check (INCREMENTAL; gencr pre-search — heuristic hints, not proof):"]
    if index.get("status") == "complete":
        lines.append("- Textual index: complete (%d files, %d windows; skipped: %s)" % (
            index["files_scanned"], index["windows"], ", ".join("%s %d" % kv for kv in index["skipped"].items() if kv[1]) or "none"))
    else:
        lines.append("- Textual index: %s (%s). Candidates below may be incomplete; your targeted searches must cover "
                     "every subject." % (index.get("status"), index.get("reason")))
    lines.append("- Change subjects (every one needs a line in \"## Duplication check\"):")
    for subject in result["subjects"]:
        if subject["start"] and subject["end"]:
            where = "%s:%s-%s" % (subject["path"], subject["start"], subject["end"])
        elif subject["start"]:
            where = "%s (whole file)" % subject["path"]
        else:
            where = subject["path"]
        lines.append("  - %s [%s] %s%s" % (subject["id"], subject["kind"], where,
                                          (" (%s)" % subject["label"]) if subject["label"] else ""))
    if result["candidates"]:
        lines.append("- Textual duplicate candidates (exact = same code after whitespace/comment normalization; renamed = "
                     "same structure with different identifiers):")
        for cand in result["candidates"]:
            lines.append("  - %s (%s) for %s: new %s:%d-%d" % (cand["id"], cand["kind"], cand["subject"], cand["path"],
                                                                 cand["start"], cand["end"]))
            lines.append("    New code:")
            lines.append(indent(cand["snippet"]))
            for original in cand["originals"]:
                prov = original["provenance"]
                lines.append("    Existing code %s:%d-%d (merge-base %s: %s; previous review %s (%s): %s):" % (
                    original["path"], original["start"], original["end"], result["merge_base"][:12],
                    prov["merge_base"], result["previous_id"], result["previous_sha"][:12], prov["previous_review"]))
                lines.append(indent(original["snippet"]))
        if result["candidates_truncated"]:
            lines.append("  - (more textual matches exist than are shown; find them with your targeted searches)")
    else:
        lines.append("- Textual duplicate candidates: none found by the textual pre-search. This is NOT evidence that "
                     "no duplication exists; every subject still needs your targeted search.")
    lines += [
        "- For every subject, look for existing equivalent implementations OUTSIDE the incremental diff, including code",
        "  added earlier in this pull request and other new code in this change, with targeted searches (Grep/rg) on the",
        "  subject's key identifiers, called APIs, constants and distinctive literals. Do not read or re-review unrelated",
        "  code: existing implementations are comparison evidence only, and previously approved code is not re-reviewed.",
        "- Actionable duplication: the same responsibility or logic implemented again (exact, copied with renames, or",
        "  semantically equivalent). Not actionable: legitimate reuse (calling or thinly wrapping the existing code,",
        "  interface implementations, tests/fixtures) and common patterns (idioms, boilerplate); say concretely why. A",
        "  wrapper that repeats substantial logic is not exempt.",
    ]
    return "\n".join(lines) + "\n"


# ── report validation ─────────────────────────────────────────────────────────

QUOTED_LOC_RE = re.compile(r"^`(.+):(\d+)(?:-(\d+))?`(?:\s.*)?$")
LOC_RE = re.compile(r"^(.+?):(\d+)(?:-(\d+))?(?:\s.*)?$")


def parse_location(value):
    """(path, start, end) from 'path:start-end' or a backtick-quoted location, keeping every path character."""
    value = (value or "").strip()
    match = QUOTED_LOC_RE.match(value) or LOC_RE.match(value)
    if not match:
        return None
    start = int(match.group(2))
    end = int(match.group(3) or start)
    return match.group(1), start, max(start, end)


def overlaps(a_start, a_end, b_start, b_end):
    return a_start <= b_end and b_start <= a_end


NO_CODE_KINDS = ("deleted", "renamed", "binary-or-mode")


def is_non_code(path):
    """Documentation/text by extension, or an extensionless documentation name (AUTHORS, README). authors.py is code."""
    name = os.path.basename(path).lower()
    if "." in name:
        return name.rsplit(".", 1)[-1] in NON_CODE_EXTENSIONS
    return name in NON_CODE_NAMES


def validate(report_text, result, findings, section_lines, repo=None):
    """Returns an error message, or None. findings: {id: fields}."""
    subjects = {s["id"]: s for s in result["subjects"]}
    candidates = {c["id"]: c for c in result["candidates"]}
    seen = {}
    for line in section_lines:
        match = re.match(r"^- \**((?:SUBJ|DUP)-\d+)\**:\s*(.*)$", line)
        if match:
            seen.setdefault(match.group(1), match.group(2).strip())
    for sid, subject in subjects.items():
        body = seen.get(sid)
        if body is None:
            return "'## Duplication check' has no line for %s" % sid
        m = re.match(r"^(duplicate \(((?:CLAUDE|CODEX)-\d+)\)|no duplicate found|not applicable)\s*[—-]+\s*(.*)$", body, re.I)
        if not m or not m.group(3).strip():
            return "%s must be 'duplicate (ID)', 'no duplicate found' or 'not applicable' followed by — and its account" % sid
        result_kind, detail = m.group(1).lower(), m.group(3)
        if result_kind.startswith("not applicable"):
            if subject["kind"] not in NO_CODE_KINDS and not is_non_code(subject["path"]):
                return ("%s (%s) may contain code and cannot be 'not applicable'; give a searched:/compared: "
                        "account" % (sid, subject["path"]))
        else:
            searched = re.search(r"searched:\s*([^;]*)", detail, re.I)
            if not searched or not searched.group(1).strip():
                return "%s needs a non-empty 'searched:' account" % sid
            compared = re.search(r"compared:\s*(.*)$", detail, re.I)
            if not compared or not compared.group(1).strip():
                return "%s needs a non-empty 'compared:' account" % sid
        if result_kind.startswith("duplicate"):
            error = check_finding(m.group(2), findings, subject["path"], subject["start"], subject["end"],
                                  None, result, repo)
            if error:
                return "%s: %s" % (sid, error)
    for did, cand in candidates.items():
        body = seen.get(did)
        if body is None:
            return "'## Duplication check' has no line for %s" % did
        m = re.match(r"^(duplicate \(((?:CLAUDE|CODEX)-\d+)\)|legitimate reuse|common pattern|not duplicate)\s*[—-]+\s*(\S.*)$", body, re.I)
        if not m:
            return "%s must be 'duplicate (ID)', 'legitimate reuse', 'common pattern' or 'not duplicate' followed by — and evidence" % did
        if m.group(1).lower().startswith("duplicate"):
            error = check_finding(m.group(2), findings, cand["path"], cand["start"], cand["end"], cand["originals"],
                                  result, repo)
            if error:
                return "%s: %s" % (did, error)
    return None


def check_finding(finding_id, findings, path, start, end, originals, result, repo=None):
    fields = findings.get(finding_id)
    if fields is None:
        return "finding %s is not defined in this report's Findings" % finding_id
    new = parse_location(fields.get("File"))
    end = end if end is not None else float("inf")
    if not new or new[0] != path or start is None or not overlaps(new[1], new[2], start, end):
        return "finding %s needs 'File: %s:<start>-<end>' within the new code (lines %s-%s)" % (finding_id, path, start, end)
    original = parse_location(fields.get("Duplicate of"))
    if not original:
        return "finding %s needs 'Duplicate of: <original path>:<start>-<end>'" % finding_id
    if originals is not None:
        if not any(o["path"] == original[0] and overlaps(original[1], original[2], o["start"], o["end"]) for o in originals):
            return "finding %s 'Duplicate of' does not match the candidate's existing code" % finding_id
    else:
        # Any regular file at HEAD may hold the original, indexed or not (a partial index does not limit evidence).
        count = result["head_files"].get(original[0])
        if count is None and repo:
            try:
                blob = read_regular(repo, result["head"], original[0], time.time() + 15)
            except (Deadline, RuntimeError):
                return "finding %s 'Duplicate of' could not be verified at HEAD (git lookup failed)" % finding_id
            if blob is not None:
                count = blob.count(b"\n") + (0 if blob.endswith(b"\n") or not blob else 1)
        if count is None:
            return ("finding %s 'Duplicate of' names %s, which is not a regular file (within the 1 MB limit) at HEAD"
                    % (finding_id, original[0]))
        if original[2] > count:
            return "finding %s 'Duplicate of' range ends after line %d of %s" % (finding_id, count, original[0])
        if original[0] == path and overlaps(original[1], original[2], new[1], new[2]):
            return "finding %s 'Duplicate of' overlaps its own new code (%s:%d-%d)" % (finding_id, path, new[1], new[2])
    return None


def save(result, path):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=1)
