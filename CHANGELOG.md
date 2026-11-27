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
- Arrow writes (`write_dataframe`, and `write_dataset` to files or MinIO) turn text held in string types other than `String` into `String`, as they already turned enums into text: a column mixing `String` and `SubString` was written as an Arrow union.
- `MinIOMedia` reads and writes data frames as a `FileSystemMedia` does: each `read_dataframe` and `write_dataframe` goes through the path functions on a temporary file, so an object holds what a local file of its name holds. `write_dataframe`'s Arrow object is now in the Arrow file format (it was an Arrow stream, which readers such as pyarrow's datasets refuse; `write_dataset` already wrote Arrow files, through a temporary folder); gzipped CSV, Feather and Excel objects work, and a TSV object holds what the file functions write (commas: they write a `.tsv` file so, a file-system behaviour left as it is); the `format` keyword wins over the media's `format`; `atomic` is accepted; `filename` may be given as a keyword, and without it the object is the one whose key is the prefix. Objects written before as Arrow streams are still read.
- `read_dataset` on a `MinIOMedia` downloads the prefix to a temporary folder and reads it as `read_dataset(::FileSystemMedia)` reads a folder, typed or not: a dataset with an `iParameters` field failed ("Missing attribute"), and every untyped read failed (`JSON.parsefile` given an `IOBuffer`). As for a folder, an untyped read of a type that cannot be resolved is refused (it gave a `LoadedDataSet`).
- Objects get their content type from their name's extension (`application/vnd.apache.arrow.file` for Arrow), in `write_dataframe` and `write_dataset`.
- `MinIOMedia` streams every read and write, with no temporary file or folder and no whole object held twice. Writes go through a buffer of `part_size` bytes (new keyword, 64 MiB by default, at least 5 MiB): an object that fits is put in one request, a larger one is a multipart upload, one part per full buffer, with one part uploading while the next fills (at most `2 * part_size` buffered); the part size doubles every 1,000 parts to stay under S3's 10,000. A failed upload is aborted. Reads take the size from a HEAD and fetch ranged GETs of `part_size` bytes into one buffer; Arrow is read straight from it. Each part and each ranged GET is logged (`key, part, bytes, total_bytes, seconds, mib_s`), then one line per object. Arrow objects keep the file format and the same bytes as a `FileSystemMedia` file.
- `write_dataset` on a `MinIOMedia` streams each table, then writes `parameters/`, `data.json`, and `data_info.json` last as the completion mark (it uploaded a temporary folder in alphabetical order). One LIST up front refuses existing keys unless `overwrite=true`, replacing a HEAD per object.
- `read_dataset` on a `MinIOMedia` fetches only the root tables, `data.json`, `data_info.json` and `parameters/*.json`, into memory; a prefix holding none of them is refused with `ArgumentError`.

### Fixed
- `stop_logger!` uploads the records a `MinIOMedia` sink still buffers (they were lost unless `minio_flush_log_buffer!` was called); `minio_flush_log_buffer!` keeps the records buffered if their upload fails.
- `read_dataset` on a `MinIOMedia` downloaded everything under the prefix, nested runs and logs included.
- `write_dataset` to a `MinIOMedia` with `atomic=true` and `overwrite=true`: a failure left a mix of old and new objects. It now deletes what it wrote and the rest of the old dataset's layout, leaving no dataset; nested prefixes are untouched.
- `MinIOMedia` uses MyJuliaToolbox's own `AWSS3` and `AWS` (both in its `[deps]`): it loaded them from `Main`, so a project that loads MyJuliaToolbox without listing `AWSS3` (a pipeline project run in its own environment, for one) failed at `MinIOMedia(...)` with "MinIOMedia requires AWSS3.jl". The lazy-load guard `_require_awss3` is gone.
- `MinIOMedia`: `_s3_delete` was called but not defined, so `write_dataset`'s clean-up after a failed upload (`atomic=true`) deleted nothing, nor did the MinIO tests' clean-up; it now removes the objects.
- README and the MinIO logger test passed `sink_kwargs=(batch_logs=false,)`, which `AsyncLogger` hands to the sink as one option named `sink_kwargs` (records stayed batched); they pass `batch_logs=false`.

### Tests
- MinIO: an object holds what a local file of its name holds (offline: Arrow file byte for byte, the `format` keyword, gzipped CSV, TSV, Excel, an Arrow stream still read, an unknown extension refused, content types, the object a call names); with a server: the same through MinIO, `filename` as a keyword and the prefix as the object, `_s3_delete`, `write_dataset`'s tables as Arrow files. The MinIO tests name the toolbox's internals `MyJuliaToolbox.IO` (`IO` alone is Base's).
- Added constructor field coverage for `parameters_locator` in media tests.
- Added parameter-reading tests covering filesystem locator, database locator, and missing-locator error handling.
- Added an Arrow test for columns of text in other string types (a mix of `String` and `SubString`, with and without `missing`).
