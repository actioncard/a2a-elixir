# A2A Elixir — Project Conventions

## Module Naming

- All modules live under the `A2A.*` namespace
- No `Impl` suffix — use behaviour modules and concrete implementations directly
- Example: `A2A.TaskStore` (behaviour), `A2A.TaskStore.ETS` (implementation)

## Code Style

- 100-character line limit
- `@moduledoc`, `@doc`, and `@spec` required on all public functions
- Use `@moduledoc false` for internal modules (never omit the attribute)
- Pipe chains: prefer pipes for 2+ transformations

## Optional Dependencies

- Guard optional deps with `Code.ensure_loaded?/1` checks
- Example: `if Code.ensure_loaded?(Plug) do ... end`
- Never call optional dep modules unconditionally

## Error Handling

- Use `{:ok, value}` / `{:error, reason}` tuples for all business logic
- No `raise` for expected/recoverable errors
- `raise` only for programmer errors (e.g., invalid arguments that indicate a bug)

## Testing

- Test file structure mirrors `lib/` structure
- All test modules use `async: true` unless they need shared state
- Use `doctest` where practical

## Version Control

- Conventional Commits format: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`
- Keep commits small and focused

## Do NOT

- Create a `config/` directory — this is a library, not an application
- Use `Application.get_env/3` — accept config via function arguments or struct fields
- Add a supervision tree or `mod:` to `application/0`
- Create empty placeholder module files — only create modules when implementing them
- Add `@impl true` on callbacks without a corresponding `@behaviour`
