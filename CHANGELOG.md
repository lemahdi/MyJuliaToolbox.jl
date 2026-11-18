# Changelog

## Unreleased

### Added
- Added pipeline runs for Mykonos (`src/pipeline.jl`): `open_zones`, `read_landing`, `run_step`, `set_output!`, `write_run`.
  - `run_step` runs one step, named after its function, and writes the run's log (`steps.json`, the Dataset Tower's standard `mykonos.steps.v1`) in the run's prefix of the pipeline zone at the step's start and end; a failing step is recorded as `failed` and its error thrown again.
  - `set_output!` sets a dataset's table inside the running step and records the set (time, step, field, table, rows, columns).
  - `write_run` writes the dataset with `write_dataset` into `dataset/`, records each file's key, and refuses a table that no step set or that changed since its last set.
  - `open_zones` gives the landing zone and the run's prefix as `MinIOMedia` from environment variables; `read_landing` reads the landing tables listed in `landing.json`.
  - No new dependency.
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
- Arrow writes (`write_dataframe`, and `write_dataset` to files or MinIO) turn text held in string types other than `String` into `String`, as they already turned enums into text: a column mixing `String` and `SubString` was written as an Arrow union.

### Tests
- Added constructor field coverage for `parameters_locator` in media tests.
- Added parameter-reading tests covering filesystem locator, database locator, and missing-locator error handling.
- Added an Arrow test for columns of text in other string types (a mix of `String` and `SubString`, with and without `missing`).
