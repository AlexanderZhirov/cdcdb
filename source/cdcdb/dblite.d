module cdcdb.dblite;

import arsd.sqlite : Sqlite, SqliteResult, DatabaseException;

import std.datetime : DateTime;
import std.string : join, replace, toLower;
import std.algorithm : canFind;
import std.conv : to;
import std.format : format;
import std.exception : enforce;

enum SnapshotStatus : ubyte
{
	pending = 0,
	ready = 1
}

struct DBSnapshot {
	long id;
	string label;
	ubyte[32] sha256;
	string description;
	DateTime createdUtc;
	long sourceLength;
	long algoMin;
	long algoNormal;
	long algoMax;
	long maskS;
	long maskL;
	SnapshotStatus status;
}

struct DBSnapshotChunk
{
	long snapshotId;
	long chunkIndex;
	long offset;
	ubyte[32] sha256;
}

struct DBBlob
{
	ubyte[32] sha256;
	ubyte[32] zSha256;
	long size;
	long zSize;
	ubyte[] content;
	DateTime createdUtc;
	DateTime lastSeenUtc;
	long refcount;
	bool zstd;
}

struct DBSnapshotChunkData {
	long chunkIndex;
	long offset;
	long size;
	ubyte[] content;
	bool zstd;
	long zSize;
	ubyte[32] sha256;
	ubyte[32] zSha256;
}

final class DBLite : Sqlite
{
private:
	string _dbPath;
	size_t _maxRetries;
	// _scheme
	mixin(import("scheme.d"));

	SqliteResult sql(T...)(string queryText, T args)
	{
		if (_maxRetries == 0) {
			return cast(SqliteResult) query(queryText, args);
		}

		string msg;
		size_t tryNo = _maxRetries;

		while (tryNo) {
			try {
				return cast(SqliteResult) query(queryText, args);
			} catch (DatabaseException e) {
				msg = e.msg;
				if (msg.toLower.canFind("locked", "busy")) {
					if (--tryNo == 0) {
						throw new Exception(
							"Не удалось выполнить подключение к базе данных после %d неудачных попыток: %s"
							.format(_maxRetries, msg)
						);
					}
					continue;
				}
				break;
			}
		}
		throw new Exception(msg);
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
	this(string database, size_t busyTimeout, size_t maxRetries)
	{
		_dbPath = database;
		super(database);

		check();

		_maxRetries = maxRetries;

		query("PRAGMA journal_mode=WAL");
		query("PRAGMA synchronous=NORMAL");
		query("PRAGMA foreign_keys=ON");
		query("PRAGMA busy_timeout=%d".format(busyTimeout));
	}

	void beginImmediate()
	{
		sql("BEGIN IMMEDIATE");
	}

	void commit()
	{
		sql("COMMIT");
	}

	void rollback()
	{
		sql("ROLLBACK");
	}

	bool isLast(string label, ubyte[] sha256) {
		auto queryResult = sql(
			q{
				SELECT COALESCE(
					(SELECT (label = ? AND sha256 = ?)
					FROM snapshots
					ORDER BY created_utc DESC
					LIMIT 1),
					0
				) AS is_last;
			}, label, sha256
		);

		if (!queryResult.empty())
			return queryResult.front()["is_last"].to!long > 0;
		return false;
	}

	long addSnapshot(DBSnapshot snapshot)
	{
		auto queryResult = sql(
			q{
				INSERT INTO snapshots(
					label,
					sha256,
					description,
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
			snapshot.label,
			snapshot.sha256[],
			snapshot.description.length ? snapshot.description : null,
			snapshot.sourceLength,
			snapshot.algoMin,
			snapshot.algoNormal,
			snapshot.algoMax,
			snapshot.maskS,
			snapshot.maskL,
			snapshot.status.to!int
		);

		if (queryResult.empty()) {
			throw new Exception("Ошибка при добавлении нового снимока в базу данных");
		}

		return queryResult.front()["id"].to!long;
	}

	bool addBlob(DBBlob blob)
	{
		auto queryResult = sql(
			q{
				INSERT INTO blobs (sha256, z_sha256, size, z_size, content, zstd)
				VALUES (?,?,?,?,?,?)
				ON CONFLICT (sha256) DO NOTHING
				RETURNING sha256
			},
			blob.sha256[],
			blob.zstd ? blob.zSha256[] : null,
			blob.size,
			blob.zSize,
			blob.content,
			blob.zstd.to!int
		);

		return !queryResult.empty();
	}

	bool addSnapshotChunk(DBSnapshotChunk snapshotChunk)
	{
		auto queryResult = sql(
			q{
				INSERT INTO snapshot_chunks (snapshot_id, chunk_index, offset, sha256)
				VALUES(?,?,?,?)
				RETURNING snapshot_id
			},
			snapshotChunk.snapshotId,
			snapshotChunk.chunkIndex,
			snapshotChunk.offset,
			snapshotChunk.sha256[]
		);

		return !queryResult.empty();
	}

	DBSnapshot getSnapshot(long id)
	{
		auto queryResult = sql(
			q{
				SELECT id, label, sha256, description, created_utc, source_length,
					algo_min, algo_normal, algo_max, mask_s, mask_l, status
				FROM snapshots WHERE id = ?
			}, id
		);

		DBSnapshot snapshot;

		if (!queryResult.empty())
		{
			auto data = queryResult.front();

			snapshot.id = data["id"].to!long;
			snapshot.label = data["label"].to!string;
			snapshot.sha256 = cast(ubyte[]) data["sha256"].dup;
			snapshot.description = data["description"].to!string;
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

	DBSnapshot[] getSnapshots(string label)
	{
		auto queryResult = sql(
			q{
				SELECT id, label, sha256, description, created_utc, source_length,
					algo_min, algo_normal, algo_max, mask_s, mask_l, status
				FROM snapshots WHERE (length(?) = 0 OR label = ?1);
			}, label
		);

		DBSnapshot[] snapshots;

		foreach (row; queryResult)
		{
			DBSnapshot snapshot;

			snapshot.id = row["id"].to!long;
			snapshot.label = row["label"].to!string;
			snapshot.sha256 = cast(ubyte[]) row["sha256"].dup;
			snapshot.description = row["description"].to!string;
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

	DBSnapshotChunkData[] getChunks(long snapshotId)
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

		DBSnapshotChunkData[] sdchs;

		foreach (row; queryResult)
		{
			DBSnapshotChunkData sdch;

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

	long deleteSnapshot(long id) {
		auto queryResult = sql("DELETE FROM snapshots WHERE id = ? RETURNING id", id);

		if (queryResult.empty()) {
			throw new Exception("Ошибка при удалении снимка из базы данных");
		}

		return queryResult.front()["id"].to!long;
	}
}
