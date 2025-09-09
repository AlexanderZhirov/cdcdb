auto _scheme = [
	q{
		-- Метаданные снапшота
		CREATE TABLE IF NOT EXISTS snapshots (
			-- Уникальный числовой идентификатор снимка. Используется во внешних ключах.
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			-- Произвольная метка/название снимка.
			label TEXT,
			-- Время создания записи в UTC. По умолчанию - сейчас.
			created_utc TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
			-- Полная длина исходного файла в байтах для этого снимка (до разбиения на чанки).
			source_length INTEGER NOT NULL,
			-- Пороговые размеры FastCDC (минимальный/целевой/максимальный размер чанка) в байтах.
			-- Фиксируются здесь, чтобы позже можно было корректно пересобрать/сравнить.
			algo_min INTEGER NOT NULL,
			algo_normal INTEGER NOT NULL,
			algo_max INTEGER NOT NULL,
			-- Маски для определения границ чанков (быстрый роллинг-хэш/FastCDC).
			-- Обычно степени вида 2^n - 1. Хранятся для воспроизводимости.
			mask_s INTEGER NOT NULL,
			mask_l INTEGER NOT NULL,
			-- Состояние снимка:
			-- pending - метаданные созданы, состав не полностью загружен;
			-- ready - все чанки привязаны, снимок готов к использованию.
			status TEXT NOT NULL DEFAULT "pending" CHECK (status IN ("pending","ready"))
		)
	},
	q{
		-- Уникальные куски содержимого (сам контент в БД)
		CREATE TABLE IF NOT EXISTS blobs (
			-- Хэш содержимого чанка. Ключ обеспечивает дедупликацию: одинаковый контент хранится один раз.
			sha256 TEXT PRIMARY KEY,
			-- Размер этого чанка в байтах.
			size INTEGER NOT NULL,
			-- Сырые байты чанка.
			content BLOB NOT NULL,
			-- Когда этот контент впервые появился в базе (UTC).
			created_utc TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
		)
	},
	q{
		-- Состав снапшота (порядок чанков важен)
		CREATE TABLE IF NOT EXISTS snapshot_chunks (
			-- Ссылка на snapshots.id. Определяет, к какому снимку относится строка.
			snapshot_id INTEGER NOT NULL,
			-- Позиция чанка в снимке (индексация).
			-- Обеспечивает порядок сборки.
			chunk_index INTEGER NOT NULL,
			-- Смещение чанка в исходном файле в байтах.
			-- Можно восстановить как сумму size предыдущих чанков по chunk_index,
			-- но хранение ускоряет проверки/отладку.
			offset INTEGER,
			-- Размер именно этого чанка в байтах (дублирует blobs.size для быстрого доступа и валидации).
			size INTEGER NOT NULL,
			-- Ссылка на blobs.sha256. Привязывает позицию в снимке к конкретному содержимому.
			sha256 TEXT NOT NULL,
			-- Гарантирует уникальность позиции чанка в рамках снимка и задаёт естественный порядок.
			PRIMARY KEY (snapshot_id, chunk_index),
			-- При удалении снимка его строки состава удаляются автоматически.
			-- Обновления id каскадятся (на практике id не меняют).
			FOREIGN KEY (snapshot_id) REFERENCES snapshots(id) ON UPDATE CASCADE ON DELETE CASCADE,
			-- Нельзя удалить blob, если он где-то используется (RESTRICT).
			-- Обновление хэша каскадится (редкий случай).
			FOREIGN KEY (sha256) REFERENCES blobs(sha256) ON UPDATE CASCADE ON DELETE RESTRICT
		)
	},
	q{
		-- Быстрый выбор всех чанков конкретного снимка (частый запрос).
		CREATE INDEX IF NOT EXISTS idx_snapshot_chunks_snapshot ON snapshot_chunks(snapshot_id)
	},
	q{
		-- Быстрый обратный поиск: где используется данный blob (для GC/аналитики).
		CREATE INDEX IF NOT EXISTS idx_snapshot_chunks_sha ON snapshot_chunks(sha256)
	}
];
