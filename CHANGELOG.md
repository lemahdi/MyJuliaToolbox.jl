# Changelog

## Unreleased

### Added
- Added `parameters_locator` to `FileSystemMedia` and `DatabaseMedia` to support parameter file path/URL resolution in `read_parameters`.
- Added `DatabaseMedia` support for `read_parameters` when `parameters_locator` is provided.
- Added URL-based parameter loading support in `read_parameters`.

### Changed
- Updated `read_parameters` for `FileSystemMedia` to prioritize `parameters_locator` when present and fall back to `source.path`.
- Updated README examples to show `parameters_locator` usage for both filesystem and database media sources.

### Tests
- Added constructor field coverage for `parameters_locator` in media tests.
- Added parameter-reading tests covering filesystem locator, database locator, and missing-locator error handling.
