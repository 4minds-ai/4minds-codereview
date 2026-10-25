Sanitized replay of a real reconciliation failure (gencr -v=2 --fresh --codex=attack, 2026-10-24).
The structure, reviewer ownership, finding IDs, severities, peer dispositions, merge blockers and sequence
are those of the original reports; the findings and evidence are synthetic.

- 01-claude-initial.md   Claude's initial report: CLAUDE-1..7.
- 02-codex-attack.md     Codex's attack: CODEX-1..5; accepts CLAUDE-1..5 and 7, rejects CLAUDE-6.
- 03-claude-reconcile.md Claude's reconciliation as it was returned: it accepts CODEX-1, 3, 4 and 5 under
                         "## Disposition of peer findings" but also restates them as finding blocks in its own
                         "## Findings" (the first under the original heading), so gencr rejects it.

Schema migration (2026-10-25, "## Review notes" became a required last section and "## Outstanding disputed findings"
rows must each name one finding): the three reports gained "## Review notes"; free text that was not a dispute about
one finding moved there explicitly — 01's "**Summary**" block (its unresolved risk -> Unresolved risks, its
"Confirmed defects" line -> Other observations), 02's multi-ID "awaiting peer evaluation" row -> Other observations, and
03's "Still unverified" list -> Unresolved risks. Findings, IDs, dispositions, merge blockers and the restated CODEX
blocks (the defect these fixtures reproduce) are unchanged.
