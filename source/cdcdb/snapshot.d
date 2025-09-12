module cdcdb.snapshot;

import cdcdb.dblite;

import zstd : uncompress;

import std.digest.sha : SHA256, digest;
import std.datetime : DateTime;
import std.exception : enforce;

final class Snapshot
{
private:
	DBLite _db;
	DBSnapshot _snapshot;

	const(ubyte)[] getBytes(const ref DBSnapshotChunkData chunk)
	{
		ubyte[] bytes;
		if (chunk.zstd)
		{
			enforce(chunk.zSize == chunk.content.length, "Размер сжатого фрагмента не соответствует ожидаемому");
			bytes = cast(ubyte[]) uncompress(chunk.content);
		}
		else
		{
			bytes = chunk.content.dup;
		}
		enforce(chunk.size == bytes.length, "Оригинальный размер не соответствует ожидаемому");
		enforce(chunk.sha256 == digest!SHA256(bytes), "Хеш-сумма фрагмента не совпадает");

		return bytes;
	}

public:
	this(DBLite dblite, DBSnapshot dbSnapshot)
	{
		_db = dblite;
		_snapshot = dbSnapshot;
	}

	this(DBLite dblite, long idSnapshot)
	{
		_db = dblite;
		_snapshot = _db.getSnapshot(idSnapshot);
	}

	ubyte[] data()
	{
		auto chunks = _db.getChunks(_snapshot.id);
		ubyte[] content;
		content.reserve(_snapshot.sourceLength);

		auto fctx = SHA256();

		foreach (chunk; chunks)
		{
			const(ubyte)[] bytes = getBytes(chunk);
			content ~= bytes;
			fctx.put(bytes);
		}

		enforce(_snapshot.sha256 == fctx.finish(), "Хеш-сумма файла не совпадает");

		return content;
	}

	void data(void delegate(const(ubyte)[]) sink)
	{
		auto chunks = _db.getChunks(_snapshot.id);
		auto fctx = SHA256();

		foreach (chunk; chunks)
		{
			const(ubyte)[] bytes = getBytes(chunk);
			sink(bytes);
			fctx.put(bytes);
		}

		enforce(_snapshot.sha256 == fctx.finish(), "Хеш-сумма файла не совпадает");
	}

	bool remove()
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

		long idDeleted = _db.deleteSnapshot(_snapshot.id);

		ok = true;

		return _snapshot.id == idDeleted;
	}

	@property long id() const nothrow @safe
	{
		return _snapshot.id;
	}

	@property string label() const @safe
	{
		return _snapshot.label;
	}

	@property DateTime created() const @safe
	{
		return _snapshot.createdUtc;
	}

	@property long length() const nothrow @safe
	{
		return _snapshot.sourceLength;
	}

	@property ubyte[32] sha256() const nothrow @safe
	{
		return _snapshot.sha256;
	}

	@property string status() const
	{
		import std.conv : to;

		return _snapshot.status.to!string;
	}

	@property string description() const nothrow @safe
	{
		return _snapshot.description;
	}
}
