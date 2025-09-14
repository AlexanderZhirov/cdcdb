module cdcdb.storage;

import cdcdb.dblite;
import cdcdb.core;
import cdcdb.snapshot;

import zstd : compress, Level;

/**
 * High-level storage facade: splits data into CDC chunks, stores chunks/blobs
 * into SQLite via `DBLite`, links them into snapshots, and returns `Snapshot`
 * objects for retrieval and deletion.
 *
 * Features:
 * - FastCDC-based content-defined chunking (configurable sizes/masks)
 * - Optional Zstandard compression (level configurable)
 * - Idempotent snapshot creation: skips if identical to the latest for label
 *
 * Typical usage:
 * ---
 * auto store = new Storage("cdc.sqlite", true, Level.default_);
 * store.setupCDC(4096, 8192, 16384, 0x3FFF, 0x03FF);
 *
 * auto snap = store.newSnapshot("my.txt", data, "initial import");
 * auto bytes = snap.data(); // retrieve
 *
 * auto removed = store.removeSnapshots("my.txt"); // remove by label
 * ---
 */
final class Storage
{
private:
	// Database parameters
	DBLite _db;
	bool _zstd;
	int _level;
	// CDC settings
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
		// CDC holds no dynamically allocated state; reinitialization is safe
		_cdc = new CDC(_minSize, _normalSize, _maxSize, _maskS, _maskL);
	}

public:
	/// Construct the storage facade and open (or create) the database.
	///
	/// Params:
	///   database    = path to SQLite file
	///   zstd        = enable Zstandard compression for stored blobs
	///   level       = Zstd compression level (see `zstd.Level`)
	///   busyTimeout = SQLite busy timeout in milliseconds
	///   maxRetries  = max retries on SQLITE_BUSY/LOCKED errors
	this(string database, bool zstd = false, int level = Level.base, size_t busyTimeout = 3000, size_t maxRetries = 3)
	{
		_db = new DBLite(database, busyTimeout, maxRetries);
		_zstd = zstd;
		_level = level;
		initCDC();
	}

	/// Reconfigure CDC parameters (takes effect for subsequent snapshots).
	///
	/// Params:
	///   minSize, normalSize, maxSize, maskS, maskL = FastCDC parameters
	void setupCDC(size_t minSize, size_t normalSize, size_t maxSize, size_t maskS, size_t maskL)
	{
		initCDC(minSize, normalSize, maxSize, maskS, maskL);
	}

	/// Create a new snapshot from raw data.
	///
	/// - Splits data with FastCDC using current settings.
	/// - Optionally compresses chunks with Zstd.
	/// - Stores unique blobs and links them to the created snapshot.
	/// - If the latest snapshot for `label` already has the same file SHA-256,
	///   returns `null` (idempotent).
	///
	/// Params:
	///   label       = user-provided snapshot label (file identifier)
	///   data        = raw file bytes
	///   description = optional human-readable description
	///
	/// Returns: a `Snapshot` instance for the created snapshot, or `null`
	///
	/// Throws:
	///   Exception if `data` is empty or on database/storage errors
	Snapshot newSnapshot(string label, const(ubyte)[] data, string description = string.init)
	{
		if (data.length == 0)
		{
			throw new Exception("Data has zero length");
		}

		import std.digest.sha : SHA256, digest;

		ubyte[32] sha256 = digest!SHA256(data);

		// If the last snapshot for the label matches current content
		if (_db.isLast(label, sha256))
			return null;

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

		_db.addLabel(label);

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

		auto idSnapshot = _db.addSnapshot(dbSnapshot);

		DBSnapshotChunk dbSnapshotChunk;
		DBBlob dbBlob;

		dbBlob.zstd = _zstd;

		// Split into chunks
		Chunk[] chunks = _cdc.split(data);

		// Write chunks to DB
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

			// Store/ensure blob
			_db.addBlob(dbBlob);

			dbSnapshotChunk.snapshotId = idSnapshot;
			dbSnapshotChunk.chunkIndex = chunk.index;
			dbSnapshotChunk.offset = chunk.offset;
			dbSnapshotChunk.sha256 = chunk.sha256;

			// Link chunk to snapshot
			_db.addSnapshotChunk(dbSnapshotChunk);
		}

		ok = true;

		Snapshot snapshot = new Snapshot(_db, idSnapshot);

		return snapshot;
	}

	/// Delete snapshots by label.
	///
	/// Params:
	///   label = snapshot label
	///
	/// Returns: number of deleted snapshots
	long removeSnapshots(string label) {
		return _db.deleteSnapshot(label);
	}

	/// Delete a specific snapshot instance.
	///
	/// Params:
	///   snapshot = `Snapshot` to remove
	///
	/// Returns: `true` on success, `false` otherwise
	bool removeSnapshots(Snapshot snapshot) {
		return removeSnapshots(snapshot.id);
	}

	/// Delete a snapshot by id.
	///
	/// Params:
	///   idSnapshot = snapshot id
	///
	/// Returns: `true` if the row was deleted
	bool removeSnapshots(long idSnapshot) {
		return _db.deleteSnapshot(idSnapshot) == idSnapshot;
	}

	/// Get a `Snapshot` object by id.
	///
	/// Params:
	///   idSnapshot = snapshot id
	///
	/// Returns: `Snapshot` handle (metadata loaded lazily via constructor)
	Snapshot getSnapshot(long idSnapshot) {
		return new Snapshot(_db, idSnapshot);
	}

	/// List snapshots (optionally filtered by label).
	///
	/// Params:
	///   label = filter by exact label; empty string returns all
	///
	/// Returns: array of `Snapshot` handles
	Snapshot[] getSnapshots(string label = string.init) {
		Snapshot[] snapshots;
		
		foreach (snapshot; _db.getSnapshots(label)) {
			snapshots ~= new Snapshot(_db, snapshot);
		}

		return snapshots;
	}

	/// Library version string.
	///
	/// Returns: semantic version of the `cdcdb` library
	string getVersion() const @safe nothrow
	{
		import cdcdb.version_ : cdcdbVersion;

		return cdcdbVersion;
	}
}
