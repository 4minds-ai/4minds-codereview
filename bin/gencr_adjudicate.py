"""Chronological adjudication of a two-reviewer gencr review (contract v2). Standard library only (Python 3.8+).

The valid reports of a run are folded in invocation order into a claim ledger. A claim is (finding, reviewer): the
author's claim starts with its definition and ends only with its own explicit withdrawal; the other reviewer's claim is
its latest explicit position (accepted, disputed, rejected, or a source-qualified withdrawal). A finding is reportable
("live") while any claim on it is live. For every live finding four facets are compared between the two latest
positions — existence, introduced by this change, severity, merge-blocking — together with the version each position
assessed, and finding-linked supplemental objections are tracked with their own lifecycle. Prose is rationale only:
nothing here infers a position from text.

Per-finding status (first match wins): opposed > unknown (legacy facets) > not reassessed > agreed. The primary
reviewer's latest valid verdict is the review's verdict; the attacker's disagreements are recorded, never a veto.
Counting unit everywhere: one per live finding (attacker objections = live findings whose status is opposed).
"""

import gencr_report

VERSION = 1
STATUSES = ("opposed", "unknown", "not reassessed", "agreed")
FACETS = ("existence", "introduced", "severity", "blocking")


def _legacy_positions(text):
    """A pre-v2 report: findings and plain dispositions without facets (their facets are unknown)."""
    lines = text.split("\n")
    pos = {"findings": [], "blockers": [], "rows": [], "withdrawn": [], "objections": [], "responses": [],
           "disputes": [], "errors": []}
    body = gencr_report.section_body(lines, "Merge blockers")
    if body:
        for line in lines[body[0]:body[1]]:
            match = gencr_report.re.match(r"^- \**(" + gencr_report.ID_RE + r")", line)
            if match:
                pos["blockers"].append(match.group(1))
    for f in gencr_report.parse(text)["findings"]:
        pos["findings"].append({"id": f["id"], "title": f["title"], "values": f["values"],
                                "severity": gencr_report.severity_class(f["values"].get("Severity")), "introduced": None,
                                "blocking": f["id"] in pos["blockers"]})
    body = gencr_report.section_body(lines, "Disposition of peer findings")
    if body:
        for line in lines[body[0]:body[1]]:
            match = gencr_report.re.match(r"^- \**(" + gencr_report.ID_RE + r")\**:\s*(accepted|rejected|disputed)\b"
                                          r"\s*(?:—|–|:| - )?\s*(.*)$", line, gencr_report.re.I)
            if match:
                pos["rows"].append({"id": match.group(1).upper(), "source": None, "status": match.group(2).lower(),
                                    "introduced": None, "severity": None, "blocking": None, "rationale": match.group(3),
                                    "legacy": True})
    tail = [line.strip() for line in lines if line.strip()][-3:]
    for line in tail:
        key, _, value = line.partition(": ")
        if key in ("VERDICT", "PEER-AGREEMENT", "PEER-REPORT"):
            pos[{"VERDICT": "verdict", "PEER-AGREEMENT": "agreement", "PEER-REPORT": "peer_report"}[key]] = value.strip()
    return pos


def _facets_of_definition(definition):
    return {"introduced": definition["introduced"], "severity": definition["severity"], "blocking": definition["blocking"]}


def _version(definition):
    """A definition's version: its title and field values plus the author's positions — membership in Merge blockers
    is not a field, so a blocking-only change is a new version the other reviewer has not assessed."""
    return [definition["fingerprint"], _facets_of_definition(definition)]


def _compare(author, peer):
    """Facet states between the author's positions (on the version the peer assessed) and the peer's position."""
    facets = {}
    status = peer["existence"]
    facets["existence"] = "agreed" if status == "accepted" else "opposed"
    for name in ("introduced", "severity", "blocking"):
        if status == "rejected":
            facets[name] = "n/a"
        elif peer.get(name) is None or author.get(name) is None:
            facets[name] = "unknown"
        else:
            facets[name] = "agreed" if peer[name] == author[name] else "opposed"
    return facets


