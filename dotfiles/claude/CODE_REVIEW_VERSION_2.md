> PRs should be blocked if critical sections (Testing, Security, Migrations) are not satisfied.

# Code Review Checklist

Use this checklist when reviewing a branch/PR to ensure the code is solid, safe, and production-ready.

---

## Risk Assessment

- [ ] Risk Level: Low / Medium / High
- [ ] Primary Risk Area: (async, state, API, DB, UI, infra)
- [ ] Rollback Complexity: Low / Medium / High

---

## Correctness & Logic

- [ ] The code does what it's supposed to do
- [ ] Edge cases are handled (nulls, empty inputs, boundary values)
- [ ] No off-by-one errors, race conditions, or incorrect assumptions
- [ ] Error paths behave correctly — exceptions are caught, logged, and handled gracefully

## Duplication & Reuse

- [ ] No copy-pasted logic that should be extracted into a shared function or utility
- [ ] No reimplementation of functionality that already exists elsewhere in the codebase
- [ ] Constants and magic numbers are extracted and named meaningfully

## Design & Architecture

- [ ] Code follows existing patterns and conventions in the project
- [ ] Responsibility is clearly separated — no function/class is doing too much
- [ ] Dependencies are reasonable and don't create unnecessary tight coupling
- [ ] Implementation is as simple as possible without sacrificing clarity

## Naming & Readability

- [ ] Variable, function, and class names are descriptive and consistent with the codebase
- [ ] Code is self-documenting; confusing sections have comments where needed
- [ ] Control flow is easy to follow — avoid deeply nested conditionals

## Testing (Required)

- [ ] Unit tests are included for all new/modified logic (required unless justified)
- [ ] Tests cover happy paths, edge cases, and failure scenarios
- [ ] Tests assert meaningful behavior (not just execution)
- [ ] Tests are deterministic (no flaky timing / network dependence)
- [ ] Existing tests pass
- [ ] Test coverage does not decrease (or justification provided)

## Data Integrity & State

- [ ] State updates are consistent and do not introduce race conditions
- [ ] No stale state issues (especially async / streaming flows)
- [ ] Backend and frontend contracts remain in sync
- [ ] Idempotency is considered where applicable (safe retries, no data corruption)

## Concurrency & Async

- [ ] Async logic is safe (no race conditions, double execution, or lost updates)
- [ ] Proper cleanup/cancellation is implemented (e.g., abort controllers, unmount handling)
- [ ] No memory leaks (event listeners, intervals, streams)

## Performance & Scalability

- [ ] No unnecessary loops, redundant API/DB calls, or N+1 query issues
- [ ] Large datasets are handled safely (pagination, limits, streaming where appropriate)
- [ ] Expensive operations are cached or batched where appropriate

## Security

- [ ] User input is validated and sanitized (no SQL/XSS/command injection risks)
- [ ] Secrets, tokens, and credentials are not exposed in code
- [ ] Authorization checks are enforced correctly

## API & Contract

- [ ] Public interfaces (APIs, function signatures) are clean and consistent
- [ ] Request/response schemas are validated (e.g., Pydantic, Zod)
- [ ] Breaking changes are flagged, versioned, or documented
- [ ] Status codes and error responses follow existing conventions

## Database & Migrations (if applicable)

- [ ] Migrations are safe, tested, and reversible where possible
- [ ] Migrations are idempotent where possible (safe to re-run or fail gracefully)
- [ ] Existence checks are used (tables, columns, indexes, constraints)
- [ ] No destructive changes without explicit approval
- [ ] Queries are efficient and properly indexed
- [ ] Migration tested against a production-like dataset/environment

### Column Additions (Production Safety)

- Do NOT add columns with `nullable=False` + `server_default` in a single migration on live tables.
- This can require an ACCESS EXCLUSIVE lock and block production traffic.
- Assume tables may reach millions of rows. Migrations must be safe under high write traffic and long-lived transactions.
- No data backfills in Alembic migrations. Treat `NULL` as the default in application/query logic (e.g., `COALESCE`) and enforce correctness at the application layer.

