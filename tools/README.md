# Release preflight

Run these commands from the repository root:

```text
python tools/release_preflight.py --target local
python tools/release_preflight.py --target staging
python tools/release_preflight.py --target production
python tools/release_preflight.py --target staging --json
```

The command is read-only. `local` checks the repository and static gates;
`staging` adds safe observational ledger, health, source, security and payment
checks; `production` is observational only and never deploys, relinks, repairs
or applies migrations, writes the database, changes Git, creates appointments,
or calls Billplz. Remote evidence that is not safely configured is reported as
`NOT_RUN` or `UNKNOWN`, never as `PASS`.

Non-secret configuration lives in
`tools/release_preflight_config.json`. It contains the frozen reference HEAD,
environment identities, explicit worktree exclusions, migration conventions,
manifest-driven Edge static checks, classified optional Staging integrations,
and known release blockers. Add a new compatible Edge static check or other
registered check there; add a small checker only when its evidence or safety
model is materially different.

The optional `--extended` mode considers the registered Staging integration
checks only after their explicit opt-in markers are present. It is never
available for Production. Use `--json` for machine-readable results. See
`PROJECT_GUIDE/RELEASE_PREFLIGHT.md` for the complete safety boundary,
prerequisites, output statuses, exit codes and future-check guidance.