def derive(author, peer, positions, objection_ids):
    """(live, status, facets, retained) of a finding from its two latest positions and its active supplemental
    objections — the truth table of the module docstring; used to build and to validate an adjudication."""
    mine, theirs = positions[author], positions.get(peer)
    facets, retained, live = {name: "n/a" for name in FACETS}, False, True
    if mine["existence"] == "withdrawn":
        peer_claims = theirs is not None and theirs["existence"] in ("accepted", "disputed")
        live = peer_claims or bool(objection_ids)
        status = "opposed" if live else "agreed"
        if peer_claims:
            facets["existence"] = "opposed"
            retained = theirs["order"] < mine["order"]
    elif theirs is None or theirs["existence"] == "withdrawn":
        # No position yet, or the peer withdrew its claim on a version the author still defines.
        status = "not reassessed"
    else:
        facets = _compare(theirs["assessed_author"], theirs)
        states = set(facets.values())
        if theirs["assessed_version"] == "current":
            status = "opposed" if "opposed" in states else ("unknown" if "unknown" in states else "agreed")
        elif "opposed" in states:
            status, retained = "opposed", True
        else:
            status = "unknown" if "unknown" in states else "not reassessed"
    if objection_ids:
        status = "opposed"
    return live, status if live else "agreed", facets, bool(retained and live)


def objection(oid, history, responses):
    """A supplemental objection from its claimant rows (history) and the other reviewer's responses, both in order.
    Its version is the claimant's latest (finding, topic, text); the latest response to that version decides it."""
    latest = history[-1]
    claimant = latest["agent"]

    def version(row):
        return [row["finding"], row["topic"], row["text"]]

    answers = []
    for r in responses:
        if r["agent"] == claimant:
            continue
        seen = [c for c in history if c["report"] == r["answered"]]
        answers.append(dict(r, version="current" if seen and version(seen[-1]) == version(latest) else "earlier"))
    applicable = [r for r in answers if r["version"] == "current"]
    state, resolution = "active", None
    if latest["status"] in ("conceded", "withdrawn"):
        state, resolution = "resolved", "%s by %s in report %s" % (latest["status"], claimant, latest["report"])
    elif applicable and applicable[-1]["status"] == "accepted":
        state, resolution = "resolved", "accepted by %s in report %s" % (applicable[-1]["agent"], applicable[-1]["report"])
    last = answers[-1] if answers else None
    return {"id": oid, "claimant": claimant, "finding": latest["finding"], "topic": latest["topic"],
            "status": latest["status"], "text": latest["text"], "report": latest["report"],
            "state": state, "resolution": resolution,
            "latest_response": {key: last[key] for key in ("agent", "report", "status", "text", "version")} if last else None,
            "history": [{key: c[key] for key in ("agent", "report", "status", "finding", "topic", "text")} for c in history],
            "responses": [{key: r[key] for key in ("agent", "report", "status", "answered", "text")} for r in responses]}


