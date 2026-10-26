#!/usr/bin/env python3
"""Runs .github/workflows/gencr-review.yml locally, job by job and step by step in file order, the way the runner
does: each step's `if:` (an implicit success() unless it uses a status function), its own env and `${{ }}` values,
GITHUB_OUTPUT / GITHUB_PATH, `bash -eo pipefail` for run steps and continue-on-error. Checkout, upload-artifact and
download-artifact are emulated locally; GitHub API calls go to the mock `gh` on PATH. Prints a JSON trace.

Usage: workflow_sim.py WORKFLOW WORKDIR TOOLS TARGET INPUTS_JSON
  TOOLS is the trusted tooling checkout (this repository); TARGET is the pull request checkout (at its head).
"""
import json, os, re, shutil, subprocess, sys

workflow, workdir, tools, target, inputs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], json.loads(sys.argv[5])
text = open(workflow, encoding="utf-8").read()


def block_lines(lines, i, indent):
    """The lines after lines[i] that are indented deeper than `indent` (blank lines included)."""
    out = []
    for line in lines[i + 1:]:
        if line.strip() and len(line) - len(line.lstrip(" ")) <= indent:
            break
        out.append(line)
    while out and not out[-1].strip():
        out.pop()
    return out


def mapping(lines, indent):
    """A flat `key: value` mapping at exactly `indent` spaces."""
    result = {}
    for line in lines:
        if len(line) - len(line.lstrip(" ")) == indent and ":" in line and not line.strip().startswith("#"):
            key, value = line.strip().split(":", 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] == '"':
                value = value[1:-1]
            result[key.strip()] = value
    return result


def parse_steps(job_lines):
    steps, i = [], 0
    while i < len(job_lines):
        if job_lines[i].startswith("      - name: "):
            body = block_lines(job_lines, i, 6)
            step = {"name": job_lines[i][len("      - name: "):].strip()}
            j = 0
            while j < len(body):
                line = body[j]
                if line.startswith("        ") and not line.startswith("         ") and ":" in line:
                    key, value = line.strip().split(":", 1)
                    value = value.strip()
                    sub = block_lines(body, j, 8)
                    if key == "run" and value in ("|", ">"):
                        content = [s[10:] for s in sub]
                        step["run"] = "\n".join(content) + "\n" if value == "|" else " ".join(c.strip() for c in content) + "\n"
                    elif key in ("env", "with"):
                        step[key] = mapping(sub, 10)
                    else:
                        step[key] = value
                j += 1
            steps.append(step)
        i += 1
    return steps


def job(name):
    section = text.split("\n  %s:\n" % name, 1)[1]
    section = re.split(r"\n  [a-z]+:\n", section, 1)[0]
    lines = section.splitlines()
    env_at = [k for k, line in enumerate(lines) if line == "    env:"]
    steps_at = lines.index("    steps:")
    env = mapping(block_lines(lines, env_at[0], 4), 6) if env_at and env_at[0] < steps_at else {}
    head = mapping(lines[:steps_at], 4)
    outputs_at = [k for k, line in enumerate(lines) if line == "    outputs:"]
    outputs = mapping(block_lines(lines, outputs_at[0], 4), 6) if outputs_at else {}
    return {"env": env, "if": head.get("if"), "outputs": outputs, "steps": parse_steps(lines[steps_at + 1:])}


def evaluate(expression, context, status_ok):
    """GitHub expressions as used by this workflow: dotted lookups, 'strings', ==, !=, &&, ||, always()/success()."""
    expression = expression.strip()
    if expression.startswith("${{") and expression.endswith("}}"):
        expression = expression[3:-2].strip()
    def lookup(path):
        value = context
        for part in path.split("."):
            value = value.get(part, "") if isinstance(value, dict) else ""
        return value
    tokens = re.findall(r"'[^']*'|&&|\|\||==|!=|\(|\)|[A-Za-z_][A-Za-z0-9_.-]*\(\)|[A-Za-z_][A-Za-z0-9_.-]*", expression)
    python = []
    for token in tokens:
        if token == "&&":
            python.append(" and ")
        elif token == "||":
            python.append(" or ")
        elif token in ("==", "!=", "(", ")"):
            python.append(" %s " % token)
        elif token.startswith("'"):
            python.append(repr(token[1:-1]))
        elif token == "always()":
            python.append("True")
        elif token == "success()":
            python.append(repr(status_ok))
        elif token == "failure()":
            python.append(repr(not status_ok))
        else:
            python.append(repr(lookup(token)))
    return eval("".join(python))  # noqa: S307 - our own workflow file, fixed grammar


def substitute(value, context):
    return re.sub(r"\$\{\{(.*?)\}\}", lambda m: str(evaluate(m.group(1), context, True)), value)


