# Agent Guidelines for Bob

## Git Commit Guidelines

### Always Use `-s` Flag for Commits

**IMPORTANT**: Always use `git commit -s` when committing changes. Do NOT manually add `Signed-off-by:` lines to commit messages.

```sh
# Correct - use -s flag
git commit -s -m "fix: resolve issue with deployment"

# Wrong - do not manually add Signed-off-by
git commit -m "fix: resolve issue

Signed-off-by: Bob <bob@example.com>"
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