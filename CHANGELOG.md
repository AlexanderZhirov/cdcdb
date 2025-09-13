# Changelog

## [0.1.0] — 2025-09-13
### Added
- SQLite-backed snapshot library with content-defined chunking (FastCDC).
- Deduplication by SHA-256 of chunks; optional Zstd compression.
- End-to-end integrity checks: per-chunk hash and final file hash.
- Transactions (WAL), basic integrity constraints, and triggers.
- High-level API:
  - `Storage`: `newSnapshot`, `getSnapshots`, `getSnapshot`, `removeSnapshots`, `setupCDC`, `getVersion`.
  - `Snapshot`: `data()` (buffered) and streaming `data(void delegate(const(ubyte)[]))`, `remove()`, properties (`id`, `label`, `created`, `length`, `sha256`, `status`, `description`).
- Tool to generate a Gear table for FastCDC (`tools/gen.d`).
