#!/usr/bin/env python3
"""Coverage/connectivity diagnostics, not ground-truth surface or metric accuracy.

Requires numpy/scipy and tools/ply_io.py. Inputs remain read-only.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree
from ply_io import read_ply


def components(points, size=0.06, offset=0.0):
    cells = set(map(tuple, np.floor(points / size + offset).astype(np.int32)))
    remaining = cells.copy()
    sizes = []
    offsets = [(x, y, z) for x in (-1, 0, 1) for y in (-1, 0, 1)
               for z in (-1, 0, 1) if x or y or z]
    while remaining:
        stack = [remaining.pop()]
        count = 0
        while stack:
            p = stack.pop()
            count += 1
            for d in offsets:
                q = (p[0] + d[0], p[1] + d[1], p[2] + d[2])
                if q in remaining:
                    remaining.remove(q)
                    stack.append(q)
        sizes.append(count)
    return cells, {"occupied_cells": len(cells), "components": len(sizes),
                   "components_at_least_10_cells": sum(s >= 10 for s in sizes),
                   "largest_component_cells": max(sizes, default=0)}


def compare(before, after):
    a, _ = read_ply(before)
    b, _ = read_ply(after)
    if not len(a) or not len(b):
        raise ValueError("Both point clouds must contain points")
    da = cKDTree(b).query(a, workers=1)[0]
    db = cKDTree(a).query(b, workers=1)[0]
    report = {"before_points": len(a), "after_points": len(b),
              "before_without_after_within_3cm": int(np.sum(da > 0.03)),
              "after_without_before_within_3cm": int(np.sum(db > 0.03)),
              "before_to_after_distance_p95_cm": float(np.percentile(da, 95) * 100),
              "connectivity_cell_m": 0.06, "connectivity": [],
              "limitations": "Read-only relative coverage; added cells may be noise. 26-neighbor grid connectivity depends on resolution and phase, is not mesh topology, and does not prove hole-free or metric-accurate surfaces."}
    for offset in (0.0, 0.5):
        ca, ra = components(a, offset=offset)
        cb, rb = components(b, offset=offset)
        report["connectivity"].append({"grid_offset_cells": offset, "before": ra, "after": rb,
                                       "retained_before_cell_fraction": len(ca & cb) / len(ca)})
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    report = compare(args.before, args.after)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
