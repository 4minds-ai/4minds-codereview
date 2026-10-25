#!/usr/bin/env python3
"""Mock `gh` CLI for tests/test_gencr_ci.sh: a tiny in-memory GitHub API persisted in $GH_STATE.

Supports the calls bin/gencr-ci makes: `gh api [-X METHOD] [--paginate --slurp] [--input -] PATH`
and `gh run download RUN -R REPO -n NAME -D DIR`. Every call is appended to $GH_STATE.calls.
"""

import json
import os
import re
import shutil
import sys

state_path = os.environ["GH_STATE"]
with open(state_path) as handle:
    state = json.load(handle)
with open(state_path + ".calls", "a") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")


def save():
    with open(state_path, "w") as handle:
        json.dump(state, handle, indent=1)


def fail(message, code=1):
    sys.stderr.write(message + "\n")
    sys.exit(code)


args = sys.argv[1:]
if args[:2] == ["run", "download"]:
    run_id = args[2]
    name = args[args.index("-n") + 1]
    target = args[args.index("-D") + 1]
    source = state.get("downloads", {}).get("%s/%s" % (run_id, name))
    if not source:
        fail("no artifact %s for run %s" % (name, run_id))
    for entry in os.listdir(source):
        src = os.path.join(source, entry)
        dst = os.path.join(target, entry)
        if os.path.islink(src):
            os.symlink(os.readlink(src), dst)
        elif os.path.isdir(src):
            shutil.copytree(src, dst, symlinks=True)
        else:
            shutil.copyfile(src, dst)
    sys.exit(0)

if args[:1] != ["api"]:
    fail("unsupported gh command: %s" % " ".join(args))
method, body, paginate, path = "GET", None, False, None
i = 1
while i < len(args):
    if args[i] == "-X":
        method = args[i + 1]
        i += 2
        continue
    if args[i] == "--input":
        body = json.load(sys.stdin)
        i += 2
        continue
    if args[i] in ("--paginate", "--slurp"):
        paginate = True
        i += 1
        continue
    path = args[i]
    i += 1
if state.get("fail_paths") and any(p in path for p in state["fail_paths"]):
    fail("HTTP 500 for %s" % path)
path = path.split("?")[0]


def out(value):
    sys.stdout.write(json.dumps(value))
    sys.exit(0)


m = re.match(r"^repos/([^/]+/[^/]+)/pulls/(\d+)$", path)
if m and method == "GET":
    pr = state["prs"].get(m.group(2))
    if not pr or pr["base"]["repo"]["full_name"] != m.group(1):
        fail("HTTP 404")
    out(pr)
m = re.match(r"^repos/([^/]+/[^/]+)/pulls/(\d+)/commits$", path)
if m and method == "GET":
    commits = state.get("pr_commits", {}).get(m.group(2), [])
    size = state.get("commit_page_size", 100)
    pages = [commits[k:k + size] for k in range(0, len(commits), size)] or [[]]
    out(pages if paginate else pages[0])
m = re.match(r"^repos/([^/]+/[^/]+)/issues/(\d+)/comments$", path)
if m and method == "GET":
    comments = [c for c in state["comments"] if c["issue"] == int(m.group(2))]
    pages = [comments[k:k + 2] for k in range(0, len(comments), 2)] or [[]]
    out(pages if paginate else comments)
if m and method == "POST":
    state["next_id"] = state.get("next_id", 1000) + 1
    state["comments"].append({"id": state["next_id"], "issue": int(m.group(2)),
                              "user": {"login": "github-actions[bot]"}, "body": body["body"]})
    save()
    out({"id": state["next_id"]})
m = re.match(r"^repos/([^/]+/[^/]+)/issues/comments/(\d+)$", path)
if m and method == "PATCH":
    for comment in state["comments"]:
        if comment["id"] == int(m.group(2)):
            if comment["user"]["login"] != "github-actions[bot]":
                fail("HTTP 403 cannot edit another user's comment")
            comment["body"] = body["body"]
            save()
            out(comment)
    fail("HTTP 404")
m = re.match(r"^repos/([^/]+/[^/]+)/statuses/([0-9a-f]{40})$", path)
if m and method == "POST":
    state["statuses"].append(dict(body, sha=m.group(2)))
    save()
    out({"id": len(state["statuses"])})
m = re.match(r"^repos/([^/]+/[^/]+)/actions/runs/(\d+)$", path)
if m and method == "GET":
    run = state.get("runs", {}).get(m.group(2))
    if not run:
        fail("HTTP 404")
    out(run)
m = re.match(r"^repos/([^/]+/[^/]+)/actions/runs/(\d+)/artifacts$", path)
if m and method == "GET":
    out({"artifacts": state.get("artifacts", {}).get(m.group(2), [])})
fail("unsupported gh api call: %s %s" % (method, path))
