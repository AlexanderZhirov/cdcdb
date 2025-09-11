module cdcdb.cdc.core;

import cdcdb.cdc.types;

import std.digest.sha : SHA256, digest;

// Change Data Capture (Захват изменения данных)
final class CDC
{
private:
	size_t _minSize, _normalSize, _maxSize;
	ulong _maskS, _maskL;
	// _gear
	mixin(import("gear.d"));

	size_t cut(const(ubyte)[] src) @safe nothrow
	{
		size_t size = src.length;
		if (size == 0)
			return 0;
		if (size <= _minSize)
			return size;

		if (size > _maxSize)
			size = _maxSize;
		auto normalSize = _normalSize;
		if (size < normalSize)
			normalSize = size;

		ulong fingerprint = 0;
		size_t index;

		// инициализация без cut-check
		while (index < _minSize)
		{
			fingerprint = (fingerprint << 1) + _gear[src[index]];
			++index;
		}
		// строгая маска
		while (index < normalSize)
		{
			fingerprint = (fingerprint << 1) + _gear[src[index]];
			if ((fingerprint & _maskS) == 0)
				return index;
			++index;
		}
		// слабая маска
		while (index < size)
		{
			fingerprint = (fingerprint << 1) + _gear[src[index]];
			if ((fingerprint & _maskL) == 0)
				return index;
			++index;
		}
		return size;
	}

public:
	this(size_t minSize, size_t normalSize, size_t maxSize, ulong maskS, ulong maskL) @safe @nogc nothrow
	{
		assert(minSize > 0 && minSize < normalSize && normalSize < maxSize,
			"Неверные размеры: требуется min < normal < max и min > 0");
		_minSize = minSize;
		_normalSize = normalSize;
		_maxSize = maxSize;
		_maskS = maskS;
		_maskL = maskL;
	}

	Chunk[] split(const(ubyte)[] data) @safe
	{
		Chunk[] chunks;
		if (data.length == 0)
			return chunks;
		chunks.reserve(data.length / _normalSize);
		size_t offset = 0;
		size_t index = 1;

		while (offset < data.length)
		{
			auto size = cut(data[offset .. $]);
			auto bytes = data[offset .. offset + size];
			ubyte[32] hash = digest!SHA256(bytes);
			chunks ~= Chunk(index, offset, size, hash);

			offset += size;
			++index;
		}
		return chunks;
	}
}
