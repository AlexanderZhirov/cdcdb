module cdcdb.cdc.cas;

import cdcdb.db;
import cdcdb.cdc.core;

import std.digest.sha : SHA256, digest;
import std.format : format;

import zstd;

import std.exception : enforce;
import std.stdio : writeln;
import std.conv : to;

import std.file : write;

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

		// writeln(hashSource.length);
		


		// Параметры для CDC вынести в отдельные настройки (продумать)
		auto cdc = new CDC(256, 512, 1024, 0xFF, 0x0F);
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
			snapshotChunk.sha256 = chunk.sha256;

			_db.addSnapshotChunk(snapshotChunk);
		}
		_db.commit();
		// Записать манифест в БД
		// Вернуть ID манифеста
		return 0;
	}

	void restoreSnapshot()
	{
		string restoreFile = "/tmp/restore.d";

		foreach (Snapshot snapshot; _db.getSnapshots("/tmp/text")) {
			auto dataChunks = _db.getChunks(snapshot.id);
			ubyte[] content;

			foreach (SnapshotDataChunk chunk; dataChunks) {
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

			enforce(snapshot.fileSha256 == digest!SHA256(content), "Хеш-сумма файла не совпадает");

			write(snapshot.filePath ~ snapshot.id.to!string, content);
		}
	}
}
