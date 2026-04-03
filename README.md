# Claude Config

Personal Claude Code configuration, commands, and tools — managed as a dotfiles-style repo.

## Setup

Clone and run the setup script to symlink everything into place:

```bash
git clone <repo> ~/src/codereview
cd ~/src/codereview
bash setup.sh
```

Then add this line to `~/.zshrc` to load the shell functions:

```zsh
source ~/src/codereview/dotfiles/zsh/codereview.zsh
```

Reload your shell:

```bash
source ~/.zshrc
```

## Structure

```
~/src/codereview/
├── setup.sh                              # Symlinks claude dotfiles into ~/.claude/
├── bin/
│   └── gencr                             # Legacy script (kept for compatibility)
└── dotfiles/
    ├── claude/
    │   ├── CODE_REVIEW.md                # Code review checklist (the source of truth)
    │   ├── code_review_query.md          # Supporting prompt for code reviews
    │   └── commands/
    │       └── code-review.md            # /project:code-review <devname>
    └── zsh/
        └── codereview.zsh                # Shell functions (source from ~/.zshrc)
```

## Commands

### `/project:code-review <devname>`

Performs a structured code review for a developer against the current git branch.

- Reads the checklist from `~/.claude/CODE_REVIEW.md`
- Auto-detects the current branch
- Checks for a prior review and diffs against it if found
- Saves the report to `~/Documents/CodeReview/<devname>/code-review-<devname>-<branch>-<timestamp>.md`

**Usage inside Claude Code:**
```
/project:code-review swalker
```

**Usage from terminal:**
```bash
gencrnew swalker
```

## Shell Functions

Defined in `dotfiles/zsh/codereview.zsh`, loaded via `~/.zshrc` (see Setup above).
