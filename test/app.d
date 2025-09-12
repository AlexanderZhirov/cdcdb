import std.stdio;

import cdcdb;

import std.file : read;

void main()
{
	auto cas = new CAS("/tmp/base.db", true);
	cas.newSnapshot("/tmp/texts", cast(ubyte[]) read("/tmp/text"));
	// import std.stdio : writeln;

	foreach (snapshot; cas.getSnapshots()) {
		writeln(snapshot);
	}

	// writeln(cas.getVersion);
}
