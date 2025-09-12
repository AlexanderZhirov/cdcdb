module cdcdb.db.dblite;

import cdcdb.db.types;

import arsd.sqlite;

import std.file : exists;
import std.exception : enforce;
import std.conv : to;
import std.string : join, replace;

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

	// Проверка БД на наличие существующих в ней необходимых таблиц
	void check()
	{
		SqliteResult queryResult = sql(
			q{
				WITH required(name) AS (VALUES ("snapshots"), ("blobs"), ("snapshot_chunks"))
				SELECT name AS missing_table
				FROM required
				WHERE NOT EXISTS (
					SELECT 1
					FROM sqlite_master
					WHERE type = "table" AND name = required.name
				);
			}
		);

		string[] missingTables;

		foreach (row; queryResult)
		{
			missingTables ~= row["missing_table"].to!string;
		}

		enforce(missingTables.length == 0 || missingTables.length == 3,
			"База данных повреждена. Отсутствуют таблицы: " ~ missingTables.join(", ")
		);

		if (missingTables.length == 3)
		{
			foreach (schemeQuery; _scheme)
			{
				sql(schemeQuery);
			}
		}
	}

	DateTime toDateTime(string sqliteDate)
	{
		string isoDate = sqliteDate.replace(" ", "T");
		return DateTime.fromISOExtString(isoDate);
	}

public:
	this(string database)
	{
		_dbPath = database;
		super(database);

		check();

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
			snapshot.label.length ? snapshot.label : null,
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
				INSERT INTO snapshot_chunks (snapshot_id, chunk_index, offset, sha256)
				VALUES(?,?,?,?)
			},
			snapshotChunk.snapshotId,
			snapshotChunk.chunkIndex,
			snapshotChunk.offset,
			snapshotChunk.sha256[]
		);
	}

	bool isLast(string filePath, ubyte[] fileSha256) {
		auto queryResult = sql(
			q{
				SELECT COALESCE(
					(SELECT (file_path = ? AND file_sha256 = ?)
					FROM snapshots
					ORDER BY created_utc DESC
					LIMIT 1),
					0
				) AS is_last;
			}, filePath, fileSha256
		);

		if (!queryResult.empty())
			return queryResult.front()["is_last"].to!long > 0;
		return false;
	}

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

		foreach (row; queryResult)
		{
			Snapshot snapshot;

			snapshot.id = row["id"].to!long;
			snapshot.filePath = row["file_path"].to!string;
			snapshot.fileSha256 = cast(ubyte[]) row["file_sha256"].dup;
			snapshot.label = row["label"].to!string;
			snapshot.createdUtc = toDateTime(row["created_utc"].to!string);
			snapshot.sourceLength = row["source_length"].to!long;
			snapshot.algoMin = row["algo_min"].to!long;
			snapshot.algoNormal = row["algo_normal"].to!long;
			snapshot.algoMax = row["algo_max"].to!long;
			snapshot.maskS = row["mask_s"].to!long;
			snapshot.maskL = row["mask_l"].to!long;
			snapshot.status = cast(SnapshotStatus) row["status"].to!int;

			snapshots ~= snapshot;
		}

		return snapshots;
	}

	Snapshot getSnapshot(long id)
	{
		auto queryResult = sql(
			q{
				SELECT id, file_path, file_sha256, label, created_utc, source_length,
					algo_min, algo_normal, algo_max, mask_s, mask_l, status
				FROM snapshots WHERE id = ?
			}, id
		);

		Snapshot snapshot;

		if (!queryResult.empty())
		{
			auto data = queryResult.front();

			snapshot.id = data["id"].to!long;
			snapshot.filePath = data["file_path"].to!string;
			snapshot.fileSha256 = cast(ubyte[]) data["file_sha256"].dup;
			snapshot.label = data["label"].to!string;
			snapshot.createdUtc = toDateTime(data["created_utc"].to!string);
			snapshot.sourceLength = data["source_length"].to!long;
			snapshot.algoMin = data["algo_min"].to!long;
			snapshot.algoNormal = data["algo_normal"].to!long;
			snapshot.algoMax = data["algo_max"].to!long;
			snapshot.maskS = data["mask_s"].to!long;
			snapshot.maskL = data["mask_l"].to!long;
			snapshot.status = cast(SnapshotStatus) data["status"].to!int;
		}

		return snapshot;
	}

	void deleteSnapshot(long id) {
		sql("DELETE FROM snapshots WHERE id = ?", id);
	}

	SnapshotDataChunk[] getChunks(long snapshotId)
	{
		auto queryResult = sql(
			q{
				SELECT sc.chunk_index, sc.offset,
					b.size, b.content, b.zstd, b.z_size, b.sha256, b.z_sha256
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
