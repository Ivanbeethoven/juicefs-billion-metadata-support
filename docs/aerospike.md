# Aerospike Metadata Option

## Positioning

Aerospike is a candidate metadata engine for a high-QPS, point-lookup-heavy
JuiceFS deployment. It is not a drop-in replacement for the official TiKV
metadata path unless the JuiceFS Aerospike metadata driver is implemented and
validated for production.

Use Aerospike as an R&D or production-hardening track when the target workload
has these properties:

- Very high `stat`, `getattr`, `open`, and small metadata update QPS.
- Clear willingness to design a JuiceFS-specific key schema.
- Operational preference for a low-latency, SSD-backed, distributed KV store.
- Metadata access dominated by point lookups rather than deep directory scans.

Keep TiKV as the correctness-first baseline. TiKV already provides distributed
transactions and ordered range scans that match JuiceFS metadata semantics more
directly.

## Why Aerospike Is Attractive

Aerospike keeps the primary index available for low-latency key access and
spreads records across 4096 partitions. Its capacity model is simple: each
record has a 64-byte primary-index metadata cost, multiplied by replication
factor and record count.

For 10 billion JuiceFS files, the Aerospike record count depends on the metadata
layout. A practical model may use several records per file, for example inode
attribute, parent entry, chunk metadata, and optional directory/stat records.

Example with 4 records per file and RF=2:

```text
10B files * 4 records/file = 40B Aerospike records
40B records * 64 bytes * RF=2 ~= 4.66 TiB primary index
```

This primary index budget is the first sizing constraint. Secondary indexes and
record payload storage add more RAM and SSD requirements.

## Required Driver Design

The experimental driver must not use full-namespace scans for JuiceFS prefix
operations. Billion-scale metadata requires an explicit schema for each access
pattern:

| JuiceFS access pattern | Aerospike design requirement |
| --- | --- |
| inode lookup | Direct record key lookup |
| dentry lookup | Direct key by parent inode + name |
| readdir | Ordered or paged directory index records |
| chunk lookup | Direct key by inode + chunk index |
| rename/link/unlink | CAS/generation checks plus rollback or repair plan |
| fsck/dump/scan | Partition-aware background scans with throttling |

Aerospike secondary indexes can help selected query paths, but they should be
used deliberately because each secondary index entry has additional memory cost.

## Suggested Production Starting Point

For a 10B-file design target, start sizing at:

```text
12-24 Aerospike nodes for a constrained PoC
24-48 Aerospike nodes for production-like validation
48+ nodes for high-QPS production or larger record-per-file layouts
```

Per node starting profile:

```text
32-64 vCPU
192-384 GiB RAM
3.84/7.68 TB NVMe
25/100 GbE
RF=2 or RF=3 depending on durability requirements
```

The exact count should be derived from:

```text
records = files * records_per_file
primary_index = records * 64 bytes * replication_factor
secondary_index = records * secondary_index_entries * 14 bytes * replication_factor
data = records * average_record_payload * replication_factor
```

Run:

```bash
python scripts/capacity_calculator.py \
  --engine aerospike \
  --files 10000000000 \
  --records-per-file 4 \
  --aerospike-rf 2 \
  --record-bytes 512 \
  --secondary-indexes 1 \
  --ram-per-node-gib 192 \
  --ssd-per-node-tib 3
```

## JuiceFS Format Shape

The final metadata URL shape depends on the driver implementation. A practical
prototype can use:

```bash
export META_URL="aerospike://as1:3000,as2:3000,as3:3000/juicefs?set=metadata"

juicefs format \
  --storage s3 \
  --bucket "${RUSTFS_ENDPOINT}/${RUSTFS_BUCKET}" \
  --access-key "$RUSTFS_ACCESS_KEY" \
  --secret-key "$RUSTFS_SECRET_KEY" \
  "$META_URL" \
  juicefs-prod
```

## Main Risks

| Risk | Mitigation |
| --- | --- |
| Full scans in metadata path | Design directory and prefix indexes before scale testing |
| Multi-key transaction gaps | Use generation checks, idempotent writes, and repair workflows |
| Secondary index memory blow-up | Keep indexes minimal and model memory before deployment |
| Large-directory hotspots | Directory sharding and paged directory index records |
| Cold restart and index rebuild behavior | Prefer production settings that meet restart SLOs |
| Driver maturity | Run random metadata tests, crash tests, fio, mdtest, and fsck loops |

## Recommendation

Aerospike is the most promising non-TiKV option for a lower-latency metadata
engine, but only after driver hardening. Treat it as:

```text
Performance exploration path: Aerospike
Correctness-first production path: TiKV
```
