module cdcdb.db.types;

enum SnapshotStatus : int
{
	pending = 0,
	ready = 1
}

struct Snapshot
{
	long id;
	string filePath;
	ubyte[32] fileSha256;
	string label;
	string createdUtc;
	long sourceLength;
	long algoMin;
	long algoNormal;
	long algoMax;
	long maskS;
	long maskL;
	SnapshotStatus status;
}

struct Blob
{
	ubyte[32] sha256; // BLOB(32)
	ubyte[32] zSha256; // BLOB(32)
	long size;
	long zSize;
	ubyte[] content; // BLOB
	string createdUtc;
	string lastSeenUtc;
	long refcount;
	bool zstd;
}

struct SnapshotChunk
{
	long snapshotId;
	long chunkIndex;
	long offset;
	long size;
	ubyte[32] sha256; // BLOB(32)
}
