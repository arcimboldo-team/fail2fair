#!/usr/bin/env python3

# Compare two XDS HKL files to identify overlapping reflections based on detector and image distances.

import argparse
import csv
import json
import math
import pathlib
import numpy as np
from scipy.spatial import cKDTree


partial_overlap_dxy = 5.0
partial_overlap_dz = 1.0
complete_overlap_dxy = 1.0
complete_overlap_dz = 0.3
warning_overlap_percent = 10.0


# Check that the input path is valid and identify the HKL file type.
def validate_lattice_path(path):
    lattice_path = pathlib.Path(path)

    if not lattice_path.is_file():
        raise FileNotFoundError(f"The file does not exist: {lattice_path}")

    file_name = lattice_path.name.upper()

    if file_name == "INTEGRATE.HKL":
        return lattice_path.resolve(), "INTEGRATE"

    if file_name == "XDS_ASCII.HKL":
        return lattice_path.resolve(), "XDS_ASCII"

    raise ValueError("The file must be named INTEGRATE.HKL or XDS_ASCII.HKL")


# Read the HKL file and extract only the reflection data needed later.
# Lee el archivo HKL y extrae solo los datos de reflexion necesarios.

def read_reflections(path, file_type):
    reflections = []

    with pathlib.Path(path).open("r", encoding="utf-8", errors="replace") as handle:
        for line_number, line in enumerate(handle, start=1):
            line = line.strip()

            if not line:
                continue

            if line.startswith("!"):
                continue

            parts = line.split()

            try:
                if file_type == "INTEGRATE":
                    if len(parts) < 21:
                        raise ValueError

                    reflection = {
                        "h": int(parts[0]),
                        "k": int(parts[1]),
                        "l": int(parts[2]),
                        "x": float(parts[5]),
                        "y": float(parts[6]),
                        "z": float(parts[7]),
                        "iobs": float(parts[3]),
                        "sigma": float(parts[4]),
                        "peak": float(parts[9]),
                        "corr": float(parts[10]),
                        "iseg": int(parts[20]),
                    }
                else:
                    if len(parts) < 12:
                        raise ValueError

                    reflection = {
                        "h": int(parts[0]),
                        "k": int(parts[1]),
                        "l": int(parts[2]),
                        "x": float(parts[5]),
                        "y": float(parts[6]),
                        "z": float(parts[7]),
                        "iobs": float(parts[3]),
                        "sigma": float(parts[4]),
                        "peak": float(parts[9]),
                        "corr": float(parts[10]),
                        "iseg": None,
                    }
            except ValueError as exc:
                raise ValueError(f"Cannot read reflection line {line_number} in {path}") from exc

            reflections.append(reflection)

    return reflections


# Find the closest valid candidate using Dxy and delta_z as separate values.
# Busca la candidata valida mas cercana usando Dxy y delta_z por separado.
def find_nearest_candidate(reflection1, lattice2, lat2_tree ):
    if lat2_tree is None:
        return None
    
    candidate_indices = lat2_tree.query_ball_point(
        [reflection1["x"], reflection1["y"]],
        r=partial_overlap_dxy,
    )

    if not candidate_indices:
        return None
    
    best_reflection2 = None
    best_deltas = None
    best_dxy = None

    for index in candidate_indices:
        reflection2 = lattice2[index]

        delta_x = abs(reflection1["x"] - reflection2["x"])
        delta_y = abs(reflection1["y"] - reflection2["y"])
        delta_z = abs(reflection1["z"] - reflection2["z"])
        dxy = math.sqrt(delta_x ** 2 + delta_y ** 2)

        if delta_z > partial_overlap_dz:
            continue
        if best_dxy is None or dxy < best_dxy:
            best_dxy = dxy
            best_reflection2 = reflection2
            best_deltas = {
                "delta_x": delta_x,
                "delta_y": delta_y,
                "delta_z": delta_z,
                "dxy": dxy,
            }
    if best_reflection2 is None:
        return None

    return best_reflection2, best_deltas


# Classify the overlap using detector distance and image distance separately.

def classify_overlap(delta_x, delta_y, delta_z):
    dxy = math.sqrt(delta_x ** 2 + delta_y ** 2)

    if dxy <= complete_overlap_dxy and delta_z <= complete_overlap_dz:
        return "complete_overlap", dxy

    if dxy <= partial_overlap_dxy and delta_z <= partial_overlap_dz:
        return "partial_overlap", dxy

    return "no_overlap", dxy


# Write one CSV row for one lattice 1 reflection and its candidate if any.
# Escribe una fila CSV para una reflexion de lattice 1 y su candidata si existe.

def write_overlap_row(writer, reflection1, reflection2, classification, deltas):
    lat1_iseg = reflection1["iseg"] if reflection1["iseg"] is not None else ""

    if reflection2 is None:
        writer.writerow(
            [
                reflection1["h"],
                reflection1["k"],
                reflection1["l"],
                "",
                "",
                "",
                reflection1["x"],
                reflection1["y"],
                reflection1["z"],
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                classification,
                reflection1["iobs"],
                reflection1["sigma"],
                reflection1["peak"],
                reflection1["corr"],
                "",
                "",
                "",
                "",
                lat1_iseg,
                "",
            ]
        )
        return

    lat2_iseg = reflection2["iseg"] if reflection2["iseg"] is not None else ""

    writer.writerow(
        [
            reflection1["h"],
            reflection1["k"],
            reflection1["l"],
            reflection2["h"],
            reflection2["k"],
            reflection2["l"],
            reflection1["x"],
            reflection1["y"],
            reflection1["z"],
            reflection2["x"],
            reflection2["y"],
            reflection2["z"],
            deltas["delta_x"],
            deltas["delta_y"],
            deltas["delta_z"],
            deltas["dxy"],
            classification,
            reflection1["iobs"],
            reflection1["sigma"],
            reflection1["peak"],
            reflection1["corr"],
            reflection2["iobs"],
            reflection2["sigma"],
            reflection2["peak"],
            reflection2["corr"],
            lat1_iseg,
            lat2_iseg,
        ]
    )


