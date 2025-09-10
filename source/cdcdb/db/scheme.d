auto _scheme = [
	q{
		-- ------------------------------------------------------------
		-- Метаданные снимка
		-- ------------------------------------------------------------
		CREATE TABLE IF NOT EXISTS snapshots (
			-- Уникальный числовой идентификатор снимка. Используется во внешних ключах.
			id INTEGER PRIMARY KEY AUTOINCREMENT,

			-- Путь к исходному файлу, для удобства навигации/поиска.
			file_path TEXT,

			file_sha256 BLOB NOT NULL CHECK (length(file_sha256) = 32),

			-- Произвольная метка/название снимка (для человека).
			label TEXT,

			-- Время создания записи (UTC). По умолчанию - текущее.
			created_utc TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),

			-- Полная длина исходного файла в байтах (до разбиения на чанки).
			source_length INTEGER NOT NULL,

			-- Пороговые размеры FastCDC: минимальный/целевой/максимальный размер чанка (в байтах).
			-- Фиксируются для воспроизводимости и сравнения результатов.
			algo_min INTEGER NOT NULL,
			algo_normal INTEGER NOT NULL,
			algo_max INTEGER NOT NULL,

			-- Маски FastCDC для определения границ чанков (обычно вида 2^n - 1).
			-- Хранятся для воспроизводимости.
			mask_s INTEGER NOT NULL,
			mask_l INTEGER NOT NULL,

			-- Состояние снимка:
			-- 0 - "pending" - метаданные созданы, состав не полностью загружен;
			-- 1 - "ready"	- все чанки привязаны, снимок готов к использованию.
			status INTEGER NOT NULL DEFAULT 0
				CHECK (typeof(status) = "integer" AND status IN (0,1))
		)
	},
	q{
		-- ------------------------------------------------------------
		-- Уникальные куски содержимого (дедупликация по sha256)
		-- ------------------------------------------------------------
		CREATE TABLE IF NOT EXISTS blobs (
			-- Хэш содержимого чанка. Храним как BLOB(32) (сырые 32 байта SHA-256).
			sha256 BLOB PRIMARY KEY CHECK (length(sha256) = 32),

			-- Хэш сжатого содержимого (если zstd=1). Может быть NULL при zstd=0.
			z_sha256 BLOB,

			-- Размер чанка в байтах (до сжатия).
			size INTEGER NOT NULL,

			-- Размер сжатого чанка (в байтах). Можно держать NOT NULL и заполнять =size при zstd=0,
			-- либо сделать NULL при zstd=0 (см. CHECK ниже допускает NULL).
			z_size INTEGER,

			-- Сырые байты: при zstd=1 здесь лежит сжатый блок, иначе - исходные байты.
			content BLOB NOT NULL,

			-- Таймштампы
			created_utc   TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
			last_seen_utc TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),

			-- Счётчик ссылок из snapshot_chunks
			refcount INTEGER NOT NULL DEFAULT 0,

			-- Флаг сжатия: 0 - без сжатия; 1 - zstd
			zstd INTEGER NOT NULL DEFAULT 0
				CHECK (typeof(zstd) = "integer" AND zstd IN (0,1)),

			-- Дополнительные гарантии целостности:
			CHECK (refcount >= 0),

			-- Если zstd=1, длина content должна равняться z_size;
			-- если zstd=0 - длина content должна равняться size.
			CHECK (
				(zstd = 1 AND z_size IS NOT NULL AND length(content) = z_size)
			OR (zstd = 0 AND length(content) = size )
			),

			-- Согласованность z_sha256 (если задан)
			CHECK (z_sha256 IS NULL OR length(z_sha256) = 32)
		)
	},
	q{
		-- ------------------------------------------------------------
		-- Состав снимка (упорядоченный список чанков)
		-- ------------------------------------------------------------
		CREATE TABLE IF NOT EXISTS snapshot_chunks (
			-- Ссылка на snapshots.id. Определяет, к какому снимку относится строка.
			snapshot_id INTEGER NOT NULL,

			-- Позиция чанка в снимке (индексация на твой выбор - 0/1-based; важно быть последовательным).
			-- Обеспечивает порядок сборки.
			chunk_index INTEGER NOT NULL,

			-- Смещение чанка в исходном файле (в байтах).
			-- Можно восстановить суммой size предыдущих чанков, но хранение ускоряет проверки/отладку.
			offset INTEGER,

			-- Размер конкретного чанка в составе (дублирует blobs.size для ускорения/валидации).
			size INTEGER NOT NULL,

			-- Ссылка на blobs.sha256. Привязывает позицию к конкретному содержимому.
			-- Тип BLOB обязан совпадать с типом в родительской таблице.
			sha256 BLOB NOT NULL,

			-- Уникальность позиции чанка в рамках одного снимка.
			PRIMARY KEY (snapshot_id, chunk_index),

			-- Внешние ключи и их поведение:
			-- При удалении снимка его строки состава удаляются автоматически.
			FOREIGN KEY (snapshot_id)
				REFERENCES snapshots(id)
				ON UPDATE CASCADE
				ON DELETE CASCADE,

			-- Нельзя удалить blob, если он где-то используется; обновление ключа запрещено.
			FOREIGN KEY (sha256)
				REFERENCES blobs(sha256)
				ON UPDATE RESTRICT
				ON DELETE RESTRICT
		)
	},
	q{
		CREATE INDEX IF NOT EXISTS idx_snapshots_path_sha
			ON snapshots(file_path, file_sha256)
	},
	q{
		-- Быстрый выбор всех чанков конкретного снимка (частый запрос).
		CREATE INDEX IF NOT EXISTS idx_snapshot_chunks_snapshot
			ON snapshot_chunks(snapshot_id)
	},
	q{
		-- Быстрый обратный поиск: где используется данный blob (для GC/аналитики).
		-- Индекс по BLOB(32) хорошо работает для точного поиска sha256.
		CREATE INDEX IF NOT EXISTS idx_snapshot_chunks_sha
			ON snapshot_chunks(sha256)
	},
	// -- ------------------------------------------------------------
	// -- Триггеры для управления refcount и GC blob'ов
	// -- ------------------------------------------------------------
	q{
		-- Инкремент счётчика при привязке чанка к снимку.
		-- Обновляем last_seen_utc, чтобы фиксировать "живость" контента.
		-- ВАЖНО: FK гарантирует, что соответствующий blobs.sha256 уже существует.
		CREATE TRIGGER IF NOT EXISTS trg_snapshot_chunks_ai
		AFTER INSERT ON snapshot_chunks
		BEGIN
			UPDATE blobs
				SET refcount = refcount + 1,
					last_seen_utc = CURRENT_TIMESTAMP
			WHERE sha256 = NEW.sha256;
		END
	},
	q{
		-- Декремент счётчика при удалении строки состава.
		-- Если счётчик стал 0 - удаляем неиспользуемый blob (авто-GC).
		CREATE TRIGGER IF NOT EXISTS trg_snapshot_chunks_ad
		AFTER DELETE ON snapshot_chunks
		BEGIN
			UPDATE blobs
				SET refcount = refcount - 1
			WHERE sha256 = OLD.sha256;

			DELETE FROM blobs
			WHERE sha256 = OLD.sha256
				AND refcount <= 0;
		END
	},
	q{
		-- Корректировка счётчиков при смене sha256 в составе.
		-- Триггер срабатывает только при реальном изменении значения.
		-- Предполагается, что NEW.sha256 существует в blobs (иначе FK не даст обновить).
		CREATE TRIGGER IF NOT EXISTS trg_snapshot_chunks_au
		AFTER UPDATE OF sha256 ON snapshot_chunks
		FOR EACH ROW
		WHEN NEW.sha256 <> OLD.sha256
		BEGIN
			UPDATE blobs
				SET refcount = refcount - 1
			WHERE sha256 = OLD.sha256;

			DELETE FROM blobs
			WHERE sha256 = OLD.sha256
				AND refcount <= 0;

			UPDATE blobs
				SET refcount = refcount + 1,
					last_seen_utc = CURRENT_TIMESTAMP
			WHERE sha256 = NEW.sha256;
		END
	},
	q{
		-- Автоматическая смена статуса снимка на 1 - "ready",
		-- когда сумма размеров его чанков стала равна source_length.
		-- Примечание: простая эвристика; если потом удалишь/поменяешь чанки,
		-- триггер ниже вернёт статус обратно на 0 - "pending".
		CREATE TRIGGER IF NOT EXISTS trg_snapshots_mark_ready
		AFTER INSERT ON snapshot_chunks
		BEGIN
		UPDATE snapshots
			SET status = 1
		WHERE id = NEW.snapshot_id
			AND (SELECT COALESCE(SUM(size),0)
					FROM snapshot_chunks
				WHERE snapshot_id = NEW.snapshot_id)
				= (SELECT source_length FROM snapshots WHERE id = NEW.snapshot_id);
		END
	},
	q{
		-- При удалении любого чанка снимок снова помечается как 0 - "pending".
		-- Это простой безопасный фоллбэк; следующая вставка приравняет суммы и вернёт 1 - "ready".
		CREATE TRIGGER IF NOT EXISTS trg_snapshots_mark_pending
		AFTER DELETE ON snapshot_chunks
		BEGIN
		UPDATE snapshots
			SET status = 0
		WHERE id = OLD.snapshot_id;
		END
	}
];
