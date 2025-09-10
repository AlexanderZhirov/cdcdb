module cdcdb.db.dblite;

import arsd.sqlite;
import std.file : exists, isFile;
import std.exception : enforce;
import std.conv : to;

import cdcdb.db.types;

final class DBLite : Sqlite
{
private:
	string _dbPath;
	// _scheme
	mixin(import("scheme.d"));

	SqliteResult sql(T...)(string queryText, T args)
	{
		return cast(SqliteResult) query(queryText, args);
	}
public:
	this(string database)
	{
		_dbPath = database;
		super(database);

		foreach (schemeQuery; _scheme)
		{
			sql(schemeQuery);
		}

		query("PRAGMA journal_mode=WAL");
		query("PRAGMA synchronous=NORMAL");
		query("PRAGMA foreign_keys=ON");
	}

	void beginImmediate()
	{
		query("BEGIN IMMEDIATE");
	}

	void commit()
	{
		query("COMMIT");
	}

	void rollback()
	{
		query("ROLLBACK");
	}

	// Snapshot getSnapshot(string filePath, immutable ubyte[32] sha256)
	// {
	// 	auto queryResult = sql(
	// 		q{
	// 			SELECT * FROM snapshots
	// 			WHERE file_path = ? AND file_sha256 = ?
	// 		}, filePath, sha256
	// 	);
	// }

	long addSnapshot(Snapshot snapshot)
	{
		auto queryResult = sql(
			q{
				INSERT INTO snapshots(
					file_path,
					file_sha256,
					label,
					source_length,
					algo_min,
					algo_normal,
					algo_max,
					mask_s,
					mask_l,
					status
				) VALUES (?,?,?,?,?,?,?,?,?,?)
				RETURNING id
			},
			snapshot.filePath,
			snapshot.fileSha256[],
			snapshot.label,
			snapshot.sourceLength,
			snapshot.algoMin,
			snapshot.algoNormal,
			snapshot.algoMax,
			snapshot.maskS,
			snapshot.maskL,
			snapshot.status.to!int
		);

		if (!queryResult.empty())
			return queryResult.front()["id"].to!long;
		return 0;
	}

	void addBlob(Blob blob)
	{
		sql(
			q{
				INSERT INTO blobs (sha256, z_sha256, size, z_size, content, zstd)
				VALUES (?,?,?,?,?,?)
				ON CONFLICT (sha256) DO NOTHING
			},
			blob.sha256[],
			blob.zstd ? blob.zSha256[] : null,
			blob.size,
			blob.zSize,
			blob.content,
			blob.zstd.to!int
		);
	}

	void addSnapshotChunk(SnapshotChunk snapshotChunk)
	{
		sql(
			q{
				INSERT INTO snapshot_chunks (snapshot_id, chunk_index, offset, size, sha256)
				VALUES(?,?,?,?,?)
			},
			snapshotChunk.snapshotId,
			snapshotChunk.chunkIndex,
			snapshotChunk.offset,
			snapshotChunk.size,
			snapshotChunk.sha256[]
		);
	}

	// struct ChunkInput
	// {
	// 	long index;
	// 	long offset;
	// 	long size;
	// 	ubyte[32] sha256;
	// 	const(ubyte)[] content;
	// }

	// long saveSnapshotWithChunks(
	// 	string filePath, string label, long sourceLength,
	// 	long algoMin, long algoNormal, long algoMax,
	// 	long maskS, long maskL,
	// 	const ChunkInput[] chunks
	// )
	// {
	// 	beginImmediate();

	// 	bool ok;

	// 	scope (exit)
	// 	{
	// 		if (!ok)
	// 			rollback();
	// 	}
	// 	scope (success)
	// 	{
	// 		commit();
	// 	}

	// 	const snapId = insertSnapshotMeta(
	// 		filePath, label, sourceLength,
	// 		algoMin, algoNormal, algoMax,
	// 		maskS, maskL, SnapshotStatus.pending
	// 	);

	// 	foreach (c; chunks)
	// 	{
	// 		insertBlobIfMissing(c.sha256, c.size, c.content);
	// 		insertSnapshotChunk(snapId, c.index, c.offset, c.size, c.sha256);
	// 	}

	// 	ok = true;

	// 	return snapId;
	// }













	// // --- чтение ---

	Snapshot[] getSnapshots(string filePath)
	{
		auto queryResult = sql(
			q{
				SELECT id, file_path, file_sha256, label, created_utc, source_length,
					algo_min, algo_normal, algo_max, mask_s, mask_l, status
				FROM snapshots WHERE file_path = ?
			}, filePath
		);

		Snapshot[] snapshots;
		// bool found = false;
		foreach (row; queryResult)
		{
			Snapshot snapshot;

			snapshot.id = row["id"].to!long;
			snapshot.filePath = row["file_path"].to!string;
			snapshot.fileSha256 = cast(ubyte[]) row["file_sha256"].dup;
			snapshot.label = row["label"].to!string;
			snapshot.createdUtc = row["created_utc"].to!string;
			snapshot.sourceLength = row["source_length"].to!long;
			snapshot.algoMin = row["algo_min"].to!long;
			snapshot.algoNormal = row["algo_normal"].to!long;
			snapshot.algoMax = row["algo_max"].to!long;
			snapshot.maskS = row["mask_s"].to!long;
			snapshot.maskL = row["mask_l"].to!long;
			snapshot.status = cast(SnapshotStatus)row["status"].to!int;
			// found = true;
			snapshots ~= snapshot;
		}
		// enforce(found, "getSnapshot: not found");
		return snapshots;
	}

	SnapshotDataChunk[] getChunks(long snapshotId) {
		auto queryResult = sql(
			q{
				SELECT sc.chunk_index, sc.offset, sc.size,
					b.content, b.zstd, b.z_size, b.sha256, b.z_sha256
				FROM snapshot_chunks sc
				JOIN blobs b ON b.sha256 = sc.sha256
				WHERE sc.snapshot_id = ?
				ORDER BY sc.chunk_index
			}, snapshotId
		);

		SnapshotDataChunk[] sdchs;

		foreach (row; queryResult)
		{
			SnapshotDataChunk sdch;

			sdch.chunkIndex = row["chunk_index"].to!long;
			sdch.offset = row["offset"].to!long;
			sdch.size = row["size"].to!long;
			sdch.content = cast(ubyte[]) row["content"].dup;
			sdch.zstd = cast(bool) row["zstd"].to!int;
			sdch.zSize = row["z_size"].to!long;
			sdch.sha256 = cast(ubyte[]) row["sha256"].dup;
			sdch.zSha256 = cast(ubyte[]) row["z_sha256"].dup;

			sdchs ~= sdch;
		}

		return sdchs;
	}
}
