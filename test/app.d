import std.stdio;

import cdcdb;

import std.file : read;

void main()
{
	auto cas = new CAS("/tmp/base.db", true);
	cas.newSnapshot("/tmp/text", cast(ubyte[]) read("/tmp/text"));
	// import std.stdio : writeln;

	writeln(cas.getSnapshotList("/tmp/text"));

	// writeln(cas.getVersion);
}
