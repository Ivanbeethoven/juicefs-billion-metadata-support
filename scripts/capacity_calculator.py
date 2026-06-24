#!/usr/bin/env python3
"""Estimate TiKV nodes for JuiceFS metadata capacity planning."""

from __future__ import annotations

import argparse
import math


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Estimate TiKV node count for JuiceFS metadata."
    )
    parser.add_argument("--files", type=float, required=True, help="File count, e.g. 10000000000")
    parser.add_argument(
        "--metadata-kib",
        type=float,
        default=1.0,
        help="Logical metadata per file in KiB.",
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
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logical_tib = args.files * args.metadata_kib / 1024 / 1024 / 1024
    replicated_tib = logical_tib * args.replicas
    raw_tib = replicated_tib * args.headroom
    tikv_nodes = math.ceil(raw_tib / args.usable_ssd_tib)

    print(f"logical_metadata_tib={logical_tib:.2f}")
    print(f"replicated_metadata_tib={replicated_tib:.2f}")
    print(f"raw_ssd_required_tib={raw_tib:.2f}")
    print(f"recommended_tikv_nodes={tikv_nodes}")


if __name__ == "__main__":
    main()

