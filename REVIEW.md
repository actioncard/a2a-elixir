# Review Exclusions

Files and paths that automated reviewers should skip.

## Skip these files

- `mix.lock` — dependency lock file, not human-authored
- `priv/plts/` — Dialyzer PLT cache (generated)
- `.formatter.exs` — formatter config, rarely meaningful to review
- `.github/workflows/` — CI configs, reviewed manually
- `examples/` — demo/example code, not part of the library
- `test/tck/` — TCK harness scaffolding, reviewed manually

## Skip these patterns

- Documentation-only changes (`*.md` files, `@moduledoc`/`@doc` edits)
- Dependency version bumps with no code changes
- Test fixture data files
