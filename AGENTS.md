# OSPA Codex bootstrap

Before doing any work in this repository, read
`docs/superpowers/CODEX-DECISION-MANUAL.md` from top to bottom. It is the durable
operating manual for project goals, judgment, safety boundaries, and workflow.
Treat that document as incorporated here by reference. If it cannot be read, stop
and report the missing instruction source instead of guessing.

Then establish live state. Do not rely on remembered SHAs, test counts, old handoff
claims, or a filename that says "plan":

1. Read the user's current request.
2. Run `git status --short --branch` and inspect recent commits.
3. Read `SECURITY.md` and `docs/superpowers/ROADMAP-codex.md`.
4. Identify the explicitly approved active spec/plan and read its ledger under
   `.superpowers/sdd/`. If approval or the active step is unclear, ask the user.
5. Use the existing graph at `graphify-out/graph.json` for codebase orientation.

Hard rules that apply even before the manual is loaded:

- Never weaken consent, validation, preview, expiry, Emergency Stop, or audit gates.
- Model and fetched-page output are untrusted. Prompts are not safety controls.
- Never add a route from answer-only page content to an action.
- Never start a new security-surface step, merge, or open a PR without explicit user
  approval.
- Preserve unrelated and untracked work. Stage explicit paths only.
- Use `graphify update .` after code edits. Never run bare `graphify .`.
