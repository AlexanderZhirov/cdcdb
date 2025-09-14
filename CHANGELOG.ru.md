# Changelog

## [0.1.1] - 2025-09-14
### Added
- Таблица `labels` для меток снимков.
### Fixed
- Улучшена целостность данных при нормализации меток.

## [0.1.0] - 2025-09-13
### Added
- Библиотека для снимков данных на базе SQLite с контентно-зависимым разбиением (FastCDC).
- Дедупликация по SHA-256 чанков, опциональная компрессия Zstd.
- Сквозная проверка целостности: хеш каждого чанка и итогового файла.
- Транзакции (WAL), базовые ограничения целостности и триггеры.
- Высокоуровневый API:
  - `Storage`: `newSnapshot`, `getSnapshots`, `getSnapshot`, `removeSnapshots`, `setupCDC`, `getVersion`.
  - `Snapshot`: `data()` (буфер) и потоковый `data(void delegate(const(ubyte)[]))`, `remove()`, свойства (`id`, `label`, `created`, `length`, `sha256`, `status`, `description`).
- Инструмент для генерации Gear-таблицы для FastCDC (`tools/gen.d`).
