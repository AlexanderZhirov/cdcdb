module cdcdb.db.dblite;

import arsd.sqlite;
import std.file : exists, isFile;

final class DBLite : Sqlite
{
private:
	string _dbPath;
	// _scheme
	mixin(import("scheme.d"));
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

	SqliteResult sql(T...)(string queryText, T args)
	{
		return cast(SqliteResult) query(queryText, args);
	}
}