def adjudicate(reports, primary, attacker):
    """reports: [{"id", "agent", "peer_report" (or None), "text", optional "contract" (1 = legacy)}] — the run's
    valid reports in invocation order. Returns the adjudication object (see module docstring)."""
    parsed = []
    for order, report in enumerate(reports):
        pos = _legacy_positions(report["text"]) if report.get("contract") == 1 else gencr_report.parse_positions(report["text"])
        parsed.append(dict(report, order=order, pos=pos))
    other = {primary: attacker, attacker: primary}
    ledger = {}

    def entry(identifier):
        prefix = identifier.split("-")[0].lower()
        return ledger.setdefault(identifier, {"id": identifier, "author": prefix, "defs": [], "withdrawals": [],
                                              "rows": [], "statements": []})

    claims, responses = {}, {}
    for rep in parsed:
        agent, order, rid, pos = rep["agent"], rep["order"], rep["id"], rep["pos"]
        for f in pos["findings"]:
            entry(f["id"])["defs"].append({"order": order, "report": rid, "agent": agent, "title": f["title"],
                                           "fingerprint": gencr_report.fingerprint(f), "introduced": f["introduced"],
                                           "severity": f["severity"], "blocking": f["blocking"]})
        for w in pos["withdrawn"]:
            e = entry(w["id"])
            e["withdrawals"].append({"order": order, "report": rid, "agent": agent, "reason": w["reason"]})
            e["statements"].append({"agent": agent, "report": rid, "order": order, "kind": "withdrawal", "text": w["reason"]})
        for row in pos["rows"]:
            e = entry(row["id"])
            e["rows"].append(dict(row, order=order, report=rid, agent=agent,
                                  assessed=row.get("source") or rep.get("peer_report")))
            if row.get("rationale"):
                e["statements"].append({"agent": agent, "report": rid, "order": order, "kind": "rationale",
                                        "text": row["rationale"]})
        for d in pos["disputes"]:
            entry(d["id"])["statements"].append({"agent": agent, "report": rid, "order": order, "kind": "dispute",
                                                 "text": d["text"]})
        for o in pos["objections"]:
            claims.setdefault(o["id"], []).append(dict(o, report=rid, agent=agent))
        for o in pos["responses"]:
            responses.setdefault(o["id"], []).append(dict(o, report=rid, agent=agent, answered=rep.get("peer_report")))

    def touches(e, agent, after):
        """Reports of `agent` after order `after` that state a position on the finding (definition, row, withdrawal)."""
        orders = [d for d in e["defs"] if d["agent"] == agent and d["order"] > after]
        orders += [r for r in e["rows"] if r["agent"] == agent and r["order"] > after]
        orders += [w for w in e["withdrawals"] if w["agent"] == agent and w["order"] > after]
        return sorted(orders, key=lambda x: x["order"])

    objections = {oid: objection(oid, rows, responses.get(oid, [])) for oid, rows in claims.items()}

    findings = {}
    for identifier, e in ledger.items():
        author = e["author"] if any(d["agent"] == e["author"] for d in e["defs"]) else (
            e["defs"][0]["agent"] if e["defs"] else e["author"])
        peer = other.get(author)
        own = [d for d in e["defs"] if d["agent"] == author]
        if not own:
            continue  # only referenced (e.g. a lineage ID) — nothing to adjudicate
        current = own[-1]
        # The withdrawal is when it happened: the first after the latest definition (later re-listings repeat it).
        withdrawal = next((w for w in e["withdrawals"] if w["agent"] == author and w["order"] > current["order"]), None)
        peer_events = [dict(r, kind="row") for r in e["rows"] if r["agent"] == peer]
        peer_events += [dict(d, kind="definition", status="accepted") for d in e["defs"] if d["agent"] == peer]
        peer_events.sort(key=lambda x: x["order"])
        peer_pos = peer_events[-1] if peer_events else None

        positions = {author: {"role": "author", "report": (withdrawal or current)["report"],
                              "order": (withdrawal or current)["order"],
                              "existence": "withdrawn" if withdrawal else "asserted",
                              "introduced": None if withdrawal else current["introduced"],
                              "severity": None if withdrawal else current["severity"],
                              "blocking": None if withdrawal else current["blocking"]}}
        if peer_pos is not None:
            if peer_pos["kind"] == "definition":
                assessed, assessed_version = current, "current"
            else:
                # The version assessed: the author's definition in the report the row answered. A later definition
                # with other field values or another blocking position is a version the peer has not assessed.
                assessed = next((d for d in own if d["report"] == peer_pos["assessed"]), None)
                assessed_version = ("current" if assessed and _version(assessed) == _version(current)
                                    and assessed["order"] <= current["order"] else "earlier")
            positions[peer] = {"role": "peer", "report": peer_pos["report"], "order": peer_pos["order"],
                               "existence": peer_pos["status"], "introduced": peer_pos.get("introduced"),
                               "severity": peer_pos.get("severity"), "blocking": peer_pos.get("blocking"),
                               "assessed_report": peer_pos.get("assessed") or peer_pos["report"],
                               "assessed_version": assessed_version,
                               "assessed_author": _facets_of_definition(assessed or current)}
        live_objections = sorted(o["id"] for o in objections.values() if o["finding"] == identifier and o["state"] == "active")
        live, status, facets, retained = derive(author, peer, positions, live_objections)

        events, last = [], {}
        for item in sorted([("definition", d) for d in e["defs"]] + [("row", r) for r in e["rows"]]
                           + [("withdrawal", w) for w in e["withdrawals"]], key=lambda x: x[1]["order"]):
            kind, x = item
            if kind == "definition":
                prev = last.get(("def", x["agent"]))
                event = "raised" if prev is None else ("maintained" if prev == _version(x) else "modified")
                last[("def", x["agent"])] = _version(x)
                detail = None
            elif kind == "withdrawal":
                event, detail = "withdrawn", x["reason"]
            else:
                key = (x["status"], x.get("introduced"), x.get("severity"), x.get("blocking"))
                prev = last.get(("row", x["agent"]))
                event = "maintained" if prev == key else x["status"]
                last[("row", x["agent"])] = key
                detail = None
            events.append({"report": x["report"], "order": x["order"], "agent": x["agent"], "event": event,
                           "detail": detail})

        statements = []
        for s in sorted(e["statements"], key=lambda x: x["order"]):
            later = touches(e, other.get(s["agent"]), s["order"])
            statements.append(dict(s, answered_later_by=({"agent": later[-1]["agent"], "report": later[-1]["report"]}
                                                         if later else None)))
        response = None
        prim = [s for s in statements if s["agent"] == primary and s["kind"] in ("rationale", "dispute", "withdrawal")]
        if author != primary and [r for r in e["rows"] if r["agent"] == primary]:
            row = [r for r in e["rows"] if r["agent"] == primary][-1]
            response = {"report": row["report"], "text": row.get("rationale") or ""}
        elif prim:
            response = {"report": prim[-1]["report"], "text": prim[-1]["text"]}
        findings[identifier] = {
            "id": identifier, "author": author, "live": live, "status": status,
            "definition": {"report": current["report"], "title": current["title"]},
            "withdrawn": {"report": withdrawal["report"], "reason": withdrawal["reason"]} if withdrawal else None,
            "positions": positions, "facets": facets, "retained": retained,
            "objections": live_objections, "history": events, "statements": statements,
            "primary_response": response}

    def verdict_of(agent):
        mine = [p for p in parsed if p["agent"] == agent]
        return (mine[-1]["pos"].get("verdict"), mine[-1]["id"]) if mine else (None, None)

    primary_verdict, primary_report = verdict_of(primary)
    attacker_verdict, attacker_report = verdict_of(attacker)
    return finish({"version": VERSION, "rule": "primary-authority", "primary": primary, "attacker": attacker,
                   "primary_report": primary_report, "primary_verdict": primary_verdict,
                   "attacker_report": attacker_report, "attacker_verdict": attacker_verdict,
                   "findings": findings, "objections": objections})


