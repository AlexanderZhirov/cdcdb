module cdcdb.cdc.cas;

import cdcdb.db;
import cdcdb.cdc.core;

import std.digest.sha : SHA256, digest;
import std.format : format;

// CAS-хранилище (Content-Addressable Storage) со снапшотами
final class CAS
{
private:
	DBLite _db;
public:
	this(string database)
	{
		_db = new DBLite(database);
	}

	size_t saveSnapshot(string filePath, const(ubyte)[] data)
	{
		ubyte[32] hashSource = digest!SHA256(data);
		// Сделать запрос в БД по filePath и сверить хеш файлов
		


		// Параметры для CDC вынести в отдельные настройки (продумать)
		auto cdc = new CDC(100, 200, 500, 0xFF, 0x0F);
		// Разбить на фрагменты
		auto chunks = cdc.split(data);

		import std.stdio : writeln;

		_db.beginImmediate();
		// Записать фрагменты в БД
		foreach (chunk; chunks)
		{
			writeln(format("%(%02x%)", chunk.sha256));
		}
		_db.commit();
		// Записать манифест в БД
		// Вернуть ID манифеста
		return 0;
	}
}
