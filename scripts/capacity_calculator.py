#!/usr/bin/env python3
"""Estimate metadata engine capacity for billion-scale JuiceFS planning."""

from __future__ import annotations

import argparse
import math


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Estimate metadata engine capacity for JuiceFS."
    )
    parser.add_argument(
        "--engine",
        choices=["tikv", "aerospike"],
        default="tikv",
        help="Metadata engine to estimate.",
    )
    parser.add_argument("--files", type=float, required=True, help="File count, e.g. 10000000000")
    parser.add_argument(
        "--metadata-kib",
        type=float,
        default=1.0,
        help="Logical metadata per file in KiB. Used by TiKV.",
    )
    parser.add_argument("--replicas", type=int, default=3, help="TiKV replica count.")
    parser.add_argument(
        "--headroom",
        type=float,
        default=2.2,
        help="RocksDB/compaction/headroom multiplier.",
    )
    parser.add_argument(
        "--usable-ssd-tib",
        type=float,
        default=3.0,
        help="Safely usable SSD per TiKV node in TiB.",
    )
    parser.add_argument(
        "--records-per-file",
        type=float,
        default=4.0,
        help="Aerospike records per JuiceFS file after metadata modeling.",
    )
    parser.add_argument(
        "--aerospike-rf",
        type=int,
        default=2,
        help="Aerospike namespace replication factor.",
    )
    parser.add_argument(
        "--record-bytes",
        type=float,
        default=512.0,
        help="Average Aerospike record payload bytes before replication.",
    )
    parser.add_argument(
        "--secondary-indexes",
        type=float,
        default=1.0,
        help="Average secondary index entries per Aerospike record.",
    )
    parser.add_argument(
        "--ram-per-node-gib",
        type=float,
        default=192.0,
        help="Safely usable RAM per Aerospike node in GiB for indexes.",
    )
    parser.add_argument(
        "--ssd-per-node-tib",
        type=float,
        default=3.0,
        help="Safely usable SSD per Aerospike node in TiB.",
    )
    return parser.parse_args()


def estimate_tikv(args: argparse.Namespace) -> None:
    logical_tib = args.files * args.metadata_kib / 1024 / 1024 / 1024
    replicated_tib = logical_tib * args.replicas
    raw_tib = replicated_tib * args.headroom
    tikv_nodes = math.ceil(raw_tib / args.usable_ssd_tib)

    print(f"logical_metadata_tib={logical_tib:.2f}")
    print(f"replicated_metadata_tib={replicated_tib:.2f}")
    print(f"raw_ssd_required_tib={raw_tib:.2f}")
    print(f"recommended_tikv_nodes={tikv_nodes}")


def estimate_aerospike(args: argparse.Namespace) -> None:
    records = args.files * args.records_per_file
    primary_index_gib = records * 64 * args.aerospike_rf / 1024 / 1024 / 1024
    secondary_index_gib = (
        records * args.secondary_indexes * 14 * args.aerospike_rf / 1024 / 1024 / 1024
    )
    index_gib = primary_index_gib + secondary_index_gib
    data_tib = records * args.record_bytes * args.aerospike_rf / 1024 / 1024 / 1024 / 1024
    raw_ssd_tib = data_tib * args.headroom
    nodes_by_ram = math.ceil(index_gib / args.ram_per_node_gib)
    nodes_by_ssd = math.ceil(raw_ssd_tib / args.ssd_per_node_tib)
    nodes = max(nodes_by_ram, nodes_by_ssd)

    print(f"metadata_records={records:.0f}")
    print(f"primary_index_gib={primary_index_gib:.2f}")
    print(f"secondary_index_gib={secondary_index_gib:.2f}")
    print(f"total_index_gib={index_gib:.2f}")
    print(f"replicated_record_data_tib={data_tib:.2f}")
    print(f"raw_ssd_required_tib={raw_ssd_tib:.2f}")
    print(f"nodes_by_ram={nodes_by_ram}")
    print(f"nodes_by_ssd={nodes_by_ssd}")
    print(f"recommended_aerospike_nodes={nodes}")


def main() -> None:
    args = parse_args()
    if args.engine == "tikv":
        estimate_tikv(args)
    else:
        estimate_aerospike(args)


if __name__ == "__main__":
    main()