def summarize(findings, objections):
    live = [f for f in findings.values() if f["live"]]
    opposed = [f for f in live if f["status"] == "opposed"]
    # Retained: the opposition is known only on an earlier version (no current-version or supplemental opposition).
    retained = [f for f in opposed if f["retained"] and not f["objections"]]
    counts = {"attacker_objections": len(opposed), "current_version": len(opposed) - len(retained),
              "retained_earlier_version": len(retained),
              "not_reassessed": sum(f["status"] == "not reassessed" for f in live),
              "unknown": sum(f["status"] == "unknown" for f in live), "agreed": sum(f["status"] == "agreed" for f in live),
              "live_findings": len(live),
              "supplemental_active": sum(o["state"] == "active" for o in objections.values())}
    positions_agree = all(f["status"] == "agreed" for f in live) and counts["supplemental_active"] == 0
    return counts, positions_agree


def flags(adj):
    """The derived counts and flags of an adjudication (its verdicts, findings and objections given)."""
    counts, positions_agree = summarize(adj["findings"], adj["objections"])
    verdicts_agree = adj["primary_verdict"] == adj["attacker_verdict"]
    live = [f for f in adj["findings"].values() if f["live"]]
    return {"counts": counts, "positions_agree": positions_agree, "verdicts_agree": verdicts_agree,
            "unanimous": verdicts_agree and positions_agree,
            "needs_another_round": (not verdicts_agree) or counts["supplemental_active"] > 0
            or any(f["status"] in ("opposed", "not reassessed") for f in live)}


def finish(adj):
    adj.update(flags(adj))
    return adj


# ── Validation of a stored adjudication (package boundary) ─────────────────────

AGENTS = ("claude", "codex")
VERDICTS = ("APPROVED", "REQUEST CHANGES")
INTRODUCED = ("yes", "no", None)
SEVERITY_VALUES = gencr_report.SEVERITIES + ("unknown", None)
BLOCKING = (True, False, None)


