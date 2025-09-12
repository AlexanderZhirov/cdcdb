module cdcdb.cdc.cas;

import cdcdb.db;
import cdcdb.cdc.core;

import zstd;

import std.digest.sha : SHA256, digest;
import std.format : format;
import std.exception : enforce;

// Content-Addressable Storage (Контентно-адресуемая система хранения)
// CAS-хранилище со снапшотами
final class CAS
{
private:
	DBLite _db;
	bool _zstd;

	size_t _minSize;
	size_t _normalSize;
	size_t _maxSize;
	size_t _maskS;
	size_t _maskL;
	CDC _cdc;
public:
	this(
		string database,
		bool zstd = false,
		size_t busyTimeout = 3000,
		size_t maxRetries = 3,
		size_t minSize = 256,
		size_t normalSize = 512,
		size_t maxSize = 1024,
		size_t maskS = 0xFF,
		size_t maskL = 0x0F
	) {
		_db = new DBLite(database, busyTimeout, maxRetries);
		_zstd = zstd;

		_minSize = minSize;
		_normalSize = normalSize;
		_maxSize = maxSize;
		_maskS = maskS;
		_maskL = maskL;

		_cdc = new CDC(_minSize, _normalSize, _maxSize, _maskS, _maskL);
	}

	size_t newSnapshot(string label, const(ubyte)[] data, string description = string.init)
	{
		if (data.length == 0) {
			throw new Exception("Данные имеют нулевой размер");
		}

		ubyte[32] sha256 = digest!SHA256(data);

		// Если последний снимок файла соответствует текущему состоянию
		if (_db.isLast(label, sha256)) return 0;

		Snapshot snapshot;

		snapshot.label = label;
		snapshot.sha256 = sha256;
		snapshot.description = description;
		snapshot.sourceLength = data.length;
		snapshot.algoMin = _minSize;
		snapshot.algoNormal = _normalSize;
		snapshot.algoMax = _maxSize;
		snapshot.maskS = _maskS;
		snapshot.maskL = _maskL;

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

		auto idSnapshot = _db.addSnapshot(snapshot);

		SnapshotChunk snapshotChunk;
		Blob blob;

		blob.zstd = _zstd;

		// Разбить на фрагменты
		auto chunks = _cdc.split(data);

		// Запись фрагментов в БД
		foreach (chunk; chunks)
		{
			blob.sha256 = chunk.sha256;
			blob.size = chunk.size;

			auto content = data[chunk.offset .. chunk.offset + chunk.size];

			if (_zstd) {
				ubyte[] zBytes = compress(content, 22);
				size_t zSize = zBytes.length;
				ubyte[32] zHash = digest!SHA256(zBytes);

				blob.zSize = zSize;
				blob.zSha256 = zHash;
				blob.content = zBytes;
			} else {
				blob.content = content.dup;
			}

			// Запись фрагментов
			_db.addBlob(blob);

			snapshotChunk.snapshotId = idSnapshot;
			snapshotChunk.chunkIndex = chunk.index;
			snapshotChunk.offset = chunk.offset;
			snapshotChunk.sha256 = chunk.sha256;

			// Привязка фрагментов к снимку
			_db.addSnapshotChunk(snapshotChunk);
		}

		ok = true;

		return idSnapshot;
	}

	Snapshot[] getSnapshots(string label = "")
	{
		return _db.getSnapshots(label);
	}

	ubyte[] getSnapshotData(const ref Snapshot snapshot)
	{
		auto dataChunks = _db.getChunks(snapshot.id);
		ubyte[] content;

		foreach (chunk; dataChunks) {
			ubyte[] bytes;
			if (chunk.zstd) {
				enforce(chunk.zSize == chunk.content.length, "Размер сжатого фрагмента не соответствует ожидаемому");
				bytes = cast(ubyte[]) uncompress(chunk.content);
			} else {
				bytes = chunk.content;
			}
			enforce(chunk.size == bytes.length, "Оригинальный размер не соответствует ожидаемому");
			content ~= bytes;
		}
		enforce(snapshot.sha256 == digest!SHA256(content), "Хеш-сумма файла не совпадает");

		return content;
	}

	void removeSnapshot(const ref Snapshot snapshot)
	{
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

		_db.deleteSnapshot(snapshot.id);

		ok = true;
	}

	string getVersion() {
		import cdcdb.version_;
		return cdcdbVersion;
	}
}
