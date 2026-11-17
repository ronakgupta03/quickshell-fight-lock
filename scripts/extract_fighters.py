#!/usr/bin/env python3
"""Extract 24 FPS 2D orthographic fighter skeleton poses from fggreeter's fighters.glb."""

import argparse
import json
import math
import struct
import numpy as np


def read_accessor(data, bin_data, idx):
    acc = data["accessors"][idx]
    bv = data["bufferViews"][acc["bufferView"]]
    offset = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    ctype_map = {
        5120: np.int8,
        5121: np.uint8,
        5122: np.int16,
        5123: np.uint16,
        5125: np.uint32,
        5126: np.float32,
    }
    ncomp_map = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
    arr = np.frombuffer(
        bin_data,
        dtype=ctype_map[acc["componentType"]],
        count=acc["count"] * ncomp_map[acc["type"]],
        offset=offset,
    )
    if ncomp_map[acc["type"]] > 1:
        arr = arr.reshape((acc["count"], ncomp_map[acc["type"]]))
    return arr


def quat_to_mat(q):
    x, y, z, w = q
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 0],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), 0],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), 0],
            [0, 0, 0, 1],
        ],
        dtype=float,
    )


def slerp(q0, q1, t):
    q0 = np.array(q0, dtype=float)
    q1 = np.array(q1, dtype=float)
    q0 /= np.linalg.norm(q0) or 1.0
    q1 /= np.linalg.norm(q1) or 1.0
    dot = float(np.dot(q0, q1))
    if dot < 0.0:
        q1 = -q1
        dot = -dot
    if dot > 0.9995:
        res = q0 + t * (q1 - q0)
        return res / (np.linalg.norm(res) or 1.0)
    theta0 = math.acos(min(1.0, max(-1.0, dot)))
    sin0 = math.sin(theta0)
    theta = theta0 * t
    s0 = math.cos(theta) - dot * math.sin(theta) / sin0
    s1 = math.sin(theta) / sin0
    return s0 * q0 + s1 * q1


def trs(t, r, s):
    mat = quat_to_mat(r) if r is not None else np.eye(4)
    if s is not None:
        mat = mat @ np.diag([s[0], s[1], s[2], 1.0])
    if t is not None:
        mat[:3, 3] = t
    return mat


BONE_SEGS = [
    ("Hips", 0.10),
    ("Spine", 0.10),
    ("Torso", 0.20),
    ("Neck", 0.10),
    ("Arm.L", 0.30),
    ("Forearm.L", 0.3162),
    ("Arm.R", 0.30),
    ("Forearm.R", 0.3162),
    ("Thigh.L", 0.3162),
    ("Leg.L", 0.40),
    ("Foot.L", 0.05),
    ("Thigh.R", 0.3162),
    ("Leg.R", 0.40),
    ("Foot.R", 0.05),
]

KEEP_ANIMS = {
    "Idle",
    "Hit.HighKick",
    "Hit.KneeUpercut",
    "Hit.LowJab",
    "Hit.Smash",
    "Hit.Uppercut",
    "Windup.Classic",
    "Windup.Counter.Classic",
    "Windup.Finisher.Classic",
}


def main():
    parser = argparse.ArgumentParser(description="Extract fighters.glb animations to JSON.")
    parser.add_argument("input", help="Path to fighters.glb")
    parser.add_argument("output", help="Output path for fighters-anims.json")
    parser.add_argument("--fps", type=int, default=24, help="Sample rate (default: 24)")
    args = parser.parse_args()

    with open(args.input, "rb") as f:
        f.read(12)
        clen, _ = struct.unpack("<II", f.read(8))
        data = json.loads(f.read(clen))
        blen, _ = struct.unpack("<II", f.read(8))
        bin_data = f.read(blen)

    nodes = data["nodes"]
    name_to_idx = {}
    for i, n in enumerate(nodes):
        if "name" in n and n["name"] not in name_to_idx:
            name_to_idx[n["name"]] = i

    root_idx = data["scenes"][0]["nodes"][0]

    def eval_world(overrides):
        world = [None] * len(nodes)

        def walk(idx, parent_m):
            n = nodes[idx]
            t = n.get("translation")
            r = n.get("rotation")
            s = n.get("scale")
            if idx in overrides:
                ov = overrides[idx]
                if "translation" in ov:
                    t = ov["translation"]
                if "rotation" in ov:
                    r = ov["rotation"]
                if "scale" in ov:
                    s = ov["scale"]
            m = parent_m @ trs(t, r, s)
            world[idx] = m
            for c in n.get("children", []):
                walk(c, m)

        walk(root_idx, np.eye(4))
        return world

    def sample_anim(anim, time_s):
        overrides = {}
        for ch in anim["channels"]:
            target = ch["target"]
            node_idx = target["node"]
            path = target["path"]
            samp = anim["samplers"][ch["sampler"]]
            times = read_accessor(data, bin_data, samp["input"])
            vals = read_accessor(data, bin_data, samp["output"])
            if len(times) == 1 or time_s <= times[0]:
                val = vals[0]
            elif time_s >= times[-1]:
                val = vals[-1]
            else:
                idx = int(np.searchsorted(times, time_s, side="right")) - 1
                idx = max(0, min(idx, len(times) - 2))
                t0, t1 = float(times[idx]), float(times[idx + 1])
                alpha = (time_s - t0) / (t1 - t0) if t1 > t0 else 0.0
                if path == "rotation":
                    val = slerp(vals[idx], vals[idx + 1], alpha)
                else:
                    val = vals[idx] + alpha * (vals[idx + 1] - vals[idx])
            overrides.setdefault(node_idx, {})[path] = val.tolist()
        return eval_world(overrides)

    def extract_frame(world):
        def extract_fighter(prefix):
            segs = []
            for bname, blen in BONE_SEGS:
                m = world[name_to_idx[prefix + bname]]
                p0 = m[:2, 3]
                up = m[:2, 1]
                p1 = p0 + up * blen
                segs.append([
                    round(float(p0[0]), 4),
                    round(float(p0[1]), 4),
                    round(float(p1[0]), 4),
                    round(float(p1[1]), 4),
                ])
            hm = world[name_to_idx[prefix + "Head"]]
            hc = (hm @ np.array([0.0, 0.17, 0.0, 1.0]))[:2]
            return {"s": segs, "h": [round(float(hc[0]), 4), round(float(hc[1]), 4)]}

        hp_m = world[name_to_idx["HitPoint"]]
        hp_pos = hp_m[:2, 3]
        hp_up = hp_m[:2, 1]
        return {
            "p": extract_fighter("P"),
            "a": extract_fighter("A"),
            "hp": [
                round(float(hp_pos[0]), 4),
                round(float(hp_pos[1]), 4),
                round(float(hp_up[0]), 4),
                round(float(hp_up[1]), 4),
            ],
        }

    out = {"fps": args.fps, "headRadius": 0.2066, "limbRadius": 0.04, "anims": {}}
    for anim in data["animations"]:
        name = anim["name"]
        if name not in KEEP_ANIMS:
            continue
        max_t = max(float(read_accessor(data, bin_data, s["input"]).max()) for s in anim["samplers"])
        n_frames = max(1, int(round(max_t * args.fps)) + 1)
        frames = [
            extract_frame(sample_anim(anim, fi / args.fps if max_t > 0 else 0.0))
            for fi in range(n_frames)
        ]
        out["anims"][name] = frames
        print(f"Extracted {name}: {len(frames)} frames ({max_t:.3f}s)")

    with open(args.output, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("Wrote", args.output)


if __name__ == "__main__":
    main()
