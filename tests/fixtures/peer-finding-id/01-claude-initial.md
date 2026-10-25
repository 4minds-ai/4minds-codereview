## Code Review: feature (widget sync)

Acknowledged: read-only review. Nothing was executed; every claim below comes from tracing the code.

**Risk assessment**
- Risk level: Medium. It adds a new provider and a scheduled sync writer.
- Rollback complexity: Low. The change is additive.

## Findings

- **CLAUDE-1 New settings form has no tests**
  - Severity: 🔴 BLOCKER
  - File: app.py:1
  - Problem: The new settings form ships without tests.
  - Evidence: No test module references the form.
  - Expected vs actual: Expected: tests for every change. Actual: none.
  - Tests: None. Deleting the form's validation would not fail any test.
  - Fix: Add tests for the form's validation and save paths.

- **CLAUDE-2 The source card opens an empty panel**
  - Severity: High
  - File: app.py:2
  - Problem: The source is listed, but its configuration panel has no entry.
  - Evidence: (traced, not executed) The panel map has no key for the source.
  - Expected vs actual: Expected: a configuration panel. Actual: an empty panel.
  - Tests: No test checks that every listed source has a panel.
  - Fix: Register the panel, or hide the card until it exists.

- **CLAUDE-3 Re-creating the sync keeps a second snapshot**
  - Severity: Medium
  - File: app.py:3
  - Problem: Seeding matches only the base filename, so a rotated snapshot is kept forever.
  - Evidence: (traced, not executed) The rotated name is seeded as an upload and skipped by cleanup.
  - Expected vs actual: Expected: one current snapshot. Actual: two.
  - Tests: The seed test uses only the base filename.
  - Fix: Match the snapshot by a stable marker and add a rotated-name test.

- **CLAUDE-4 Import holds the whole snapshot in memory**
  - Severity: Medium
  - File: app.py:4
  - Problem: The byte budget is checked only after the full download.
  - Evidence: (traced) The bounded download falls back to the unbounded default.
  - Expected vs actual: Expected: stop at the budget. Actual: the budget is checked afterwards.
  - Tests: No test passes a byte budget.
  - Fix: Enforce the budget while downloading.

- **CLAUDE-5 Failure reasons never reach the user**
  - Severity: Low
  - File: app.py:5
  - Problem: The client reads the wrong response field for errors.
  - Evidence: The reason is in `message`; the client reads `error`.
  - Expected vs actual: Expected: an actionable reason. Actual: a generic failure.
  - Tests: The failure test never asserts the reason.
  - Fix: Map `message` to `error` and assert it.

- **CLAUDE-6 Repeat imports can overwrite a shared file**
  - Severity: Low
  - File: app.py:6
  - Problem: A fixed filename lets two entries share one stored file.
  - Evidence: (traced) Both imports write the same name.
  - Expected vs actual: Expected: distinct files. Actual: a shared file.
  - Tests: None.
  - Fix: Give each import a distinct name.

- **CLAUDE-7 Docstrings contradict the code**
  - Severity: Low
  - File: app.py:7
  - Problem: Two docstrings describe behaviour the code does not have.
  - Evidence: Read of the cited lines.
  - Expected vs actual: Expected: accurate docs. Actual: contradictory docs.
  - Tests: Not applicable.
  - Fix: Correct both docstrings.

## Disposition of peer findings
- None

## Merge blockers
- CLAUDE-1
- CLAUDE-2

## Outstanding disputed findings
- None

## Review notes
- Verified clean: None
- Unresolved risks: Whether reused file ids purge old chunks is unverified.
- Disproven claims: None
- Test gaps: None
- Out-of-scope ownership changes: None
- Other observations: Confirmed defects: CLAUDE-2 through CLAUDE-7, by static trace.

VERDICT: REQUEST CHANGES
PEER-AGREEMENT: N/A
PEER-REPORT: N/A