def _same(a, b):
    """Equality with JSON types kept apart (True is not 1, "false" is not False)."""
    if type(a) is not type(b):
        return False
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(_same(a[k], b[k]) for k in a)
    if isinstance(a, list):
        return len(a) == len(b) and all(_same(x, y) for x, y in zip(a, b))
    return a == b


def _is(value, allowed):
    return any(value is v if v is None or isinstance(v, bool) else (type(value) is type(v) and value == v)
               for v in allowed)


def _position_problem(position, role, agent, owner, order):
    """Why one stored position is malformed, or None; owner = {report id: agent} and order = {report id: invocation
    index} of the valid invocations."""
    if not isinstance(position, dict):
        return "is not an object"
    if position.get("role") != role or owner.get(position.get("report")) != agent:
        return "does not cite a report of %s in this review" % agent
    if type(position.get("order")) is not int or position["order"] != order[position["report"]]:
        return "has an order that is not its report's place in the invocations"
    facets = ("introduced", "severity", "blocking")
    if any(name not in position for name in facets) or not _is(position["introduced"], INTRODUCED) \
            or not _is(position["severity"], SEVERITY_VALUES) or not _is(position["blocking"], BLOCKING):
        return "has a missing or ill-typed facet"
    if role == "author":
        if position.get("existence") not in ("asserted", "withdrawn") or (
                position["existence"] == "withdrawn" and any(position[name] is not None for name in facets)):
            return "has an invalid existence"
        return None
    if position.get("existence") not in ("accepted", "disputed", "rejected", "withdrawn"):
        return "has an invalid existence"
    if position.get("assessed_version") not in ("current", "earlier") or position.get("assessed_report") not in owner:
        return "has an invalid assessed version"
    assessed = position.get("assessed_author")
    if not isinstance(assessed, dict) or set(assessed) != set(facets) or not _is(assessed["introduced"], INTRODUCED) \
            or not _is(assessed["severity"], SEVERITY_VALUES) or not _is(assessed["blocking"], BLOCKING):
        return "has an invalid assessed author position"
    return None


def _chronological(rows, order):
    """True when rows are in strictly increasing invocation order (one row per report, never reordered)."""
    places = [order[row["report"]] for row in rows]
    return all(a < b for a, b in zip(places, places[1:]))


def _objection_problem(oid, o, owner, order, answered):
    if not isinstance(o, dict) or not isinstance(o.get("history"), list) or not o["history"] \
            or not isinstance(o.get("responses"), list):
        return "is malformed"
    for row in o["history"] + o["responses"]:
        if not isinstance(row, dict) or owner.get(row.get("report")) != row.get("agent"):
            return "cites a report that is not part of this review"
    if not _chronological(o["history"], order) or not _chronological(o["responses"], order):
        return "has rows out of invocation order or repeated"
    claimant = o["history"][-1]["agent"]
    for r in o["responses"]:
        if r["agent"] == claimant or r.get("answered") != answered[r["report"]]:
            return "has a response that is not the other reviewer's answer to the report it replied to"
    if not oid.startswith(str(claimant).upper() + "-O"):
        return "is not owned by its claimant"
    for c in o["history"]:
        if c["agent"] != claimant or c.get("status") not in ("raised", "maintained", "conceded", "withdrawn") \
                or c.get("topic") not in gencr_report.TOPICS or not isinstance(c.get("finding"), str) \
                or not isinstance(c.get("text"), str):
            return "has a malformed claimant row"
    for r in o["responses"]:
        if r.get("status") not in ("accepted", "rejected") or not isinstance(r.get("text"), str) \
                or (r.get("answered") is not None and r.get("answered") not in owner):
            return "has a malformed response"
    if not _same(o, objection(oid, o["history"], o["responses"])):
        return "does not match its own history and responses (state, resolution or latest response)"
    return None


def validate(adj, invocations, outcome, primary, attacker):
    """Problems of a stored adjudication object (empty list = valid). Types are checked strictly; the roles, the
    latest report and verdict of each reviewer are bound to the package's invocation records; every derived value —
    per-finding live/status/facets/retained, each objection's state, resolution and latest response, counts and
    flags — is recomputed from the stored positions and objection histories. Never raises."""
    try:
        return _validate(adj, invocations, outcome, primary, attacker)
    except Exception as error:  # noqa: BLE001 — a shape this validator did not foresee is never trusted
        return ["the adjudication could not be validated (%s)" % type(error).__name__]