**Required pattern (NO BACKFILL):**
1. Add column as nullable (no default)
2. Do NOT backfill in migration (ever)
3. Application and query layer must treat `NULL` as the intended default (e.g., false, "general", etc.)
4. If strict NOT NULL is required, it must be enforced at the application layer (validators/guards) — not via a backfill in Alembic.

**Example:**
```python
op.add_column('table', sa.Column('col', sa.Boolean(), nullable=True))
```

### High-risk rules (read every time)

- [ ] **No DROP COLUMN on high-traffic tables** — DROP COLUMN requires ACCESS EXCLUSIVE lock, blocking all reads/writes. If the column is unused, leave it in place and let the ORM ignore it. Only drop columns during planned maintenance windows with pods shut down.
- [ ] **ADD COLUMN reviewed for table normalization** — Before adding a column to an existing table (especially `user`), ask: does this data have its own lifecycle or domain? If yes, create a separate table with a `user_id` FK instead. Examples of data that belongs in its own table:
  - Trials / expiration dates → `user_trials`
  - Billing / subscription fields → `user_subscriptions`
  - Consent flags → `user_preferences`
  - Telemetry / tracking fields → `user_telemetry`
  - Onboarding metadata → `user_onboarding`

  A table with dozens of loosely-related columns is hard to read, slow to migrate, and locks on every schema change. Keep tables focused on a single domain.
- [ ] **Migration lock impact is understood** — Know what lock level the operation takes (ACCESS EXCLUSIVE, SHARE UPDATE EXCLUSIVE, etc.) and whether it's acceptable for production traffic. Even `ADD COLUMN` with a non-null default can lock the table on older PostgreSQL versions.
- [ ] **Data migrations (backfills) are batched and safe** — Backfills must not run inside long-running transactions or the request path. Use batched updates with LIMIT/OFFSET or cursor-based iteration. Never backfill millions of rows in a single transaction.
- [ ] **Migration is safe across multiple deployments** — No dependency on exact prior state or missing revisions. Must work when staging and production are at different alembic versions. Test that `alembic upgrade head` succeeds from any known production revision.
- [ ] **Revision hygiene is verified** — No deleted or renamed migration files after merge. `down_revision` chain is intact and linear/intentional (merge revisions are explained). Run `alembic heads` to confirm a single head.

## Observability & Operability

- [ ] Logging is sufficient for debugging production issues
- [ ] Logs are structured and include useful identifiers (requestId, userId, etc.)
- [ ] No sensitive data is logged
- [ ] Metrics/monitoring are added for critical paths
- [ ] Change can be rolled back safely

## Frontend Behavior (if applicable)

- [ ] UI reflects state changes correctly
- [ ] Loading, empty, and error states are handled
- [ ] No unnecessary re-renders (memoization where needed)
- [ ] Basic accessibility is considered (keyboard, aria)

## Rollout Safety

- [ ] Feature flags are used where appropriate
- [ ] No hard dependency on simultaneous deployment of other services
- [ ] Blast radius is understood and documented if high risk

## Housekeeping

- [ ] No dead code, commented-out blocks, or leftover TODOs
- [ ] No unused imports, dependencies, or files
- [ ] PR has a clear description explaining *why* the change was made

## Reviewer Sanity Check

- [ ] I can explain what this PR does in 1–2 sentences
- [ ] I would feel comfortable owning this code in production

---

> Not every item applies to every PR. Use judgment — but do not skip critical sections (testing, security, migrations).


---

# Adversarial Review Protocol (Required for High-Risk Changes)

**Mission:** Attempt to falsify the developer's claims. A review is not complete because the code looks reasonable or the tests pass. Find concrete ways the change can produce wrong outcomes, silently fail, corrupt state, violate boundaries, or pass tests despite broken production logic.

