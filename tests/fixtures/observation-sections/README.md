Sanitized replay of a real review failure (gencr -v=2 --fresh --codex=attack, 2026-10-24, run 222901).
Structure, IDs, severities, merge blockers and the placement are those of the original initial report; all findings
and observations are synthetic.

- 01-claude-initial-misplaced.md  As returned: after the last finding's Fix, still inside "## Findings", the report
                                   lists "Things I checked and found clean:" and "Unresolved risks (not findings):" —
                                   observations the review instructions ask for but the report format had no section
                                   for. gencr rejects it (it is never repaired or moved).
- 01-claude-initial-corrected.md  The same report with those observations under "## Review notes".
