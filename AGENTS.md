# Agent Guidelines

These guidelines apply to all AI coding agents working in this repository (e.g. Bob, Claude).

## Branching Policy

### Always Create a Branch Before Committing

**IMPORTANT**: Never commit directly to `main`. Always create a dedicated branch for each change, commit there, and push the branch.

```sh
# Correct - create a branch first
git checkout -b feat/my-change
git commit -s -m "feat: add my change"
git push origin feat/my-change

# Wrong - committing directly on main
git checkout main
git commit -s -m "feat: add my change"
```

Branch naming should follow the conventional commit prefix of the work:
- `feat/<short-description>` for new features
- `fix/<short-description>` for bug fixes
- `docs/<short-description>` for documentation changes
- `refactor/<short-description>` for refactoring
- `chore/<short-description>` for maintenance tasks

## Pre-Commit Documentation Review

Before every commit, review the documentation to ensure it is up to date with your changes:

- **README.md** — update if you changed usage, configuration, flags, scripts, or deployment steps
- **AGENTS.md** — update if you changed agent guidelines, branching policy, or commit conventions

If the docs don't need changes, no action is required — but you must consciously check before committing.

## Git Commit Guidelines

### Always Use `-s` Flag for Commits

**IMPORTANT**: Always use `git commit -s` when committing changes. Do NOT manually add `Signed-off-by:` lines to commit messages.

```sh
# Correct - use -s flag
git commit -s -m "fix: resolve issue with deployment"

# Wrong - do not manually add Signed-off-by
git commit -m "fix: resolve issue

Signed-off-by: Your Name <you@example.com>"
```

The `-s` flag automatically adds the proper DCO sign-off trailer based on the git configuration.

## Commit Message Format

Use conventional commit format:
- `feat:` for new features
- `fix:` for bug fixes
- `docs:` for documentation changes
- `refactor:` for code refactoring
- `test:` for test changes
- `chore:` for maintenance tasks

Example:
```sh
git commit -s -m "fix(deploy-agent): fail deployment when agent card endpoint is not accessible

- Enable HTTP route creation for all deployment types
- Make deployment fail with exit 1 when agent card returns 404
- Fix MCP_URL to use full Kubernetes service DNS"