## Scope and baseline
- Identify the exact merge base, changed files, affected callers/consumers, and intended behavior. Distinguish newly introduced defects from pre-existing defects.
- Trace relevant code outside the diff (callers, worker handlers, persistence, configuration, downstream consumers), without making unrelated modifications.
- Check ownership boundaries and unexpected changes to other teams' services; report these separately and require owner review.
- Determine which migration system the actual service owns. Do not assume Alembic applies to all repositories; for Go/data-service use the applicable goose migrations. Preserve production-safe schema-change requirements.

## Attack plan
- Write down critical invariants: what must never happen (duplicate jobs, missing authorization, data loss, false success, skipped work), and what must always happen.
- Construct negative scenarios for every new conditional, fallback, timeout, retry, state transition, query predicate, and early return.
- Follow each scenario end-to-end: trigger -> handler -> transaction/commit -> queue/event -> consumer -> persisted result -> user-visible result.
- Challenge stale reads, commit/read gaps, simultaneous workers, reordered messages, crashes before/after commit, replayed events, partial writes, and repeated deployment/restart.
- Check that the operation fails visibly when work does not start or complete. Logs or successful HTTP responses are not proof of completion.
- Challenge authz and tenant isolation at each entry point, including direct invocation and background execution. Never log secrets or reuse user credentials as service credentials.
- Examine load amplification, large datasets, missing indexes, unbounded retries, resource exhaustion, and high-frequency polling.

## Tests must be able to fail
- For each important new guard or predicate, ask: **If I delete, invert, or bypass this line, which test fails?** If none, identify a missing regression test.
- Verify mocks respect the actual query filters, ordering, limits, transaction state, and commit boundaries; a mock that returns the supplied object regardless of query is not proof.
- Test the observable end state, not only that a handler was invoked, a log was emitted, or a message was queued.
- Verify timeout and fallback tests distinguish the intended path from other paths that produce the same final value.
- Use safe local mutation or fault injection when feasible; restore modifications after each probe. Never mutate production or staging to prove a point.
- A newly added test must fail against the defective version and pass against the corrected version whenever reproducible.

## Two-sided adversarial review
- **Attacker:** Produce the strongest concrete counterexample and a minimal reproducer or failing test.
- **Defender:** Attempt to disprove it by tracing the real execution path and running the test. Identify invalid assumptions and false positives.
- **Attacker again:** Recheck the fix for regressions, missing alternate paths, and tests that cannot fail.
- Repeat only for material unresolved issues; do not manufacture findings to prolong review.

## Finding quality and evidence
Each finding must include:
1. **ID, severity, confidence, and status** (confirmed / likely / hypothesis / disproven / fixed / unverified).
2. **Code evidence**: file and line(s), entry point, and the precise faulty condition.
3. **Reproduction**: inputs, timeline/interleaving, local command or test, and actual vs expected result. If not executed, say so.
4. **Impact**: user-visible outcome, data-integrity/security implications, and realistic blast radius.
5. **Test effectiveness**: what current tests miss, and a regression test that would fail on the defect.
6. **Minimal corrective direction** and whether the fix was verified; do not silently change code during a review-only assignment.

## Severity and exit criteria
- **Blocker:** demonstrated security boundary violation, data corruption/loss, destructive migration, or critical production outage risk.
- **High:** demonstrated core functional failure, duplicate side effects, silent failure, or unsafe race on a meaningful path.
- **Medium:** credible noncritical defect with a clear trigger; **Low:** maintainability or minor edge case; **Informational:** improvement with no demonstrated defect.
- Do not mark a finding fixed because a commit exists. Re-run the failing test and inspect all relevant execution paths.
- Do not claim tests passed unless executed. Report commands, results, environment, and limitations.
- Finish with: confirmed defects; unresolved risks; disproven claims; test gaps; out-of-scope ownership changes; and explicit merge recommendation with blockers.
- A clean result means **no defects demonstrated under the tested scenarios**, not proof that the code is bug-free.
