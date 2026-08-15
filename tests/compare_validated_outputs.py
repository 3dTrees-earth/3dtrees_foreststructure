#!/usr/bin/env python3
"""Require byte-identical scientific artifacts for a validated dataset run."""

from __future__ import annotations

import argparse
import filecmp
from pathlib import Path


EXCLUDED_SUFFIXES = {
    "_performance.csv",
    "_structure.validation.json",
}


def scientific_artifacts(directory: Path, dataset_id: int) -> dict[str, Path]:
    prefix = str(dataset_id)
    artifacts: dict[str, Path] = {}
    for path in directory.glob(f"{prefix}_*"):
        if not path.is_file():
            continue
        if any(path.name.endswith(suffix) for suffix in EXCLUDED_SUFFIXES):
            continue
        artifacts[path.name] = path
    return artifacts


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset_id", type=int)
    parser.add_argument("baseline_dir", type=Path)
    parser.add_argument("candidate_dir", type=Path)
    args = parser.parse_args()

    baseline = scientific_artifacts(args.baseline_dir, args.dataset_id)
    candidate = scientific_artifacts(args.candidate_dir, args.dataset_id)
    if baseline.keys() != candidate.keys():
        missing = sorted(baseline.keys() - candidate.keys())
        unexpected = sorted(candidate.keys() - baseline.keys())
        raise SystemExit(
            f"artifact set differs; missing={missing}, unexpected={unexpected}"
        )
    if not baseline:
        raise SystemExit("no scientific artifacts found")

    differences = [
        name
        for name in sorted(baseline)
        if not filecmp.cmp(baseline[name], candidate[name], shallow=False)
    ]
    if differences:
        raise SystemExit(f"scientific artifacts differ: {differences}")
    print(
        f"dataset {args.dataset_id}: {len(baseline)} scientific artifacts "
        "are byte-identical"
    )


if __name__ == "__main__":
    main()
