# JuiceFS Billion Metadata Performance Test Report

Date: 2026-07-01

## Summary

This report records the ad-hoc large-scale JuiceFS small-file write test that was run against the existing four client nodes and the external RustFS S3 endpoint.

The test was stopped manually after reaching about 20.8 million files. The original 100 million file target was not completed because the RustFS S3 endpoint became unavailable for a period and all clients started returning I/O errors. RustFS was later restarted successfully, but the run was intentionally stopped at this point.

## Test Topology

```text
JuiceFS clients:
  vm008, vm009, vm010, vm011

TiKV metadata:
  vm008: PD + TiKV
  vm009: PD + TiKV
  vm010: PD + TiKV

Object storage:
  RustFS S3 endpoint: http://20.78.1.4:9000
  HAProxy backend: vm000, vm001, vm002, vm003
```

JuiceFS metadata used TiKV:

```text
tikv://10.0.0.13:2379,10.0.0.14:2379,10.0.0.15:2379/juicefs-prod
```

JuiceFS objects used RustFS:

```text
http://20.78.1.4:9000/juicefs-prod
```

## Test Parameters

The long-running write test used these effective parameters:

```text
Run ID: scale100m-20260701-134026
Target cumulative files: 100,000,000
Previous files before this run: 5,393,148
Additional target files: 94,606,852
Target files per client: 23,651,713
File size: 1 byte
Workers per client: 64
Files per directory: 100,000
Clients: 4
```

The test wrote real files through the mounted JuiceFS filesystem:

```text
/mnt/juicefs-prod
```

## Final Observed File Count

Final exact count after stopping the writers:

| Node | Test directory host label | Files |
| --- | --- | ---: |
| vm008 | rustfs000009 | 4,045,325 |
| vm009 | rustfs00000A | 3,784,983 |
| vm010 | rustfs000008 | 3,789,412 |
| vm011 | rustfs00000B | 3,805,620 |

Totals:

```text
Files created in this run: 15,425,340
Previous files before this run: 5,393,148
Estimated cumulative files: 20,818,488
Remaining to 100M target: 79,181,512
```

The writers were stopped manually after this point. Their remote result files stayed pending because the workload was interrupted before each node reached its target.

## Throughput

During healthy operation, the observed aggregate write speed was approximately:

```text
1,300 - 1,400 files/s
```

A reasonable planning value for this topology is:

```text
1,350 files/s
```

Estimated full 100 million file runtime at that rate:

```text
100,000,000 / 1,350 = 74,074 seconds
74,074 seconds = 20.6 hours
```

Estimated runtime from the final observed count to 100 million:

```text
79,181,512 / 1,350 = 58,653 seconds
58,653 seconds = 16.3 hours
```

These estimates assume the RustFS S3 endpoint remains healthy and the TiKV/RustFS write path does not degrade.

## Capacity Observations

Final observed JuiceFS logical usage:

```text
/mnt/juicefs-prod: about 80 GiB used
```

Final observed JuiceFS cache usage:

```text
vm008 /data/rustfs2: about 30G used / 271G free
vm009 /data/rustfs2: about 29G used / 272G free
vm010 /data/rustfs2: about 29G used / 272G free
vm011 /data/rustfs2: about 29G used / 272G free
```

Final observed RustFS backend usage on the active 9000 cluster:

```text
vm001: /data/rustfs1..4 about 159G used / 142G free each
vm002: /data/rustfs1..4 about 159G used / 142G free each
vm003: /data/rustfs1..4 about 158-159G used / 142G free each
```

The active RustFS backend was about 53% full at the end of this test.

The payload size was only 1 byte per file, so the backend storage growth is dominated by object, block, metadata, and filesystem overhead rather than user payload.

## TiKV Observations

TiKV remained healthy at the end of the test:

```text
3 PD nodes: Up
3 TiKV nodes: Up
Region count: 92
slow_score: 1
```

Final TiKV store capacity snapshots:

| Store | Capacity | Available | Used size |
| --- | ---: | ---: | ---: |
| 10.0.0.13:20160 | 268GiB | 258.8GiB | 9.163GiB |
| 10.0.0.14:20160 | 268GiB | 257.1GiB | 10.91GiB |
| 10.0.0.15:20160 | 268GiB | 260.4GiB | 7.574GiB |

TiKV did not show slow-store symptoms in the final status sample.

## Incident During The Run

At around 2026-07-01 08:37 UTC, the RustFS services behind HAProxy port 9000 were stopped:

```text
vm000 rustfs.service stopped at 2026-07-01 08:37:38 UTC
vm001 rustfs.service stopped at 2026-07-01 08:38:06 UTC
vm002 rustfs.service stopped at 2026-07-01 08:38:06 UTC
vm003 rustfs.service stopped at 2026-07-01 08:38:06 UTC
```

HAProxy then returned:

```text
HTTP/1.1 503 Service Unavailable
rustfs_endpoint_c1/<NOSRV>
```

The JuiceFS clients reported:

```text
Errno 5 Input/output error
```

RustFS was manually restarted with:

```bash
systemctl start rustfs
```

After restart, HAProxy health and client-side health checks returned HTTP 200:

```text
{"status":"ok","ready":true,"service":"rustfs-endpoint","version":"1.0.0-beta.8"}
```

HAProxy logs also showed `PUT` requests returning `200`, confirming that object writes recovered.

## Performance Characteristics

Observed bottleneck characteristics:

- vm008-vm010 run TiKV, PD, JuiceFS mount, and writers together.
- vm011 only runs JuiceFS mount and writers, so it was much lighter.
- TiKV data disks on vm008-vm010 showed high utilization during healthy write periods.
- JuiceFS cache disks were not the primary bottleneck.
- JuiceFS object writes used `http://20.78.1.4:9000`, a public HAProxy endpoint, not an internal endpoint.

The current topology is good enough to validate tens of millions of tiny files, but it is not ideal for maximum throughput.

## Recommendations

For a cleaner 100M or 1B file test:

1. Use an internal RustFS endpoint instead of `20.78.1.4:9000`.
2. Keep TiKV nodes dedicated; do not run write clients on TiKV nodes.
3. Add dedicated JuiceFS client nodes to increase aggregate write pressure.
4. Add monitoring or restart policy investigation for RustFS; the 9000 backend services were stopped cleanly by systemd.
5. Keep exact file counting infrequent because it scans JuiceFS metadata.
6. Track RustFS backend capacity closely; 1-byte files still create significant object-storage overhead.

## Final Status

```text
Test stopped manually.
Writers stopped on vm008, vm009, vm010, vm011.
RustFS 9000 backend restored and healthy.
TiKV cluster healthy.
Final estimated cumulative file count: 20,818,488.
```
