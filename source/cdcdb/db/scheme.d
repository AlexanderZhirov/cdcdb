auto _scheme = [
	q{
		-- ------------------------------------------------------------
		-- Таблица snapshots
		-- ------------------------------------------------------------
		CREATE TABLE IF NOT EXISTS snapshots (
			-- идентификатор снимка
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			-- путь к исходному файлу
			file_path TEXT,
			-- SHA-256 всего файла (BLOB(32))
			file_sha256 BLOB NOT NULL CHECK (length(file_sha256) = 32),
			-- метка/название снимка
			label TEXT,
			-- время создания (UTC)
			created_utc TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
			-- длина исходного файла в байтах
			source_length INTEGER NOT NULL,
			-- FastCDC: минимальный размер чанка
			algo_min INTEGER NOT NULL,
			-- FastCDC: целевой размер чанка
			algo_normal INTEGER NOT NULL,
			-- FastCDC: максимальный размер чанка
			algo_max INTEGER NOT NULL,
			-- FastCDC: маска S
			mask_s INTEGER NOT NULL,
			-- FastCDC: маска L
			mask_l INTEGER NOT NULL,
			-- 0=pending, 1=ready
			status INTEGER NOT NULL DEFAULT 0
				CHECK (status IN (0,1))
		)
	},
	q{
		-- ------------------------------------------------------------
		-- Таблица blobs
		-- ------------------------------------------------------------
		CREATE TABLE IF NOT EXISTS blobs (
			-- SHA-256 исходного содержимого (BLOB(32))
			sha256 BLOB PRIMARY KEY CHECK (length(sha256) = 32),
			-- SHA-256 сжатого содержимого (BLOB(32)) или NULL
			z_sha256 BLOB,
			-- размер исходного содержимого, байт
			size INTEGER NOT NULL,
			-- размер сжатого содержимого, байт
			z_size INTEGER NOT NULL,
			-- байты (сжатые при zstd=1, иначе исходные)
			content BLOB NOT NULL,
			-- время создания записи (UTC)
			created_utc   TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
			-- время последней ссылки (UTC)
			last_seen_utc TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
			-- число ссылок из snapshot_chunks
			refcount INTEGER NOT NULL DEFAULT 0,
			-- 0=нет сжатия, 1=zstd
			zstd INTEGER NOT NULL DEFAULT 0
				CHECK (zstd IN (0,1)),
			CHECK (refcount >= 0),
			CHECK (
				(zstd = 1 AND length(content) = z_size) OR
				(zstd = 0 AND length(content) = size)
			),
			CHECK (z_sha256 IS NULL OR length(z_sha256) = 32)
		)
	},
	q{
		-- ------------------------------------------------------------
		-- Таблица snapshot_chunks
		-- ------------------------------------------------------------
		CREATE TABLE IF NOT EXISTS snapshot_chunks (
			-- FK -> snapshots.id
			snapshot_id INTEGER NOT NULL,
			-- порядковый номер чанка в снимке
			chunk_index INTEGER NOT NULL,
			-- смещение чанка в исходном файле, байт
			offset INTEGER,
			-- FK -> blobs.sha256 (BLOB(32))
			sha256 BLOB NOT NULL,
			PRIMARY KEY (snapshot_id, chunk_index),
			FOREIGN KEY (snapshot_id)
				REFERENCES snapshots(id)
				ON UPDATE CASCADE
				ON DELETE CASCADE,
			FOREIGN KEY (sha256)
				REFERENCES blobs(sha256)
				ON UPDATE RESTRICT
				ON DELETE RESTRICT
		)
	},
	q{
		-- Индекс для запросов вида: WHERE file_path=? AND file_sha256=?
		CREATE INDEX IF NOT EXISTS idx_snapshots_path_sha
			ON snapshots(file_path, file_sha256)
	},
	q{
		-- Индекс для обратного поиска использования blob по sha256
		CREATE INDEX IF NOT EXISTS idx_snapshot_chunks_sha
			ON snapshot_chunks(sha256)
	},
	// ------------------------------------------------------------
	// Триггеры на поддержание refcount и статуса снимка
	// ------------------------------------------------------------
	q{
		-- AFTER INSERT: увеличить refcount и обновить last_seen_utc
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
		-- AFTER DELETE: уменьшить refcount и удалить blob при refcount <= 0
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
		-- AFTER UPDATE OF sha256: корректировка счётчиков при смене ссылки
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
		-- AFTER INSERT: установить status=1 при совпадении суммы размеров с source_length
		CREATE TRIGGER IF NOT EXISTS trg_snapshots_mark_ready
		AFTER INSERT ON snapshot_chunks
		BEGIN
			UPDATE snapshots
				SET status = 1
			WHERE id = NEW.snapshot_id
				AND (SELECT COALESCE(SUM(b.size),0)
						FROM snapshot_chunks sc
						JOIN blobs b ON b.sha256 = sc.sha256
						WHERE sc.snapshot_id = NEW.snapshot_id)
					= (SELECT source_length FROM snapshots WHERE id = NEW.snapshot_id);
		END
	},
	q{
		-- AFTER DELETE: установить status=0 для снимка, из которого удалён чанк
		CREATE TRIGGER IF NOT EXISTS trg_snapshots_mark_pending
		AFTER DELETE ON snapshot_chunks
		BEGIN
			UPDATE snapshots
				SET status = 0
			WHERE id = OLD.snapshot_id;
		END
	},
	q{
		-- Проверка порядка индексов и непрерывности смещений.
		CREATE TRIGGER IF NOT EXISTS trg_sc_before_insert
		BEFORE INSERT ON snapshot_chunks
		BEGIN
			-- Ожидаемое значение: max(chunk_index)+1 для данного snapshot_id (или текущий при первой вставке).
			SELECT CASE
				WHEN NEW.chunk_index <> COALESCE(
					(SELECT MAX(chunk_index) FROM snapshot_chunks WHERE snapshot_id = NEW.snapshot_id),
					NEW.chunk_index - 1
				) + 1
				THEN RAISE(ABORT, "snapshot_chunks: индекс chunk_index должен быть непрерывным и только возрастающим")
			END;

			-- Проверка: offset равен сумме размеров предыдущих чанков.
			SELECT CASE
				WHEN NEW.offset <> (
					SELECT COALESCE(SUM(b.size), 0)
					FROM snapshot_chunks sc
					JOIN blobs b ON b.sha256 = sc.sha256
					WHERE sc.snapshot_id = NEW.snapshot_id
					AND sc.chunk_index < NEW.chunk_index
				)
				THEN RAISE(ABORT, "snapshot_chunks: offset должен равняться сумме размеров предыдущих чанков")
			END;
		END
	},
	q{
		-- Запрет обновления строк состава; использовать DELETE + INSERT.
		CREATE TRIGGER IF NOT EXISTS trg_sc_block_update
		BEFORE UPDATE ON snapshot_chunks
		BEGIN
			SELECT RAISE(ABORT, "snapshot_chunks: UPDATE запрещён; используйте DELETE + INSERT");
		END
	}
];
