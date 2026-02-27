# Changelog

## Unreleased

### Added
- Added `parameters_locator` to `SQLDumpMedia` and `DatabaseMedia` to support parameter file path/URL resolution in `read_parameters`.
- Added `DatabaseMedia` and `SQLDumpMedia` support for `read_parameters` when `parameters_locator` is provided.
- Added URL-based parameter loading support in `read_parameters`.

### Changed
- Moved `parameters_locator` from `FileSystemMedia` to `SQLDumpMedia`.
- Updated `read_parameters` for `FileSystemMedia` to use `source.path` directly.
- Updated README examples to show `parameters_locator` usage for database media sources.

### Tests
- Added constructor field coverage for `parameters_locator` in media tests.
- Added parameter-reading tests covering filesystem locator, database locator, and missing-locator error handling.
