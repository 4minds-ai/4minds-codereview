Read-only review completed. Findings below are confirmed by static tracing; runtime behaviour remains unverified.

Risk: High, primarily data integrity and sync completion.

## Findings

- **CODEX-1 First sync can overwrite a concurrently imported file**
  - Severity: 🔴 BLOCKER
  - File: app.py:11
  - Problem: The first sync allocates its id from a stale list and replaces whatever entry now has that id.
  - Evidence: (traced) Imports lock and allocate against live data; the sync does neither.
  - Expected vs actual: Expected: the imported file is kept. Actual: it is replaced.
  - Tests: The first-sync test uses empty data, so it cannot detect this.
  - Fix: Take the dataset lock and allocate from live data.

- **CODEX-2 A failed handoff is reported as a successful sync**
  - Severity: High
  - File: app.py:12
  - Problem: The handoff result is ignored.
  - Evidence: (traced) The callback returns a bool that the caller drops.
  - Expected vs actual: Expected: a failed run. Actual: a successful one.
  - Tests: No test covers a failed handoff.
  - Fix: Fail the run when the handoff fails.

- **CODEX-3 Malformed responses can replace data with an empty snapshot**
  - Severity: High
  - File: app.py:13
  - Problem: A missing list becomes an empty, final page.
  - Evidence: (traced) `{}` parses to an empty final page, which is committed.
  - Expected vs actual: Expected: the run fails and keeps the old data. Actual: the data is emptied.
  - Tests: No test sends a malformed response.
  - Fix: Validate the response shape and raise otherwise.

- **CODEX-4 The time budget does not bound a response in flight**
  - Severity: Medium
  - File: app.py:14
  - Problem: The deadline is checked only between requests.
  - Evidence: (reasoned, not executed) No absolute timeout wraps a request.
  - Expected vs actual: Expected: an absolute cap. Actual: a per-request check.
  - Tests: The budget test checks only before the first request.
  - Fix: Wrap each request in the remaining budget.

- **CODEX-5 A default configuration creates a sync that can never run**
  - Severity: High
  - File: app.py:15
  - Problem: Import accepts an empty configuration that scheduled runs reject.
  - Evidence: (traced) The import stores the raw configuration; the scheduler validates it strictly.
  - Expected vs actual: Expected: a runnable configuration or a rejected request. Actual: a sync that always fails.
  - Tests: The two validations are tested separately.
  - Fix: Validate the configuration before it is stored.

## Disposition of peer findings

- CLAUDE-1: accepted — No test references the form; this blocks under the test rule.

- CLAUDE-2: accepted — The panel map has no entry for the source.

- CLAUDE-3: accepted — The seed matches only the base filename.

- CLAUDE-4: accepted — The bounded download falls back to the unbounded default.

- CLAUDE-5: accepted — The client reads `error`; the reason is in `message`.

- CLAUDE-6: rejected — The active import path gives a repeat import a distinct name, so no file is shared.

- CLAUDE-7: accepted — Both docstrings contradict the code.

## Merge blockers

- CLAUDE-1 — Missing tests under the test rule.
- CLAUDE-2 — The source card opens an empty panel.
- CODEX-1 — Stale allocation can replace an unrelated file.
- CODEX-2 — A failed handoff is recorded as a success.
- CODEX-3 — Malformed responses can empty the data.
- CODEX-5 — The default configuration produces an unusable sync.

## Outstanding disputed findings

- CLAUDE-6 — Rejected on the active import path; the peer has not yet evaluated that evidence.

## Review notes
- Verified clean: None
- Unresolved risks: None
- Disproven claims: None
- Test gaps: None
- Out-of-scope ownership changes: None
- Other observations: CODEX-1 to CODEX-5 are newly identified findings awaiting peer evaluation; agreement is not assumed.

VERDICT: REQUEST CHANGES
PEER-AGREEMENT: NO
PEER-REPORT: 01-round0-claude-initial
