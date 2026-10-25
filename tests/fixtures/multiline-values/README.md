Sanitized replay of a real review failure (gencr -v=2 --fresh --codex=attack, 2026-10-25, run 103602).
The structure of the original initial report is kept — six findings with the same severities and merge blocker, the
same value layouts, and the same "## Review notes" layout — with synthetic text.

- 01-claude-initial.md  As returned: CLAUDE-1's "- Fix:" has nothing on its line and three actions indented below it,
                        Problem and Evidence carry text on the line plus nested bullets, and five of the six
                        "## Review notes" entries are a label followed by indented bullets. gencr rejected the report
                        (Fix "empty"; notes "must start on the label line"); under the block-value grammar it is valid
                        as written.