def should_run(condition, context, status_ok):
    if not condition:
        return status_ok
    uses_status = re.search(r"\b(always|success|failure|cancelled)\(\)", condition)
    result = evaluate(condition, context, status_ok)
    return bool(result) if uses_status else bool(result) and status_ok


def run_job(name, context, trace):
    spec = job(name)
    ws = os.path.join(workdir, name)
    temp = os.path.join(ws, "_temp")
    os.makedirs(temp)
    context = dict(context, runner={"temp": temp}, steps={})
    record = {"steps": [], "outputs": {}}
    trace[name] = record
    if spec["if"] and not should_run(spec["if"], context, True):
        record["result"] = "skipped"
        return record
    path_file = os.path.join(temp, "path")
    open(path_file, "w").close()
    job_env = {k: substitute(v, context) for k, v in spec["env"].items()}
    ok = True
    for step in spec["steps"]:
        entry = {"name": step["name"], "ran": False}
        record["steps"].append(entry)
        if not should_run(step.get("if"), context, ok):
            continue
        entry["ran"] = True
        outputs, status = {}, 0
        uses = step.get("uses", "")
        with_ = {k: substitute(v, context) for k, v in step.get("with", {}).items()}
        if uses.startswith("actions/checkout@"):
            source = tools if with_.get("path") == "tools" else target
            os.symlink(source, os.path.join(ws, with_["path"]))
        elif uses.startswith("actions/upload-artifact@"):
            destination = os.path.join(workdir, "artifacts", with_["name"])
            if os.path.isdir(with_["path"]) and os.listdir(with_["path"]):
                shutil.copytree(with_["path"], destination)
                outputs["artifact-url"] = "https://example.invalid/artifact/" + with_["name"]
            else:
                status = 1
        elif uses.startswith("actions/download-artifact@"):
            source = os.path.join(workdir, "artifacts", with_["name"])
            if os.path.isdir(source):
                shutil.copytree(source, with_["path"])
            else:
                status = 1
        elif "run" in step:
            output_file = os.path.join(temp, "output-%d" % len(record["steps"]))
            open(output_file, "w").close()
            script = os.path.join(temp, "step-%d.sh" % len(record["steps"]))
            with open(script, "w", encoding="utf-8") as handle:
                handle.write(step["run"])
            extra_path = [p for p in open(path_file).read().splitlines() if p]
            env = dict(os.environ, **job_env)
            env.update({k: substitute(v, context) for k, v in step.get("env", {}).items()})
            env.update({"GITHUB_OUTPUT": output_file, "GITHUB_PATH": path_file, "GITHUB_WORKSPACE": ws,
                        "RUNNER_TEMP": temp, "GITHUB_REPOSITORY": context["github"]["repository"],
                        "GITHUB_REF": context["github"]["ref"], "GITHUB_EVENT_NAME": context["github"]["event_name"],
                        "GITHUB_RUN_ID": context["github"]["run_id"], "GITHUB_RUN_ATTEMPT": "1",
                        "PATH": os.pathsep.join(extra_path[::-1] + [os.environ["PATH"]])})
            cwd = os.path.join(ws, step["working-directory"]) if "working-directory" in step else ws
            with open(os.path.join(temp, "log"), "a", encoding="utf-8") as log:
                log.write("== %s\n" % step["name"])
                log.flush()
                status = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", script], cwd=cwd, env=env,
                                        stdout=log, stderr=subprocess.STDOUT).returncode
            for line in open(output_file, encoding="utf-8").read().splitlines():
                if "=" in line:
                    key, value = line.split("=", 1)
                    outputs[key] = value
        entry["status"], entry["outputs"] = status, outputs
        if "id" in step:
            context["steps"][step["id"]] = {"outputs": outputs}
        if status != 0 and step.get("continue-on-error") != "true":
            ok = False
    record["result"] = "success" if ok else "failure"
    record["outputs"] = {k: substitute(v, context) for k, v in spec["outputs"].items()}
    record["log"] = open(os.path.join(temp, "log"), encoding="utf-8").read() if os.path.exists(os.path.join(temp, "log")) else ""
    return record


github = {"token": "ghs-simulated-token", "sha": "0" * 40, "repository": "acme/app", "ref": "refs/heads/main",
          "event_name": "workflow_dispatch", "event": {"action": "", "repository": {"default_branch": "main"}},
          "server_url": "https://github.com", "run_id": "4242"}
base = {"github": github, "inputs": inputs}
trace = {}
trust = run_job("trust", base, trace)
needs = {"trust": {"result": trust["result"], "outputs": trust["outputs"]}}
review = run_job("review", dict(base, needs=needs), trace) if trust["result"] == "success" else {"result": "skipped", "outputs": {}}
needs["review"] = {"result": review["result"], "outputs": review["outputs"]}
run_job("publish", dict(base, needs=needs), trace)
print(json.dumps(trace, indent=2))
