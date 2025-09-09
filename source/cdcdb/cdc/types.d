module cdcdb.cdc.types;

/// Единица разбиения
struct Chunk
{
	size_t index; // 1..N
	size_t offset; // смещение в исходном буфере
	size_t size; // размер чанка
	ubyte[32] sha256; // hex(SHA-256) содержимого
}

/// Метаданные снимка
struct SnapshotInfo
{
	size_t id;
	string createdUTC; // ISO-8601
	string label;
	size_t sourceLength;
	size_t chunks;
}
