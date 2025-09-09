#!/usr/bin/rdmd

import std.stdio : write, writef, writeln;
import std.random : Random, unpredictableSeed, uniform;

void main()
{
	enum N = 256;
	ulong[N] gear;

	auto rng = Random(unpredictableSeed);

	bool[ulong] seen;
	ulong[] vals;
	vals.reserve(N);

	while (vals.length < N)
	{
		const v = uniform!ulong(rng);
		if (v in seen)
			continue;
		seen[v] = true;
		vals ~= v;
	}

	gear[] = vals[0 .. N];

	writeln("immutable ulong[256] gear = [");
	foreach (i, v; gear)
	{
		if (i % 4 == 0)
			write("\t");
		writef("0x%016x", v);
		if (i != N - 1)
			write(",");
		if ((i + 1) % 4 == 0 || i == N - 1)
			writeln();
		else
			write(" ");
	}
	writeln("];");
}
