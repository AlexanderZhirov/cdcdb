module cdcdb.storage;

import cdcdb.dblite;
import cdcdb.core;
import cdcdb.snapshot;

import zstd : compress, Level;

final class Storage
{
private:
	// Параметры работы с базой данных
	DBLite _db;
	bool _zstd;
	int _level;
	// Настройки CDC механизма
	CDC _cdc;
	size_t _minSize;
	size_t _normalSize;
	size_t _maxSize;
	size_t _maskS;
	size_t _maskL;

	void initCDC(size_t minSize = 256, size_t normalSize = 512, size_t maxSize = 1024,
		size_t maskS = 0xFF, size_t maskL = 0x0F)
	{
		_minSize = minSize;
		_normalSize = normalSize;
		_maxSize = maxSize;
		_maskS = maskS;
		_maskL = maskL;
		// CDC не хранит динамически выделенных данных, переинициализация безопасна
		_cdc = new CDC(_minSize, _normalSize, _maxSize, _maskS, _maskL);
	}

public:
	this(string database, bool zstd = false, int level = Level.base, size_t busyTimeout = 3000, size_t maxRetries = 3)
	{
		_db = new DBLite(database, busyTimeout, maxRetries);
		_zstd = zstd;
		_level = level;
		initCDC();
	}

	void setupCDC(size_t minSize, size_t normalSize, size_t maxSize, size_t maskS, size_t maskL)
	{
		initCDC(minSize, normalSize, maxSize, maskS, maskL);
	}

	Snapshot newSnapshot(string label, const(ubyte)[] data, string description = string.init)
	{
		if (data.length == 0)
		{
			throw new Exception("Данные имеют нулевой размер");
		}

		import std.digest.sha : SHA256, digest;

		ubyte[32] sha256 = digest!SHA256(data);

		// Если последний снимок файла соответствует текущему состоянию
		if (_db.isLast(label, sha256))
			return null;

		DBSnapshot dbSnapshot;

		dbSnapshot.label = label;
		dbSnapshot.sha256 = sha256;
		dbSnapshot.description = description;
		dbSnapshot.sourceLength = data.length;
		dbSnapshot.algoMin = _minSize;
		dbSnapshot.algoNormal = _normalSize;
		dbSnapshot.algoMax = _maxSize;
		dbSnapshot.maskS = _maskS;
		dbSnapshot.maskL = _maskL;

		_db.beginImmediate();

		bool ok;

		scope (exit)
		{
			if (!ok)
				_db.rollback();
		}
		scope (success)
		{
			_db.commit();
		}

		auto idSnapshot = _db.addSnapshot(dbSnapshot);

		DBSnapshotChunk dbSnapshotChunk;
		DBBlob dbBlob;

		dbBlob.zstd = _zstd;

		// Разбить на фрагменты
		Chunk[] chunks = _cdc.split(data);

		// Запись фрагментов в БД
		foreach (chunk; chunks)
		{
			dbBlob.sha256 = chunk.sha256;
			dbBlob.size = chunk.size;

			auto content = data[chunk.offset .. chunk.offset + chunk.size];

			if (_zstd) {
				ubyte[] zBytes = compress(content, _level);
				size_t zSize = zBytes.length;
				ubyte[32] zHash = digest!SHA256(zBytes);

				dbBlob.zSize = zSize;
				dbBlob.zSha256 = zHash;
				dbBlob.content = zBytes;
			} else {
				dbBlob.content = content.dup;
			}

			// Запись фрагментов
			_db.addBlob(dbBlob);

			dbSnapshotChunk.snapshotId = idSnapshot;
			dbSnapshotChunk.chunkIndex = chunk.index;
			dbSnapshotChunk.offset = chunk.offset;
			dbSnapshotChunk.sha256 = chunk.sha256;

			// Привязка фрагментов к снимку
			_db.addSnapshotChunk(dbSnapshotChunk);
		}

		ok = true;

		Snapshot snapshot = new Snapshot(_db, idSnapshot);

		return snapshot;
	}

	// Удаляет снимок по метке, возвращает количество удаленных снимков
	long removeSnapshots(string label) {
		return _db.deleteSnapshot(label);
	}

	bool removeSnapshots(Snapshot snapshot) {
		return removeSnapshots(snapshot.id);
	}

	bool removeSnapshots(long idSnapshot) {
		return _db.deleteSnapshot(idSnapshot) == idSnapshot;
	}

	Snapshot getSnapshot(long idSnapshot) {
		return new Snapshot(_db, idSnapshot);
	}

	Snapshot[] getSnapshots(string label = string.init) {
		Snapshot[] snapshots;
		
		foreach (snapshot; _db.getSnapshots(label)) {
			snapshots ~= new Snapshot(_db, snapshot);
		}

		return snapshots;
	}

	string getVersion() const @safe nothrow
	{
		import cdcdb.version_ : cdcdbVersion;

		return cdcdbVersion;
	}
}