def _validate(adj, invocations, outcome, primary, attacker):
    if not isinstance(adj, dict):
        return ["adjudication is not an object"]
    if not _is(adj.get("version"), (VERSION,)) or adj.get("rule") != "primary-authority":
        return ["unsupported adjudication version or rule"]
    if adj.get("primary") != primary or adj.get("attacker") != attacker or primary == attacker \
            or primary not in AGENTS or attacker not in AGENTS:
        return ["the adjudication's roles are not the package's (primary %s, attacker %s)" % (primary, attacker)]
    if not isinstance(invocations, list) or not all(isinstance(i, dict) for i in invocations):
        return ["the invocation records are malformed"]
    valid = [i for i in invocations if i.get("verdict")]
    owner = {i.get("id"): i.get("agent") for i in valid}
    order = {i.get("id"): place for place, i in enumerate(valid)}  # the adjudication's invocation order
    answered = {i.get("id"): i.get("peer_report") for i in valid}
    problems = []
    for role, agent in (("primary", primary), ("attacker", attacker)):
        mine = [i for i in valid if i.get("agent") == agent]
        report, verdict = (mine[-1].get("id"), mine[-1].get("verdict")) if mine else (None, None)
        if not mine or adj.get(role + "_report") != report or adj.get(role + "_verdict") != verdict \
                or not _is(verdict, VERDICTS):
            problems.append("%s_report/%s_verdict are not %s's latest valid report and verdict" % (role, role, agent))
    if adj.get("primary_verdict") != outcome:
        problems.append("the outcome %r is not the primary reviewer's verdict %r" % (outcome, adj.get("primary_verdict")))
    if not isinstance(adj.get("findings"), dict) or not isinstance(adj.get("objections"), dict) \
            or not isinstance(adj.get("counts"), dict):
        return problems + ["adjudication findings, objections or counts have the wrong type"]
    for oid, o in adj["objections"].items():
        problem = _objection_problem(oid, o, owner, order, answered)
        if problem:
            problems.append("supplemental objection %s %s" % (oid, problem))
    if problems:
        return problems
    other = {primary: attacker, attacker: primary}
    for identifier, f in adj["findings"].items():
        if not isinstance(f, dict) or f.get("id") != identifier or f.get("author") not in AGENTS \
                or not isinstance(f.get("positions"), dict):
            problems.append("adjudication of %s is malformed" % identifier)
            continue
        author, peer = f["author"], other[f["author"]]
        if author not in f["positions"] or not set(f["positions"]) <= {author, peer}:
            problems.append("adjudication of %s has positions of the wrong reviewers" % identifier)
            continue
        bad = [(agent, _position_problem(p, "author" if agent == author else "peer", agent, owner, order))
               for agent, p in f["positions"].items()]
        bad = [(agent, why) for agent, why in bad if why]
        if bad:
            problems.append("the position of %s on %s %s" % (bad[0][0], identifier, bad[0][1]))
            continue
        mine, theirs = f["positions"][author], f["positions"].get(peer)
        if mine["existence"] == "asserted" and theirs is not None and theirs["assessed_version"] == "current" \
                and not _same(theirs["assessed_author"], {name: mine[name] for name in ("introduced", "severity", "blocking")}):
            problems.append("the assessment of %s's current version contradicts its author's current positions" % identifier)
            continue
        active = sorted(oid for oid, o in adj["objections"].items() if o["finding"] == identifier and o["state"] == "active")
        live, status, facets, retained = derive(author, peer, f["positions"], active)
        if not (_same(f.get("objections"), active) and _same(f.get("live"), live) and _same(f.get("status"), status)
                and _same(f.get("facets"), facets) and _same(f.get("retained"), retained)):
            problems.append("adjudication of %s does not match its positions and objections" % identifier)
        withdrawn = f.get("withdrawn")
        if (withdrawn is None) != (f["positions"][author]["existence"] == "asserted") or (
                withdrawn is not None and (not isinstance(withdrawn, dict)
                                           or withdrawn.get("report") != f["positions"][author]["report"])):
            problems.append("the withdrawal of %s does not match its author's position" % identifier)
    if problems:
        return problems
    for key, value in flags(adj).items():
        if not _same(adj.get(key), value):
            problems.append("%s does not match the verdicts, findings and objections" % key)
    return problems


