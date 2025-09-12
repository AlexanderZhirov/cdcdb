# cdcdb

A library for storing and managing snapshots of textual data in an SQLite database. It uses content-defined chunking (CDC) based on the FastCDC algorithm to split data into variable-size chunks for efficient deduplication. Supports optional Zstd compression, transactions, and end-to-end integrity verification via SHA-256. Primary use cases: backups and versioning of text files while minimizing storage footprint.

## FastCDC algorithm
FastCDC splits data into variable-size chunks using content hashing. A Gear table is used to compute rolling “fingerprints” and choose cut points while respecting minimum, target, and maximum chunk sizes. This efficiently detects changes and stores only unique chunks, reducing storage usage.

## Core classes

### Storage
High-level API for the SQLite store and snapshot management.

- **Constructor**: Initializes a connection to SQLite.
- **Methods**:
  - `newSnapshot`: Creates a snapshot. Returns a `Snapshot` object or `null` if the data matches the latest snapshot.
  - `getSnapshots`: Returns a list of snapshots (all, or filtered by label). Returns an array of `Snapshot`.
  - `getSnapshot`: Fetches a snapshot by ID. Returns a `Snapshot`.
  - `setupCDC`: Configures CDC splitting parameters. Returns nothing.
  - `getVersion`: Returns the library version string (e.g., `"0.0.2"`).
  - `removeSnapshots`: Deletes snapshots by label, ID, or a `Snapshot` object. Returns the number of deleted snapshots (for label) or `true`/`false` (for ID or object).

### Snapshot
Work with an individual snapshot.

- **Constructor**: Creates a snapshot handle by its ID.
- **Methods**:
  - `data`: Restores full snapshot data. Returns a byte array (`ubyte[]`).
  - `data`: Streams restored data via a delegate sink. Returns nothing.
  - `remove`: Deletes the snapshot from the database. Returns `true` on success, otherwise `false`.

- **Properties**:
  - `id`: Snapshot ID (`long`).
  - `label`: Snapshot label (`string`).
  - `created`: Creation timestamp (UTC, `DateTime`).
  - `length`: Original data length (`long`).
  - `sha256`: Data SHA-256 hash (`ubyte[32]`).
  - `status`: Snapshot status (`"pending"` or `"ready"`).
  - `description`: Snapshot description (`string`).

## Example
```d
import cdcdb;

import std.stdio : writeln, File;
import std.file : exists, remove;

void main()
{
	// Create DB
	string dbPath = "example.db";

	// Initialize Storage with Zstd compression
	auto storage = new Storage(dbPath, true, 22);

	// Create a snapshot
	ubyte[] data = cast(ubyte[]) "Hello, cdcdb!".dup;
	auto snap = storage.newSnapshot("example_file", data, "Version 1.0");
	if (snap)
	{
		writeln("Snapshot created: ID=", snap.id, ", Label=", snap.label);
	}

	// Restore data
	auto snapshots = storage.getSnapshots("example_file");
	if (snapshots.length > 0)
	{
		auto lastSnap = snapshots[0];
		File outFile = File("restored.txt", "wb");
		lastSnap.data((const(ubyte)[] chunk) => outFile.rawWrite(chunk));
		outFile.close();
		writeln("Data restored to restored.txt");
	}

	// Delete snapshots
	long deleted = storage.removeSnapshots("example_file");
	writeln("Deleted snapshots: ", deleted);
}
```

## Tools

The `tools` directory contains a small D script for generating a Gear table used by FastCDC. It lets you build custom hash tables to tune splitting behavior. To generate a new table:

```bash
chmod +x ./tools/gen.d
./tools/gen.d > ./source/gear.d
```

## Installation

* **In `dub.json`**:

	```json
	"dependencies": {
		"cdcdb": "~>0.1.0"
	}
	```
* **Build**: `dub build`.

## License

Boost Software License 1.0 (BSL-1.0).
