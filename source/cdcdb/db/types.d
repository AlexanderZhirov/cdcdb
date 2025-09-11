module cdcdb.db.types;

import std.datetime : DateTime;

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
	DateTime createdUtc;
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
	ubyte[32] sha256;
	ubyte[32] zSha256;
	long size;
	long zSize;
	ubyte[] content;
	DateTime createdUtc;
	DateTime lastSeenUtc;
	long refcount;
	bool zstd;
}

struct SnapshotChunk
{
	long snapshotId;
	long chunkIndex;
	long offset;
	ubyte[32] sha256;
}

struct SnapshotDataChunk {
	long chunkIndex;
	long offset;
	long size;
	ubyte[] content;
	bool zstd;
	long zSize;
	ubyte[32] sha256;
	ubyte[32] zSha256;
}
