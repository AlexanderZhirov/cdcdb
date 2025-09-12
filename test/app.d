import std.stdio;

import cdcdb;

import std.file : read, write;
import std.stdio : File, writeln;
import std.conv : to;


void main()
{
	auto storage = new Storage("/tmp/base.db", true, 22);
	storage.newSnapshot("/tmp/text", cast(ubyte[]) read("/tmp/text"));

	// if (snapshot !is null) {
	// 	writeln(cast(string) snapshot.data);
	// 	snapshot.remove();
	// }

	foreach (snapshot; storage.getSnapshots()) {
		auto file = File("/tmp/restore" ~ snapshot.id.to!string, "wb");
		snapshot.data((const(ubyte)[] content) {
			file.rawWrite(content);
		});
		file.close();
	}
}