# ── Run-history rules for one new report (validation) and its handoff ─────────

def _state(prior, agent, peer):
    """What `agent` must address in its next report, from the valid prior reports of the run (in order)."""
    parsed = [dict(r, pos=gencr_report.parse_positions(r["text"])) for r in prior]
    own_live = {}  # id -> report of its latest definition by agent
    claims = {}  # id -> latest row of agent (plain or qualified) with the report it was written in
    objections = {}  # oid -> latest claimant row of agent
    for rep in parsed:
        pos = rep["pos"]
        if rep["agent"] == agent:
            for f in pos["findings"]:
                own_live[f["id"]] = rep["id"]
            for w in pos["withdrawn"]:
                own_live.pop(w["id"], None)
            for row in pos["rows"]:
                claims[row["id"]] = dict(row, report=rep["id"])
            for o in pos["objections"]:
                objections[o["id"]] = dict(o, report=rep["id"])
    peer_defs = {}  # id -> latest report of peer defining it
    for rep in parsed:
        if rep["agent"] == peer:
            for f in rep["pos"]["findings"]:
                peer_defs[f["id"]] = rep["id"]
    return parsed, own_live, claims, objections, peer_defs


def handoff(prior, agent, peer, peer_report):
    """Lists for the handoff of `agent` answering `peer_report`: own live findings to restate or withdraw, claims to
    keep with a source-qualified row or withdraw, own live supplemental objections, and the peer's to answer."""
    parsed, own_live, claims, objections, peer_defs = _state(prior, agent, peer)
    answered = next((r for r in parsed if r["id"] == peer_report), None)
    current = {f["id"] for f in answered["pos"]["findings"]} if answered else set()
    kept = []
    for identifier, row in sorted(claims.items()):
        if identifier in current or row["status"] not in ("accepted", "disputed"):
            continue
        source = peer_defs.get(identifier)
        if source:
            kept.append({"id": identifier, "source": source, "status": row["status"]})
    mine = [{"id": oid, "finding": o["finding"], "topic": o["topic"]} for oid, o in sorted(objections.items())
            if o["status"] in ("raised", "maintained")]
    theirs = [{"id": o["id"], "finding": o["finding"], "topic": o["topic"]}
              for o in (answered["pos"]["objections"] if answered else []) if o["status"] in ("raised", "maintained")]
    return {"own_live": sorted(own_live), "kept_claims": kept, "own_objections": mine, "peer_objections": theirs}


