module cdcdb.cdc.cas;

import cdcdb.db;
import cdcdb.cdc.core;

import std.digest.sha : SHA256, digest;
import std.format : format;

import zstd;

// CAS-хранилище (Content-Addressable Storage) со снапшотами
final class CAS
{
private:
	DBLite _db;
	bool _zstd;
public:
	this(string database, bool zstd = false)
	{
		_db = new DBLite(database);
		_zstd = zstd;
	}

	size_t saveSnapshot(string filePath, const(ubyte)[] data)
	{
		ubyte[32] hashSource = digest!SHA256(data);
		// Сделать запрос в БД по filePath и сверить хеш файлов

		import std.stdio : writeln;
		// writeln(hashSource.length);
		


		// Параметры для CDC вынести в отдельные настройки (продумать)
		auto cdc = new CDC(300, 700, 1000, 0xFF, 0x0F);
		// Разбить на фрагменты
		auto chunks = cdc.split(data);

		Snapshot snapshot;
		snapshot.filePath = filePath;
		snapshot.fileSha256 = hashSource;
		snapshot.label = "Файл для теста";
		snapshot.sourceLength = data.length;

		_db.beginImmediate();

		auto idSnapshot = _db.addSnapshot(snapshot);

		SnapshotChunk snapshotChunk;
		Blob blob;

		blob.zstd = _zstd;

		// Записать фрагменты в БД
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

			_db.addBlob(blob);

			snapshotChunk.snapshotId = idSnapshot;
			snapshotChunk.chunkIndex = chunk.index;
			snapshotChunk.offset = chunk.offset;
			snapshotChunk.size = chunk.size;
			snapshotChunk.sha256 = chunk.sha256;

			_db.addSnapshotChunk(snapshotChunk);
		}
		_db.commit();
		// Записать манифест в БД
		// Вернуть ID манифеста
		return 0;
	}
}
