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
			blob.zSize ? blob.zSha256[] : null,
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

	// Snapshot getSnapshot(long id)
	// {
	// 	auto queryResult = sql(
	// 		q{
	// 			SELECT id, file_path, file_sha256, label, created_utc, source_length,
	// 				algo_min, algo_normal, algo_max, mask_s, mask_l, status
	// 			FROM snapshots WHERE id = ?
	// 		}, id);

	// 	Snapshot s;
	// 	bool found = false;
	// 	foreach (row; queryResult)
	// 	{
	// 		s.id = row[0].to!long;
	// 		s.file_path = row[1].to!string;
	// 		s.label = row[2].to!string;
	// 		s.created_utc = row[3].to!string;
	// 		s.source_length = row[4].to!long;
	// 		s.algo_min = row[5].to!long;
	// 		s.algo_normal = row[6].to!long;
	// 		s.algo_max = row[7].to!long;
	// 		s.mask_s = row[8].to!long;
	// 		s.mask_l = row[9].to!long;
	// 		s.status = cast(SnapshotStatus) row[10].to!int;
	// 		found = true;
	// 		break;
	// 	}
	// 	enforce(found, "getSnapshot: not found");
	// 	return s;
	// }

	// SnapshotChunk[] getSnapshotChunks(long snapshotId)
	// {
	// 	auto r = sql(q{
	// 		SELECT snapshot_id,chunk_index,COALESCE(offset,0),size,sha256
	// 		FROM snapshot_chunks
	// 		WHERE snapshot_id=? ORDER BY chunk_index
	// 	}, snapshotId);

	// 	auto acc = appender!SnapshotChunk[];
	// 	foreach (row; r)
	// 	{
	// 		SnapshotChunk ch;
	// 		ch.snapshot_id = row[0].to!long;
	// 		ch.chunk_index = row[1].to!long;
	// 		ch.offset = row[2].to!long;
	// 		ch.size = row[3].to!long;

	// 		const(ubyte)[] sha = cast(const(ubyte)[]) row[4];
	// 		enforce(sha.length == 32, "getSnapshotChunks: sha256 blob length != 32");
	// 		ch.sha256[] = sha[];

	// 		acc.put(ch);
	// 	}
	// 	return acc.data;
	// }

	// /// Вариант без `out`: вернуть Nullable
	// Nullable!Snapshot maybeGetSnapshotByLabel(string label)
	// {
	// 	auto r = sql(q{
	// 		SELECT id,file_path,label,created_utc,source_length,
	// 			algo_min,algo_normal,algo_max,mask_s,mask_l,status
	// 		FROM snapshots
	// 		WHERE label=? ORDER BY id DESC LIMIT 1
	// 	}, label);

	// 	foreach (row; r)
	// 	{
	// 		Snapshot s;
	// 		s.id = row[0].to!long;
	// 		s.file_path = row[1].to!string;
	// 		s.label = row[2].to!string;
	// 		s.created_utc = row[3].to!string;
	// 		s.source_length = row[4].to!long;
	// 		s.algo_min = row[5].to!long;
	// 		s.algo_normal = row[6].to!long;
	// 		s.algo_max = row[7].to!long;
	// 		s.mask_s = row[8].to!long;
	// 		s.mask_l = row[9].to!long;
	// 		s.status = cast(SnapshotStatus) row[10].to!int;
	// 		return typeof(return)(s); // Nullable!Snapshot(s)
	// 	}
	// 	return typeof(return).init; // null/empty
	// }

	// /// Или жёсткий вариант: вернуть/кинуть
	// Snapshot getSnapshotByLabel(string label)
	// {
	// 	auto m = maybeGetSnapshotByLabel(label);
	// 	enforce(!m.isNull, "getSnapshotByLabel: not found");
	// 	return m.get;
	// }
}
