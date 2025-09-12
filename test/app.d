import cdcdb;
import std.stdio : writeln, File;
import std.file : exists, remove, read;
import zstd : Level;

void main()
{
	// Создаем временную базу для примера
	string dbPath = "./bin/example.db";

	// Инициализация Storage с компрессией Zstd
	auto storage = new Storage(dbPath, true, Level.speed);

	// Настройка параметров CDC (опционально)
	storage.setupCDC(256, 512, 1024, 0xFF, 0x0F);

	// Тестовые данные
	ubyte[] data1 = cast(ubyte[]) "Hello, cdcdb!".dup;
	ubyte[] data2 = cast(ubyte[]) "Hello, updated cdcdb!".dup;

	// Создание первого снимка
	auto snap1 = storage.newSnapshot("example_file", data1, "Версия 1.0");
	if (snap1)
	{
		writeln("Создан снимок с ID: ", snap1.id);
		writeln("Метка: ", snap1.label);
		writeln("Размер: ", snap1.length, " байт");
		writeln("Статус: ", snap1.status);
	}

	// Создание второго снимка (обновление)
	auto snap2 = storage.newSnapshot("example_file", data2, "Версия 2.0");
	if (snap2)
	{
		writeln("Создан обновленный снимок с ID: ", snap2.id);
	}

	// Получение всех снимков по метке
	auto snapshots = storage.getSnapshots("example_file");
	writeln("Найдено снимков: ", snapshots.length);

	// Восстановление данных из последнего снимка (потоково, для экономии памяти)
	if (snapshots.length > 0)
	{
		auto lastSnap = snapshots[$ - 1]; // Последний снимок
		File outFile = File("./bin/restored.txt", "wb");
		lastSnap.data((const(ubyte)[] chunk) { outFile.rawWrite(chunk); });
		outFile.close();
		writeln("Данные восстановлены в restored.txt");

		// Проверка хэша (опционально)
		import std.digest.sha : digest, SHA256;

		auto restoredData = cast(ubyte[]) read("./bin/restored.txt");
		assert(restoredData == data2);
		writeln("Хэш совпадает: ", lastSnap.sha256 == digest!SHA256(restoredData));
	}

	// Удаление снимков по метке
	long deleted = storage.removeSnapshots("example_file");
	writeln("Удалено снимков: ", deleted);

	// Проверка: снимки удалены
	auto remaining = storage.getSnapshots("example_file");
	assert(remaining.length == 0);
	writeln("Все снимки удалены.");

	writeln("Версия библиотеки: ", storage.getVersion());
}
