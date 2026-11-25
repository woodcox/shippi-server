# AGENTS.md

Instructions for AI coding agents making changes to this repo. It is a
pure-Bash server provisioning project (dotfiles + installers + hardening) for
Raspberry Pi and similar hosts. There is no build system and no framework —
just Bash.

## Project map

- `bin/` — user-facing commands: `shippi-setup`, `shippi-harden`,
  `shippi-refresh`, `shippi-ssh`, `shippi-help`.
- `install.sh` — installer entry point; sources the modules in `install/`:
  `debian.sh`, `docker.sh`, `binary.sh`, `config.sh`, `runtime.sh`,
  `ai-tools.sh`.
- `config/` — dotfiles copied into `$HOME` (shell, git, mise, opencode,
  lazygit, btop, starship, …).
- `test/` — self-contained test runners, no framework.
- `docs/research/` — dated research notes.
- `assets/` — logos and icons.

## Bash style

- Shell scripts in this project target Bash 5. Use Bash 5 syntax where it
  keeps the code simpler and clearer.
- Every script starts with `#!/usr/bin/env bash` and `set -euo pipefail`.
  Test suites use `set -uo pipefail` (they manage failures themselves).
- 2-space indent. No tabs.
- `snake_case` for functions and variables; `SCREAMING_SNAKE` for constants
  and exports.
- Quote every variable and command expansion, including `"$var"` in tests.
- Prefer early `return 1` / `|| return 1` guards so callers decide how
  failures propagate; never let an error silently produce empty output.
- Keep helper functions small and file-local; prefix internal helpers with
  `_`.

## Comments

- Explain **why**, not what. If a line looks wrong without the context
  (a weird guard, an ordering constraint, a workaround), write the comment
  that makes it look right. Match the density of the existing code.

## Error handling and safety

- Every installer and modifier must be **idempotent**: running it twice must
  be safe. Prefer "check, then act" or marker files (see `MARKER` in
  `bin/shippi-setup`).
- Never clobber user data. If the repo owns a file the user may also own
  (e.g. git identity), rescue/seed it before overwriting — see
  `ensure_git_config` in `install.sh`.
- For `bin/shippi-harden`: the worst failure mode is a Pi the user cannot
  ssh into. Any change that touches ssh, accounts, firewall, or service
  policy must be judged against lockout risk, and the suite in
  `test/shippi-harden-test.sh` exists largely to enforce that.
- Fail loudly: errors go to stderr, non-zero exits are meaningful, and a
  partial state is better than a silently wrong state.

## Interactivity

- Use `gum` for prompts (`gum confirm`, `gum choose`), matching existing
  scripts.
- Every interactive flow must degrade gracefully when no TTY is available:
  skip the optional step or take a safe default instead of hanging.
- Remember `gum choose` reads from `/dev/tty`; test harnesses fake this with
  a pseudo-tty (`script`).

## Testing

- Before claiming any work is done, run the relevant suite and report the
  results:
  - `./test/shippi-harden-test.sh` — for anything touching
    `bin/shippi-harden`.
  - `./test/ai-tools-test.sh` — for anything touching
    `install/ai-tools.sh`.
- Test files are self-contained Bash runners: they `source` the script under
  test, count `PASS`/`FAIL`, and clean up with an `EXIT` trap. Follow that
  pattern; do not introduce a test framework.
- New `shippi-harden` behavior ships with new tests. No exceptions.
- Run `bash -n <script>` on every script you touch. Run `shellcheck` too if
  it is installed; fix findings it reports, but do not add a shellcheck
  setup.

## Git conventions

- Commits follow Conventional Commits: `feat:`, `fix:`, `chore:`,
  `docs:`, `refactor:`, `test:`, `ci:`. Imperative mood, subject ≤ 72 chars,
  no trailing period.
- Branch names mirror the commit type:
  `<type>/kebab-case-description`, e.g. `fix/sudo-tty-prompt`,
  `feat/security-hardening`.

## Dotfiles (`config/`)

- Non-Bash configs (TOML, YAML, JSONC) follow each file's existing
  formatting — indentation, quoting, ordering. Match the file you are
  editing; do not reformat or introduce tooling. The Bash rules above do not
  apply to these files.

## Skills subsystem

- `install/ai-tools.sh` installs AI agent skills across multiple agent
  targets, with lock files and collision handling.
- Core invariant: **a foreign skill entry must never be deleted or
  overwritten silently.** Collision handling applies to every agent target.
  If you touch this file, the tests in `test/ai-tools-test.sh` encode the
  cases a single bad run once cost a bundled skill category.

## Docs

- Research findings go in `docs/research/YYYY-MM-DD-<topic>.md`.
- User-facing help lives in the scripts themselves (`shippi-help`), not in
  separate docs.
