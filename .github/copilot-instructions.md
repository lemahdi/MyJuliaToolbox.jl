# Copilot Instructions for MyJuliaToolbox

## Scope
These instructions apply to all files in this repository.

## Project Context
- Language: Julia
- Package: MyJuliaToolbox
- Main source folder: src/
- Tests folder: test/
- Prefer existing abstractions in IO, dataset, parameters, and utils modules.

## Coding Guidelines
- Keep changes minimal and focused on the requested behavior.
- Preserve public APIs unless a change is explicitly requested.
- Follow existing naming and formatting patterns in nearby files.
- Prefer small helper methods over duplicating logic.
- Add comments only when logic is non-obvious.
- For data transformation code, prefer `Pipe` and `DataFramesMeta` functions before considering other approaches.

## API and Design Rules
- Favor explicit, type-stable method signatures where possible.
- Add overloads instead of breaking existing signatures.
- For file or media handling, reuse FileSystemMedia and iSourceMedia conventions.
- Use ArgumentError for invalid user input and keep error messages actionable.

## Testing Rules
- Add or update tests for every behavior change.
- Place tests in the corresponding suite under test/io, test/parameters, or test/utils.
- Prefer deterministic tests using temporary directories and cleanup guards.
- Ensure both happy path and error path are covered for new public methods.

## Validation
- Run targeted tests first, then run full package tests when changes are broad.
- Targeted test command example: `julia --project=. -e "include(\"test/io/dataset-tests.jl\")"`.
- Full test command: `julia --project=. -e "using Pkg; Pkg.test()"`.
- Do not leave failing tests in the branch.

## Documentation
- Update README.md or docs/ when user-facing behavior changes.
- Keep examples short and executable.

## Pull Request Quality
- Keep diffs small and easy to review.
- Include a short summary of what changed and why.
- Mention any limitations or follow-up items explicitly.

## Git Workflow
- Create a feature branch when the user requests it.
- Do not commit unless explicitly asked.