def check_report(text, agent, peer, peer_report, prior, known):
    """Errors of a new report of `agent` answering `peer_report` (or None), given the run's valid prior reports."""
    pos = gencr_report.parse_positions(text)
    errors = list(pos["errors"])
    parsed, own_live, claims, objections, peer_defs = _state(prior, agent, peer)
    answered = next((r for r in parsed if r["id"] == peer_report), None)
    if peer_report and answered is None:
        return errors + ["cannot check the dispositions: %s is not a valid report of this review" % peer_report]
    current = {f["id"] for f in answered["pos"]["findings"]} if answered else set()
    peer_reports = {r["id"]: r for r in parsed if r["agent"] == peer}
    defined_now = {f["id"] for f in pos["findings"]}
    withdrawn_now = {w["id"] for w in pos["withdrawn"]}
    name = {"claude": "Claude", "codex": "Codex"}.get(peer, "the other reviewer")
    plain = {r["id"] for r in pos["rows"] if r["source"] is None}
    for identifier in sorted(current - plain):
        errors.append("'## Disposition of peer findings' has no row for %s (every finding of %s's report %s needs one: "
                      "'- %s: accepted|disputed; introduced: ...; severity: ...; blocking: ... — <rationale>' or "
                      "'- %s: rejected — <rationale>')" % (identifier, name, peer_report, identifier, identifier))
    for identifier in sorted(plain - current):
        errors.append("disposition row %s does not name a finding of %s's report %s%s" % (
            identifier, name, peer_report or "(there is none yet)",
            "" if peer_report else "; write '- None'"))
    for row in pos["rows"]:
        if row["source"] is None:
            continue
        source = peer_reports.get(row["source"])
        if source is None or row["id"] not in {f["id"] for f in source["pos"]["findings"]}:
            errors.append("disposition row %s (report %s): that report is not an earlier report of %s in this review "
                          "defining %s" % (row["id"], row["source"], name, row["id"]))
        elif row["id"] in current:
            errors.append("disposition row %s: %s is in %s's report %s; assess its current version with a plain row"
                          % (row["id"], row["id"], name, peer_report))
        elif row["status"] == "rejected":
            errors.append("disposition row %s (report %s): a source-qualified row keeps a claim (accepted or disputed) "
                          "or withdraws it" % (row["id"], row["source"]))
        elif row["status"] == "withdrawn" and claims.get(row["id"], {}).get("status") not in ("accepted", "disputed"):
            errors.append("disposition row %s: you hold no claim on %s to withdraw" % (row["id"], row["id"]))
    qualified = {r["id"] for r in pos["rows"] if r["source"]}
    for kept in handoff(prior, agent, peer, peer_report)["kept_claims"]:
        if kept["id"] not in qualified:
            errors.append("you hold a claim on %s (%s), which %s's report %s no longer defines: keep it with '- %s "
                          "(report %s): accepted|disputed; introduced: ...; severity: ...; blocking: ... — <rationale>' or "
                          "withdraw it with '- %s (report %s): withdrawn — <reason>'"
                          % (kept["id"], kept["status"], name, peer_report, kept["id"], kept["source"], kept["id"],
                             kept["source"]))
    for identifier, report_id in sorted(own_live.items()):
        if identifier not in defined_now and identifier not in withdrawn_now:
            errors.append("your finding %s (report %s) is neither in '## Findings' nor under '## Withdrawn findings': "
                          "restate its current version, or withdraw it explicitly with '- %s: withdrawn — <reason>' "
                          "(leaving it out is not a withdrawal)" % (identifier, report_id, identifier))
    # Re-listing an earlier withdrawal is harmless; withdrawing a finding this reviewer never defined is an error.
    defined_ever = {f["id"] for r in parsed if r["agent"] == agent for f in r["pos"]["findings"]}
    for identifier in sorted(withdrawn_now):
        if identifier not in defined_ever:
            errors.append("withdrawn finding %s is not one of your findings in this review" % identifier)
    prefix = agent.upper() + "-O"
    for o in pos["objections"]:
        previous = objections.get(o["id"])
        if not o["id"].startswith(prefix):
            errors.append("supplemental objection %s: your objections use your own prefix %s<n>" % (o["id"], prefix))
        elif previous is None and o["status"] != "raised":
            errors.append("supplemental objection %s is new: its status is raised" % o["id"])
        elif previous is not None and o["status"] == "raised":
            errors.append("supplemental objection %s was raised before: write maintained, conceded or withdrawn"
                          % o["id"])
        elif previous is not None and previous["status"] in ("conceded", "withdrawn"):
            errors.append("supplemental objection %s was already %s; raise a new one with a new ID" % (
                o["id"], previous["status"]))
        if o["finding"] not in known:
            errors.append("supplemental objection %s names %s, which is not a finding of this review"
                          % (o["id"], o["finding"]))
    stated = {o["id"] for o in pos["objections"]}
    for oid, o in sorted(objections.items()):
        if o["status"] in ("raised", "maintained") and oid not in stated:
            errors.append("your supplemental objection %s (report %s) must be restated as maintained, conceded or "
                          "withdrawn (leaving it out is not a withdrawal)" % (oid, o["report"]))
    open_peer = {o["id"] for o in (answered["pos"]["objections"] if answered else []) if o["status"] in ("raised", "maintained")}
    answered_ids = [r["id"] for r in pos["responses"]]
    for oid in sorted(open_peer - set(answered_ids)):
        errors.append("'## Supplemental objections' has no response to %s's objection %s: write '- %s: accepted|"
                      "rejected — <rationale>'" % (name, oid, oid))
    for oid in sorted(set(answered_ids) - open_peer):
        errors.append("response %s does not answer an open supplemental objection of %s's report %s"
                      % (oid, name, peer_report))
    return errors
