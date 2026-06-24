#!/usr/bin/env python3
"""Generate a TiUP topology file from Terraform JSON output."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate TiUP topology YAML.")
    parser.add_argument("--terraform-output", required=True, help="Path to terraform output -json.")
    parser.add_argument("--output", required=True, help="Path to write topology YAML.")
    parser.add_argument("--user", default="tikv", help="SSH user for TiUP.")
    parser.add_argument("--deploy-dir", default="/data/tikv-deploy")
    parser.add_argument("--data-dir", default="/data/tikv-data")
    parser.add_argument("--tikv-capacity", default="3TiB")
    parser.add_argument("--reserve-space", default="200GiB")
    return parser.parse_args()


def output_value(outputs: dict[str, Any], key: str) -> Any:
    value = outputs.get(key)
    if isinstance(value, dict) and "value" in value:
        return value["value"]
    raise KeyError(f"missing Terraform output: {key}")


def zone_name(index: int) -> str:
    return f"az-{chr(ord('a') + index % 3)}"


def render_topology(
    pd_ips: list[str],
    tikv_ips: list[str],
    user: str,
    deploy_dir: str,
    data_dir: str,
    tikv_capacity: str,
    reserve_space: str,
) -> str:
    lines: list[str] = [
        "global:",
        f"  user: {user}",
        "  ssh_port: 22",
        f"  deploy_dir: {deploy_dir}",
        f"  data_dir: {data_dir}",
        "",
        "server_configs:",
        "  pd:",
        '    replication.location-labels: ["zone", "host"]',
        "    replication.max-replicas: 3",
        "  tikv:",
        f"    storage.reserve-space: {reserve_space}",
        f"    raftstore.capacity: {tikv_capacity}",
        "",
        "pd_servers:",
    ]

    for index, ip in enumerate(pd_ips, start=1):
        lines.extend(
            [
                f"  - host: {ip}",
                f"    name: pd-{index}",
                "    client_port: 2379",
                "    peer_port: 2380",
            ]
        )

    lines.append("")
    lines.append("tikv_servers:")
    for index, ip in enumerate(tikv_ips, start=1):
        zero_based = index - 1
        lines.extend(
            [
                f"  - host: {ip}",
                "    port: 20160",
                "    status_port: 20180",
                "    config:",
                "      server.labels:",
                f"        zone: {zone_name(zero_based)}",
                f"        host: tikv-{index}",
            ]
        )

    return "\n".join(lines) + "\n"


def main() -> None:
    args = parse_args()
    outputs = json.loads(Path(args.terraform_output).read_text(encoding="utf-8-sig"))
    pd_ips = output_value(outputs, "pd_private_ips")
    tikv_ips = output_value(outputs, "tikv_private_ips")

    topology = render_topology(
        pd_ips=pd_ips,
        tikv_ips=tikv_ips,
        user=args.user,
        deploy_dir=args.deploy_dir,
        data_dir=args.data_dir,
        tikv_capacity=args.tikv_capacity,
        reserve_space=args.reserve_space,
    )
    Path(args.output).write_text(topology, encoding="utf-8")


if __name__ == "__main__":
    main()
