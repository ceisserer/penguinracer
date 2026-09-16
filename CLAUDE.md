# CLAUDE.md — PenguinRacer

The working rules for this codebase live in **[AGENTS.md](./AGENTS.md)** — the layout, the
architecture rules, the traps found the hard way, the deliberate deviations from ETR. Read it
before changing anything. All of it applies to Claude Code; this file only adds what is specific
to Claude Code's own defaults.

## Commit and PR attribution

Commits and pull requests in this repository carry **no agent attribution**:

- Do **not** append a `Co-Authored-By:` trailer naming Claude, any Claude model, or any other
  model or tool.
- Do **not** append a "Generated with …" line, badge, emoji or product link to pull request
  descriptions.

This deliberately overrides Claude Code's default attribution behaviour, which defers to a
project instruction such as this one. The history was rewritten once to strip those trailers out
of 27 commits — do not reintroduce them.

Authorship is recorded the ordinary way, through the `user.name` / `user.email` configured for
this repository. The project's use of LLMs is disclosed once and in prose, in the README under
*How this was built*, which is the honest place for it — a per-commit trailer is not.
