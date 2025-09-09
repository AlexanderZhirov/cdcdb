module cdcdb.cdc.cas;

import cdcdb.db;
import cdcdb.cdc.core;

final class CAS
{
private:
	DBLite _db;
public:
	this(string database)
	{
		_db = new DBLite(database);
	}

	size_t saveSnapshot(const(ubyte)[] data)
	{
		// Параметры для CDC вынести в отдельные настройки (продумать)
		auto cdc = new CDC(100, 200, 500, 0xFF, 0x0F);
		// Разбить на фрагменты
		auto chunks = cdc.split(data);

		import std.stdio : writeln;

		_db.beginImmediate();
		// Записать фрагменты в БД
		foreach (chunk; chunks)
		{
			writeln(chunk.index);
		}
		_db.commit();
		// Записать манифест в БД
		// Вернуть ID манифеста
		return 0;
	}
}
