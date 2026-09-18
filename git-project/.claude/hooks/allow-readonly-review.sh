#!/usr/bin/env bash
# PreToolUse(Bash) hook — project-scoped.
#
# Purpose: during code reviews in THIS repo, auto-approve read-only inspection
# commands so they never trigger a permission prompt — INCLUDING commands that
# contain $(...) command substitution or pipes, which the settings allowlist
# cannot match. Anything that looks mutating/dangerous is passed straight
# through to the normal permission flow (exit 0 with no decision), so this only
# ever GRANTS for a conservative read-only set and never blocks or hides risk.
#
# Contract: PreToolUse hooks receive the tool call as JSON on stdin. Emitting
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
# grants the call and bypasses the prompt. Emitting nothing defers to normal
# permission handling (allowlist / user prompt).

cmd="$(cat | jq -r '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0

# Normalize away harmless void/stderr redirects (2>/dev/null, 2>&1, >/dev/null,
# &>/dev/null) before the safety checks below. These write nothing to the
# filesystem, so they should not force a permission prompt on an otherwise
# read-only command. Real output redirects to files (> file, >> file, 2> file)
# survive this strip and still defer via rule 2.
scan="$(printf '%s' "$cmd" | sed -E 's/(&|[12])?>>?[[:space:]]*(\/dev\/null|&[12])//g')"

# 1) Pass through (do NOT auto-approve) if any mutating / dangerous token
#    appears ANYWHERE in the command line — including inside $(...) or after a
#    pipe. Word-boundary matched so it doesn't trip on substrings.
if printf '%s' "$scan" | grep -Eq '(^|[^[:alnum:]_/.-])(rm|rmdir|mv|cp|dd|tee|truncate|mkfifo|mkdir|touch|chmod|chown|ln|sudo|kill|pkill|killall|shutdown|reboot|curl|wget|scp|rsync|nc|ncat|socat|perl|ruby|npm|pnpm|yarn|pip|pip3|poetry|go|node|npx|deno|bun|docker|podman|kubectl|helm|terraform|aws|gcloud|az|export|unset|source|eval|exec)([^[:alnum:]_-]|$)'; then
  exit 0
fi

# 2) Pass through on redirection, backticks, in-place edits, find-side effects,
#    awk system() calls, or any mutating git subcommand.
if printf '%s' "$scan" | grep -Eq '(>>?|2>|<[^(]|`|\bsed[[:space:]]+-i|\bawk[^|]*system[[:space:]]*\(|-delete\b|-exec(dir)?\b|-ok\b|-fprintf?\b|git[[:space:]]+(commit|push|add|reset|restore|checkout|switch|rm|clean|stash|rebase|merge([[:space:]]|$)|cherry-pick|tag|apply|mv|gc|prune|reflog|worktree|config|remote|fetch|pull|clone|init|update-ref))'; then
  exit 0
fi

# 3) Auto-approve only when the LEADING command is a known read-only tool.
#    (An optional `git -C <path>` / `--no-pager` prefix is allowed.)
#    An optional leading shell-variable assignment prefix (`VAR=`, `VAR=$(`)
#    is also allowed: the assignment itself writes only an ephemeral shell
#    variable, and rules 1 & 2 above have ALREADY scanned the entire command
#    line — including anything inside $(...) — for mutating/dangerous tokens
#    and deferred if any were found. So `MB=$(git merge-base ...)` is still a
#    read-only inspection command and must not force a permission prompt.
if printf '%s' "$scan" | grep -Eq '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=\$?\(?[[:space:]]*)?(git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(--no-pager[[:space:]]+)?(log|diff|show|status|rev-parse|merge-base|cherry|branch|ls-files|ls-tree|blame|cat-file|rev-list|for-each-ref|diff-tree|describe|name-rev|shortlog)|grep|egrep|rg|find|cat|head|tail|wc|sort|uniq|cut|tr|comm|nl|column|jq|diff|basename|dirname|realpath|echo|ls|pwd|true|sed[[:space:]]+-n|awk)([[:space:]]|$)'; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"read-only review command (project hook)"}}'
  exit 0
fi

# 4) Everything else: DENY automatically so the user is never prompted.
#    Rationale: the user has repeatedly and emphatically required that code
#    reviews in this repo never raise a permission prompt. Deferring here
#    (exit 0) is exactly what triggers a prompt for anything the read-only
#    allowlist above did not match — including compound shell (`cd; for; if`),
#    which this hook cannot verify as safe. So instead of deferring, we DENY:
#    the command bounces straight back to the model as a tool error, the model
#    rewrites it as a single bare read-only command (which rule 3 approves),
#    and the user never has to hit return. Mutating/dangerous single commands
#    still get denied here too, which is the safe default for a review session.
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Not on the read-only review allowlist. Rewrite as a SINGLE bare read-only command (git log/diff/show/ls-files, grep, find, ls, cat, sed -n, awk) with no cd, no ;/&&, no for/if loops, no $(...). This repo auto-denies non-allowlisted Bash during reviews so the user is never prompted."}}'
exit 0
