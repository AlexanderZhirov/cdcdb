import std.stdio;

import cdcdb;

import std.file : read;

void main()
{
	auto storage = new Storage("/tmp/base.db", true);
	storage.newSnapshot("/tmp/text", cast(ubyte[]) read("/tmp/text"));

	// if (snapshot !is null) {
	// 	writeln(cast(string) snapshot.data);
	// 	snapshot.remove();
	// }

	import std.stdio : writeln;

	foreach (snapshot; storage.getSnapshots()) {
		writeln(cast(string) snapshot.data);
	}

	// writeln(cas.getVersion);
}
