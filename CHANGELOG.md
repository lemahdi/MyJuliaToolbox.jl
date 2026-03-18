# Changelog

## Unreleased

### Added
- Added `ArchiveMedia` media backend for reading and writing datasets as `.zip` or `.tar.gz` / `.tgz` archives.
  - `write_dataset(ArchiveMedia("out.zip"), dataset)` packs a dataset directory into a zip archive (atomic by default).
  - `read_dataset(ArchiveMedia("out.zip"))` / `read_dataset("out.zip")` extracts and reads back, auto-resolving the concrete type from `data_info.json`.
  - Format is inferred from file extension; can be overridden with `format=:zip` or `format=:tar_gz`.
  - All existing dataset features (typed reads, `iParameters` refs, `data_info.json`, CSV/Arrow choice) work identically inside archives.
- Added `ZipFile` and `Tar` (stdlib) dependencies to support archive I/O.
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
