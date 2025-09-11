import std.stdio;

import cdcdb;

import std.file : read;

void main()
{
	auto cas = new CAS("/tmp/base.db", true);
	cas.newSnapshot("/tmp/text", "Файл для тестирования", cast(ubyte[]) read("/tmp/text"));
}
