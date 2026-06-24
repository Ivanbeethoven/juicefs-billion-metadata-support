# JuiceFS Aerospike Metadata Engine

This fork adds an experimental JuiceFS metadata driver for Aerospike.

## Status

The driver is suitable for prototype validation, smoke tests, and performance
experiments. It is not production-ready for billion-scale metadata yet.

Current implementation:

- Registers the metadata engine as `aerospike`.
- Uses Aerospike namespace from the URL path.
- Uses `set=metadata` by default unless overridden by query string.
- Stores the original JuiceFS metadata key, value, and version in Aerospike bins.
- Uses a global lock record plus generation/version checks to preserve JuiceFS
  KV transaction semantics in the prototype.

Known limitations:

- Prefix/range scan currently uses namespace scan plus in-process filtering.
  This must be replaced before large-scale use.
- Multi-key metadata operations are conservative and not tuned for high QPS.
- Directory pagination, rename recovery, crash consistency, and fsck workflows
  need dedicated stress tests.
- Secondary index and record schema design are still open production tasks.

## Metadata URL

```bash
aerospike://host1:3000,host2:3000,host3:3000/namespace?set=metadata
```

Example:

```bash
juicefs format \
  --storage s3 \
  --bucket http://rustfs:9000/juicefs-data \
  --access-key "$S3_ACCESS_KEY" \
  --secret-key "$S3_SECRET_KEY" \
  "aerospike://as1:3000,as2:3000,as3:3000/juicefs?set=metadata" \
  juicefs-aerospike
```

Mount:

```bash
juicefs mount \
  "aerospike://as1:3000,as2:3000,as3:3000/juicefs?set=metadata" \
  /mnt/juicefs
```

## Build

```bash
make juicefs
```

For containerized builds:

```bash
docker run --rm \
  -v "$PWD:/src" \
  -v "$HOME/.cache/go-build:/root/.cache/go-build" \
  -v "$HOME/.cache/go-mod:/go/pkg/mod" \
  -w /src \
  golang:1.25-bookworm \
  sh -c 'go test ./pkg/meta -run TestKVClient -count=1 && make juicefs'
```

## Local Smoke Test

Start Aerospike and an S3-compatible object store, then run:

```bash
juicefs format \
  --storage s3 \
  --bucket "$S3_ENDPOINT/$S3_BUCKET" \
  --access-key "$S3_ACCESS_KEY" \
  --secret-key "$S3_SECRET_KEY" \
  "aerospike://aerospike:3000/test?set=metadata" \
  smoke-aerospike

juicefs mount \
  --no-usage-report \
  "aerospike://aerospike:3000/test?set=metadata" \
  /mnt/juicefs

mkdir -p /mnt/juicefs/smoke
echo ok > /mnt/juicefs/smoke/file.txt
cat /mnt/juicefs/smoke/file.txt
juicefs umount /mnt/juicefs
```

## Billion-Scale Work Still Required

Aerospike can store very large record counts, but JuiceFS metadata needs more
than point lookups. Before using this driver at billion scale, implement and
validate:

- Directory-entry records keyed for paged `readdir`.
- Range/prefix scan replacement that does not scan the whole namespace.
- CAS/generation-based multi-record update strategy.
- Idempotent rename/unlink/create recovery.
- Partition-aware background scan for dump, fsck, and cleanup.
- Long-running random metadata tests with concurrent mounts.

## Capacity Notes

Aerospike primary index capacity is roughly:

```text
64 bytes * replication_factor * record_count
```

For a 10-billion-file deployment, model the number of Aerospike records per
file explicitly. For example:

```text
10B files * 4 records/file * 64 bytes * RF=2 ~= 4.66 TiB primary index
```

Secondary indexes and record payloads add more RAM and SSD requirements.
