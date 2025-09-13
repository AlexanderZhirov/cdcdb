module cdcdb.snapshot;

import cdcdb.dblite;

import zstd : uncompress;

import std.digest.sha : SHA256, digest;
import std.datetime : DateTime;
import std.exception : enforce;

/**
 * Snapshot reader and lifecycle helper.
 *
 * This class reconstructs full file content from chunked storage persisted
 * via `DBLite`, verifies integrity (per-chunk SHA-256 and final file hash),
 * and provides a safe way to remove a snapshot record.
 *
 * Usage:
 * ---
 * auto s1 = new Snapshot(db, snapshotId);
 * auto bytes = s1.data(); // materialize full content in memory
 *
 * // or stream into a sink to avoid large allocations:
 * s1.data((const(ubyte)[] part) {
 *     // consume part
 * });
 * ---
 *
 * Notes:
 * - All integrity checks are enforced; any mismatch throws.
 * - `data(void delegate(...))` is preferred for very large files.
 */
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
			enforce(chunk.zSize == chunk.content.length, "Compressed chunk size does not match the expected value");
			bytes = cast(ubyte[]) uncompress(chunk.content);
		}
		else
		{
			bytes = chunk.content.dup;
		}
		enforce(chunk.size == bytes.length, "Original size does not match the expected value");
		enforce(chunk.sha256 == digest!SHA256(bytes), "Chunk hash does not match");

		return bytes;
	}

public:
	/// Construct a `Snapshot` from an already fetched `DBSnapshot` row.
	///
	/// Params:
	///   dblite      = database handle
	///   dbSnapshot  = snapshot row (metadata) previously retrieved
	this(DBLite dblite, DBSnapshot dbSnapshot)
	{
		_db = dblite;
		_snapshot = dbSnapshot;
	}

	/// Construct a `Snapshot` by loading metadata from the database.
	///
	/// Params:
	///   dblite     = database handle
	///   idSnapshot = snapshot id to load
	this(DBLite dblite, long idSnapshot)
	{
		_db = dblite;
		_snapshot = _db.getSnapshot(idSnapshot);
	}

	/// Materialize the full file content in memory.
	///
	/// Reassembles all chunks in order, validates each chunk SHA-256 and the
	/// final file SHA-256 (`snapshots.sha256`).
	///
	/// Returns: full file content as a newly allocated `ubyte[]`
	///
	/// Throws: Exception on any integrity check failure
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

		enforce(_snapshot.sha256 == fctx.finish(), "File hash does not match");

		return content;
	}

	/// Stream the full file content into a caller-provided sink.
	///
	/// This variant avoids allocating a single large buffer. Chunks are
	/// decoded, verified, and passed to `sink` in order.
	///
	/// Params:
	///   sink = delegate invoked for each verified chunk (may be called many times)
	///
	/// Throws: Exception on any integrity check failure
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

		enforce(_snapshot.sha256 == fctx.finish(), "File hash does not match");
	}

	/// Remove this snapshot from the database inside a transaction.
	///
	/// Starts an IMMEDIATE transaction, deletes the snapshot row, and commits.
	/// On any failure it rolls back.
	///
	/// Returns: `true` if the snapshot row was deleted, `false` otherwise
	///
	/// Note: Does not garbage-collect unreferenced blobs; perform that separately.
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

	/// Snapshot id (primary key).
	@property long id() const nothrow @safe
	{
		return _snapshot.id;
	}

	/// User-defined label.
	@property string label() const @safe
	{
		return _snapshot.label;
	}

	/// Creation timestamp (UTC) from the database.
	@property DateTime created() const @safe
	{
		return _snapshot.createdUtc;
	}

	/// Original file length in bytes.
	@property long length() const nothrow @safe
	{
		return _snapshot.sourceLength;
	}

	/// Expected SHA-256 of the full file (32 raw bytes).
	@property ubyte[32] sha256() const nothrow @safe
	{
		return _snapshot.sha256;
	}

	/// Snapshot status as a string (enum to string).
	@property string status() const
	{
		import std.conv : to;

		return _snapshot.status.to!string;
	}

	/// Optional human-readable description.
	@property string description() const nothrow @safe
	{
		return _snapshot.description;
	}
}
