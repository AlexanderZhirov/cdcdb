module cdcdb.snapshot;

import cdcdb.dblite;

import std.exception : enforce;

final class Snapshot {
private:
	DBLite _db;
	DBSnapshot _snapshot;
public:
	this(DBLite dblite, DBSnapshot dbSnapshot) {
		_db = dblite;
		_snapshot = dbSnapshot;
	}

	this(DBLite dblite, long idSnapshot) {
		_db = dblite;
		_snapshot = _db.getSnapshot(idSnapshot);
	}

	ubyte[] data() {
		auto dataChunks = _db.getChunks(_snapshot.id);
		ubyte[] content;

		import zstd : uncompress;

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

		import std.digest.sha : SHA256, digest;

		enforce(_snapshot.sha256 == digest!SHA256(content), "Хеш-сумма файла не совпадает");

		return content;
	}

	bool remove() {
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

		long idDeleted = _db.deleteSnapshot(_snapshot.id);

		ok = true;

		return _snapshot.id == idDeleted;
	}
}
