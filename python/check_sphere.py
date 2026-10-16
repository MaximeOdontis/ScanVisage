#!/usr/bin/env python3
"""Validation metrique : ajuste une sphere sur un scan d'objet de diametre connu.

Exemple (balle de ping-pong, 40 mm) :
    python check_sphere.py Scan_XXXX/pose_01.ply --diameter 40
Le fichier doit etre un PLY de l'application (metres). L'objet doit etre l'element le
plus proche de la camera, a 30 a 40 cm, tenu par un support fin et sans reflet.
"""
import argparse
from pathlib import Path

import numpy as np
import open3d as o3d


def fit_sphere(P):
    A = np.c_[2 * P, np.ones(len(P))]
    b = (P ** 2).sum(axis=1)
    x, *_ = np.linalg.lstsq(A, b, rcond=None)
    c = x[:3]
    r = np.sqrt(x[3] + c @ c)
    return c, r


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ply", type=Path)
    ap.add_argument("--diameter", type=float, required=True, help="diametre reel en mm")
    ap.add_argument("--units", choices=["m", "mm"], default="m", help="unite du PLY (m pour l'application)")
    args = ap.parse_args()

    pts = np.asarray(o3d.io.read_point_cloud(str(args.ply)).points, dtype=np.float64)
    if args.units == "m":
        pts *= 1000.0

    zmin = np.percentile(pts[:, 2], 1)
    near = pts[pts[:, 2] < zmin + 10.0]
    c0 = near.mean(axis=0)
    c0[2] += args.diameter / 2.0
    P = pts[np.linalg.norm(pts - c0, axis=1) < args.diameter * 0.7]
    if len(P) < 200:
        raise SystemExit("Trop peu de points sur l'objet. Rapprochez-le et centrez-le.")

    for _ in range(4):  # ajustement avec rejet iteratif des points aberrants
        c, r = fit_sphere(P)
        res = np.linalg.norm(P - c, axis=1) - r
        keep = np.abs(res) < 2.0
        if keep.sum() < 100:
            break
        P = P[keep]
    c, r = fit_sphere(P)
    res = np.linalg.norm(P - c, axis=1) - r

    diam = 2 * r
    print(f"Points utilises       : {len(P)}")
    print(f"Diametre ajuste       : {diam:.2f} mm (reel : {args.diameter:.2f} mm)")
    print(f"Erreur de diametre    : {diam - args.diameter:+.2f} mm")
    print(f"Residu RMS (forme)    : {np.sqrt((res ** 2).mean()):.2f} mm")
    print("Repeter sur plusieurs distances et poses : une seule mesure ne valide rien.")


if __name__ == "__main__":
    main()
