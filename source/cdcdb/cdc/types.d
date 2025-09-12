module cdcdb.cdc.types;

// Единица разбиения
struct Chunk
{
	size_t index; // 1..N
	size_t offset; // смещение в исходном буфере
	size_t size; // размер чанка
	immutable(ubyte)[32] sha256; // hex(SHA-256) содержимого
}