# Main comparison workflow: validate, read, compare, write CSV and JSON.

def compare_lattices(lattice1_path, lattice2_path):
    lattice1_path, lattice1_file_type = validate_lattice_path(lattice1_path)
    lattice2_path, lattice2_file_type = validate_lattice_path(lattice2_path)

    if lattice1_file_type != lattice2_file_type:
        raise ValueError("Both files must be the same type: INTEGRATE.HKL or XDS_ASCII.HKL")

    lattice1 = read_reflections(lattice1_path, lattice1_file_type)
    lattice2 = read_reflections(lattice2_path, lattice2_file_type)

    if lattice2:
        lat2_points = np.array([[r["x"], r["y"]] for r in lattice2], dtype=np.float64)
        lat2_tree = cKDTree(lat2_points)
    else:
        lat2_tree = None


    lattice1_total = len(lattice1)
    lattice2_total = len(lattice2)
    no_overlap = 0
    partial_overlap = 0
    complete_overlap = 0

    csv_header = [
        "lat1_h",
        "lat1_k",
        "lat1_l",
        "lat2_h",
        "lat2_k",
        "lat2_l",
        "lat1_x",
        "lat1_y",
        "lat1_z",
        "lat2_x",
        "lat2_y",
        "lat2_z",
        "delta_x",
        "delta_y",
        "delta_z",
        "dxy",
        "classification",
        "lat1_iobs",
        "lat1_sigma",
        "lat1_peak",
        "lat1_corr",
        "lat2_iobs",
        "lat2_sigma",
        "lat2_peak",
        "lat2_corr",
        "lat1_iseg",
        "lat2_iseg",
    ]

    with open("overlap_pairs.csv", "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(csv_header)

        for reflection1 in lattice1:
            nearest = find_nearest_candidate(reflection1, lattice2, lat2_tree)

            if nearest is None:
                reflection2 = None
                deltas = None
                classification = "no_overlap"
            else:
                reflection2, deltas = nearest
                classification, dxy = classify_overlap(
                    deltas["delta_x"],
                    deltas["delta_y"],
                    deltas["delta_z"],
                )
                deltas["dxy"] = dxy

            if classification == "complete_overlap":
                complete_overlap += 1
            elif classification == "partial_overlap":
                partial_overlap += 1
            else:
                no_overlap += 1

            write_overlap_row(writer, reflection1, reflection2, classification, deltas)

    if lattice1_total > 0:
        complete_overlap_percent = complete_overlap / lattice1_total * 100
        partial_overlap_percent = partial_overlap / lattice1_total * 100
        total_overlap_percent = (complete_overlap + partial_overlap) / lattice1_total * 100
    else:
        complete_overlap_percent = 0.0
        partial_overlap_percent = 0.0
        total_overlap_percent = 0.0

    if total_overlap_percent > warning_overlap_percent:
        warning_second_lattice = True
    else:
        warning_second_lattice = False

    summary = {
        "lattice1_total": lattice1_total,
        "lattice2_total": lattice2_total,
        "no_overlap": no_overlap,
        "partial_overlap": partial_overlap,
        "complete_overlap": complete_overlap,
        "complete_overlap_percent": complete_overlap_percent,
        "partial_overlap_percent": partial_overlap_percent,
        "total_overlap_percent": total_overlap_percent,
        "warning_second_lattice": warning_second_lattice,
    }

    with open("summary.json", "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
        handle.write("\n")

    print(f"lattice1_total: {lattice1_total}")
    print(f"lattice2_total: {lattice2_total}")
    print(f"complete_overlap: {complete_overlap}")
    print(f"partial_overlap: {partial_overlap}")
    print(f"total_overlap_percent: {total_overlap_percent:.2f}")
    print(f"warning_second_lattice: {warning_second_lattice}")

    return summary


# Accept either positional paths or --lat1/--lat2, but not both styles mixed.
def parse_args():
    parser = argparse.ArgumentParser(description="Compare overlap between two XDS HKL files.")
    parser.add_argument("paths", nargs="*", help="Positional paths: lattice1_path lattice2_path")
    parser.add_argument("--lat1", help="Path to lattice 1 HKL file")
    parser.add_argument("--lat2", help="Path to lattice 2 HKL file")
    args = parser.parse_args()

    if args.paths and (args.lat1 or args.lat2):
        parser.error("Do not mix positional paths with --lat1/--lat2")

    if args.lat1 or args.lat2:
        if not args.lat1 or not args.lat2:
            parser.error("--lat1 and --lat2 must be used together")
        return args.lat1, args.lat2

    if len(args.paths) != 2:
        parser.error("Use two positional paths or --lat1 PATH --lat2 PATH")

    return args.paths[0], args.paths[1]


if __name__ == "__main__":
    lattice1_path, lattice2_path = parse_args()
    compare_lattices(lattice1_path, lattice2_path)
