import cdcdb;

import std.file : read, write, remove, exists;
import std.path : buildPath;
import std.digest.sha : digest, SHA256;
import std.exception : assertThrown, assertNotThrown;
import std.datetime : DateTime;
import core.thread : Thread;
import core.time : msecs, seconds;

unittest
{
	const string dbPath = "./bin/test_cdcdb.db";

	if (exists(dbPath)) {
		remove(dbPath);
	}

	// Тест конструктора Storage
	auto storage = new Storage(dbPath, true, 22);

	// Тест настройки CDC
	storage.setupCDC(128, 256, 512, 0xFF, 0x0F);

	// Тест создания снимка
	ubyte[] data1 = cast(ubyte[]) "Hello, World!".dup;
	auto snap1 = storage.newSnapshot("test_label", data1, "First snapshot");
	assert(snap1 !is null);
	assert(snap1.label == "test_label");
	assert(snap1.length == data1.length);
	assert(snap1.sha256 == digest!SHA256(data1));
	assert(snap1.status == "ready");
	assert(snap1.description == "First snapshot");

	// Тест дубликата (не должен создать новый)
	auto snapDup = storage.newSnapshot("test_label", data1);
	assert(snapDup is null);

	// Тест изменения данных
	ubyte[] data2 = cast(ubyte[]) "Hello, Changed World!".dup;
	auto snap2 = storage.newSnapshot("test_label", data2);
	assert(snap2 !is null);
	assert(snap2.sha256 == digest!SHA256(data2));

	// Тест восстановления данных
	auto restored = snap1.data();
	assert(restored == data1);
	bool streamedOk = false;
	snap2.data((const(ubyte)[] chunk) {
		assert(chunk == data2); // Поскольку маленький файл — один фрагмент
		streamedOk = true;
	});
	assert(streamedOk);

	// Тест getSnapshots
	auto snaps = storage.getSnapshots("test_label");
	assert(snaps.length == 2);
	assert(snaps[0].id == snap1.id);
	assert(snaps[1].id == snap2.id);

	auto allSnaps = storage.getSnapshots();
	assert(allSnaps.length == 2);

	// Тест удаления
	assert(snap1.remove());
	snaps = storage.getSnapshots("test_label");
	assert(snaps.length == 1);
	assert(snaps[0].id == snap2.id);

	// Тест пустых данных
	assertThrown!Exception(storage.newSnapshot("empty", []));
}
