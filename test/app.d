import std.stdio;

import cdcdb;

import std.file : read;

void main()
{
	auto cas = new CAS("/tmp/base.db");
	cas.saveSnapshot(cast(ubyte[]) read("/tmp/text"));
}
