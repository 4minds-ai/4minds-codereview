## Round 1 reconciliation: Claude (primary) evaluates Codex report 02-round0-codex-attack

I accept five of Codex's six positions and withdraw CLAUDE-6. One point is still disputed: whether CODEX-2 should block this change. That doesn't change the outcome, because both of us still request changes.

**What I checked in this round**
- **CODEX-1:** the import lock and the sync's allocation.
- **CODEX-2:** every caller of the handoff callback.
- **CODEX-5:** the import endpoint and the scheduled-run validation.
- **CODEX-3 and CODEX-4:** checked against the client in the diff.

## Findings

- **CLAUDE-1 New settings form has no tests**
  - Severity: 🔴 BLOCKER
  - File: app.py:1
  - Problem: The new settings form ships without tests.
  - Evidence: No test module references the form. Codex confirmed this independently and accepted it.
  - Expected vs actual: Expected: tests for every change. Actual: none.
  - Tests: None. Deleting the form's validation would not fail any test.
  - Fix: Add tests covering:
    - validation
    - the save path

- **CLAUDE-2 The source card opens an empty panel**
  - Severity: High
  - File: app.py:2
  - Problem: The source is listed, but its configuration panel has no entry.
  - Evidence: (traced, not executed) The panel map has no key for the source. Codex accepted this.
  - Expected vs actual: Expected: a configuration panel. Actual: an empty panel.
  - Tests: No test checks that every listed source has a panel.
  - Fix: Register the panel, or hide the card until it exists.

- **CLAUDE-3 Re-creating the sync keeps a second snapshot**
  - Severity: Medium
  - File: app.py:3
  - Problem: Seeding matches only the base filename, so a rotated snapshot is kept forever.
  - Evidence: (traced, not executed) The rotated name is seeded as an upload and skipped by cleanup. Codex accepted this.
  - Expected vs actual: Expected: one current snapshot. Actual: two.
  - Tests: The seed test uses only the base filename.
  - Fix: Match the snapshot by a stable marker and add a rotated-name test.

- **CLAUDE-4 Import holds the whole snapshot in memory**
  - Severity: Medium
  - File: app.py:4
  - Problem: The byte budget is checked only after the full download.
  - Evidence: (traced) The bounded download falls back to the unbounded default. Codex accepted this.
  - Expected vs actual: Expected: stop at the budget. Actual: the budget is checked afterwards.
  - Tests: No test passes a byte budget.
  - Fix: Enforce the budget while downloading.

- **CLAUDE-5 Failure reasons never reach the user**
  - Severity: Low
  - File: app.py:5
  - Problem: The client reads the wrong response field for errors.
  - Evidence: The reason is in `message`; the client reads `error`. Codex accepted this.
  - Expected vs actual: Expected: an actionable reason. Actual: a generic failure.
  - Tests: The failure test never asserts the reason.
  - Fix: Map `message` to `error` and assert it.

- **CLAUDE-7 Docstrings contradict the code**
  - Severity: Low
  - File: app.py:7
  - Problem: - Two docstrings describe behaviour the code does not have.
    - The header has no logo.
  - Evidence: Read of the cited lines. Codex accepted this.
  - Expected vs actual: Expected: accurate docs. Actual: contradictory docs.
  - Tests: Not applicable.
  - Fix: Correct both docstrings.

- **CODEX-1 First sync can replace a file a concurrent import just added (accepted; tracked under Codex's ID)**
  - Severity: High
  - File: app.py:11
  - Problem: Without a prior manifest, the id is allocated from a stale list and the entry with that id is replaced.
  - Evidence: (traced) Imports serialize on a dataset lock and allocate against live data; the sync takes only its own lock.
  - Expected vs actual: Expected: the imported file is kept. Actual: its entry is overwritten.
  - Tests: The first-sync test uses empty data, so it can't detect this.
  - Fix: Take the dataset lock, then allocate from live data.

- **CODEX-3 Malformed response bodies become an authoritative empty snapshot (accepted)**
  - Severity: High
  - File: app.py:13
  - Problem: A missing list becomes an empty, final page that is committed.
  - Evidence: (traced) `{}` renders as an empty snapshot, which replaces the old one.
  - Expected vs actual: Expected: a contract violation fails the run. Actual: silent replacement.
  - Tests: There are no tests for a missing list.
  - Fix: Require the list and raise otherwise.

- **CODEX-4 The time budget doesn't bound a response that is still streaming (accepted)**
  - Severity: Medium
  - File: app.py:14
  - Problem: The deadline is checked only before each request.
  - Evidence: (reasoned, not executed) Nothing wraps the request in an absolute timeout.
  - Expected vs actual: Expected: an absolute cap. Actual: a cap between pages only.
  - Tests: The budget test exercises only the first request.
  - Fix: Wrap each request in the remaining budget.

- **CODEX-5 A default configuration imports successfully but leaves a sync that can never run (accepted)**
  - Severity: High
  - File: app.py:15
  - Problem: Import accepts an empty configuration and stores it unchanged.
  - Evidence: (traced) The scheduler validates strictly and rejects it on every run.
  - Expected vs actual: Expected: a runnable configuration. Actual: a sync that always fails.
  - Tests: Nothing tests import followed by a scheduled run.
  - Fix: Canonicalize and validate the configuration before it is stored.

## Disposition of peer findings
- CODEX-1: accepted — Imports allocate against live data under the dataset lock; the sync allocates from a stale list and replaces by id. Codex rated it 🔴 BLOCKER; I rate it High because it needs a concurrent first sync, but I agree it blocks the merge.
- CODEX-2: disputed — The defect is real, but every sync writer drops the handoff result, so it is a platform-wide gap rather than a blocker introduced here.
- CODEX-3: accepted — A missing list becomes an empty final page that replaces the old snapshot. High, merge blocker.
- CODEX-4: accepted — The deadline is checked only before requests. Medium, not blocking.
- CODEX-5: accepted — The import stores the raw configuration and the scheduler rejects it. High, merge blocker.
- CLAUDE-6 (Codex rejected it): I accept the rejection and withdraw the finding. The active import path gives a repeat import a distinct name.

## Merge blockers
- CLAUDE-1
- CLAUDE-2
- CODEX-1
- CODEX-3
- CODEX-5

## Outstanding disputed findings
- CODEX-2: we agree the defect exists; we disagree on whether it blocks this change. It doesn't change the verdict.
- CODEX-1 severity: Codex says 🔴 BLOCKER, I say High. We agree it blocks the merge.

## Review notes
- Verified clean: None
- Unresolved risks: Still unverified (not counted as defects):
  - whether reused file ids purge old chunks
  - the live response contract
- Disproven claims: None
- Test gaps: None
- Out-of-scope ownership changes: None
- Other observations: None

VERDICT: REQUEST CHANGES
PEER-AGREEMENT: YES
PEER-REPORT: 02-round0-codex-attack
