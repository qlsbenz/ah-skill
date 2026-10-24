# git-conventions

Base conventions for all git operations in this repository. Skills in the `git` domain reference this file as `.agents/rules/git-conventions.md`.

## Conventional Commits

Format: `<type>(<scope>)?: <subject>` — in English, lowercase, no trailing period, no longer than 72 characters.

Allowed `type` values:

| type | purpose |
|------|-----------|
| `feat` | new functionality for the user |
| `fix` | bug fix |
| `refactor` | code change with no behavior change |
| `perf` | performance optimization |
| `docs` | documentation only |
| `test` | tests only |
| `build` | build, dependencies, CI |
| `ci` | CI configuration |
| `chore` | maintenance that doesn't fall into other categories |
| `revert` | revert |

`scope` — a short name for the module/SDK/folder (`sdk-go`, `cli`, `auth`). If there's no scope — omit it along with the parentheses.

Commit message body (optional, after a blank line):
- what and why — in Russian or English, depending on the project's context
- breaking change — `BREAKING CHANGE:` in the footer, or `!` after type/scope (`feat!:`, `feat(api)!:`)
- issue references — `Refs: #123` or `Closes: #123` in the footer

Examples:
```
feat(sdk-go): add retries for idempotent requests
fix: fix race condition in startup
refactor(auth): extract token validation into a separate middleware
docs(readme): update installation example
chore(deps): update express to 4.19
```

## AI attribution

Every commit that Codex authors (via `git-conventional-commits` or by running `git commit` directly) carries a trailer in the footer:

```
Co-Authored-By: Codex <noreply@openai.com>
```

- Applies to every commit Codex creates — not to commits the user writes themselves, even in a session where Codex is present.
- Own line in the footer, after `BREAKING CHANGE:`/`Refs:`/`Closes:` if present; same blank line before the footer as any other body.
- Text is model-version-agnostic on purpose — it doesn't need editing when the model behind Codex changes.
- No `Codex-Session:` line or any other session/tool URL, even if the calling harness suggests appending one by default — session links are ephemeral and internal, they don't belong in permanent repo history. `Co-Authored-By:` is the only attribution line.

```
fix(auth): fix race condition in token refresh

Co-Authored-By: Codex <noreply@openai.com>
```

## Branch names

- `feature/<short-desc>` — new functionality
- `fix/<short-desc>` or `bugfix/<short-desc>` — bug fix
- `hotfix/<short-desc>` — urgent production fix
- `chore/<short-desc>` — technical/maintenance
- `docs/<short-desc>` — documentation only
- `release/<version>` — release branch (if using a release train)

Description in kebab-case, Latin script, no longer than 50 characters. If there's a ticket — append it at the end: `feature/oauth-pkce-PROJ-1234`.

## Pull Request

- PR title — a Conventional Commit for the merge commit (`feat(sdk-go): retries for idempotent`)
- description contains:
  - **Why** — motivation in 1-2 sentences
  - **What changed** — bullets by layer/component
  - **How to verify** — manual verification steps or a link to tests
  - **Risks / breaking changes** — separately, if applicable
- linked to the issue (`Closes #N`)
- reviewer — at least one; if the code is complex or breaking — two

## Semver and tags

Versioning strictly follows semver: `MAJOR.MINOR.PATCH`.

- **PATCH** — `fix`, `perf`, `docs`, `refactor` with no public API change
- **MINOR** — `feat` that doesn't break compatibility
- **MAJOR** — any breaking change

Before `v1.0.0`, a breaking change goes into MINOR, not MAJOR.

Tag format — `v<MAJOR>.<MINOR>.<PATCH>` (e.g. `v1.4.2`). In a monorepo with multiple SDKs: `<sdk>/v<X>.<Y>.<Z>` (e.g. `sdk-go/v0.3.1`). This format is required for Go: the tag path must match the module path from the repo root, otherwise `go get` won't find the module in the subdirectory. Other packages follow the same format for consistency.

In a monorepo, each package is versioned independently: a breaking change in one SDK doesn't move the versions of its neighbors. A shared `vX.Y.Z` tag is not set on a monorepo with independent versions — it wouldn't correspond to any single package.

A tag is set only on the merge commit into `main` after CI succeeds.

## Principles

- **Atomic commits.** One commit — one logical change. Don't mix a refactor with a feature.
- **Don't rewrite the history of published branches.** Force-push only to your own feature branch before the PR is opened.
- **Squash on merge** — if the branch contains noisy WIP commits. Otherwise — rebase or merge commit, depending on the project's convention.
- **Never commit secrets.** If it happens by accident — rotate the key; don't rely on rewriting history as the only remedy.
