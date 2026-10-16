#!/usr/bin/env python3
"""Reconstruction d'un maillage STL de visage a partir d'un scan ScanVisage.

Entree : dossier contenant pose_01.ply, pose_01.json, pose_02.ply, ... (nuages en metres,
repere camera : X droite, Y bas, Z devant).
Etapes : crop du visage, recalage en chaine (RANSAC/FPFH + candidats de rotation + ICP
point-a-plan), fusion, reconstruction de Poisson, export STL en millimetres.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
import open3d as o3d

reg = o3d.pipelines.registration

# Pose enfant -> pose parente (le recalage se fait de proche en proche)
PARENTS = {
    "face": None,
    "gauche_30": "face",
    "gauche_60": "gauche_30",
    "droite_30": "face",
    "droite_60": "droite_30",
    # sequence guidee (version ARKit) : chaque pose est recalee sur la face
    "profil_droit": "face",
    "profil_gauche": "face",
    "dessous": "face",
    "dessus": "face",
    "droite": "face",
    "gauche": "face",
    "haut": "face",
    "bas": "face",
}
NOMINAL_STEP_DEG = 30.0


def rot_axis(axis, deg):
    a = np.deg2rad(deg)
    c, s = np.cos(a), np.sin(a)
    if axis == 0:
        R = [[1, 0, 0], [0, c, -s], [0, s, c]]
    elif axis == 1:
        R = [[c, 0, s], [0, 1, 0], [-s, 0, c]]
    else:
        R = [[c, -s, 0], [s, c, 0], [0, 0, 1]]
    T = np.eye(4)
    T[:3, :3] = np.array(R)
    return T


def about_point(T, c):
    A = np.eye(4)
    A[:3, 3] = c
    B = np.eye(4)
    B[:3, 3] = -c
    return A @ T @ B


def sensor_from_face(meta):
    """Pose visage -> capteur enregistree par l'app (version ARKit), translation en mm."""
    sf = meta.get("sensorFromFace")
    if not sf or len(sf) != 12:
        return None
    S = np.eye(4)
    S[:3, :4] = np.asarray(sf, dtype=np.float64).reshape(3, 4)
    S[:3, 3] *= 1000.0
    return S


def pose_init(src_pose, dst_pose, mirror_x):
    """Initialisation src -> dst deduite des poses ARKit, si disponibles."""
    if mirror_x:
        return None
    a = sensor_from_face(src_pose.get("meta", {}))
    b = sensor_from_face(dst_pose.get("meta", {}))
    if a is None or b is None:
        return None
    return b @ np.linalg.inv(a)


def load_poses(folder, mirror_x):
    poses = []
    for ply in sorted(folder.glob("pose_*.ply")):
        meta_path = ply.with_suffix(".json")
        meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
        pcd = o3d.io.read_point_cloud(str(ply))
        pts = np.asarray(pcd.points, dtype=np.float64) * 1000.0  # m -> mm
        if mirror_x:
            pts[:, 0] *= -1.0
        pcd.points = o3d.utility.Vector3dVector(pts)
        poses.append({"label": meta.get("label", ply.stem), "file": ply.name, "pcd": pcd, "meta": meta})
    return poses


def crop_face(pcd, radius):
    pts = np.asarray(pcd.points)
    zmin = np.percentile(pts[:, 2], 1)
    near = pts[pts[:, 2] < zmin + 50.0]
    center = near.mean(axis=0) + np.array([0.0, 0.0, 45.0])
    d = np.linalg.norm(pts - center, axis=1)
    return pcd.select_by_index(np.where(d < radius)[0])


def preprocess(pcd, radius):
    pcd = crop_face(pcd, radius)
    pcd, _ = pcd.remove_statistical_outlier(nb_neighbors=30, std_ratio=2.0)
    pcd.estimate_normals(o3d.geometry.KDTreeSearchParamHybrid(radius=6.0, max_nn=40))
    pcd.orient_normals_towards_camera_location(np.zeros(3))
    return pcd


def fpfh(pcd, voxel):
    down = pcd.voxel_down_sample(voxel)
    down.estimate_normals(o3d.geometry.KDTreeSearchParamHybrid(radius=voxel * 2, max_nn=30))
    feat = reg.compute_fpfh_feature(
        down, o3d.geometry.KDTreeSearchParamHybrid(radius=voxel * 5, max_nn=100)
    )
    return down, feat


def icp_refine(src, dst, init):
    T = init
    res = None
    for thr in (12.0, 6.0, 3.0):
        res = reg.registration_icp(
            src, dst, thr, T,
            reg.TransformationEstimationPointToPlane(),
            reg.ICPConvergenceCriteria(max_iteration=60),
        )
        T = res.transformation
    return res


def register_pair(src, dst, extra_init=None):
    """Retourne (T src->dst, fitness, rmse). Teste plusieurs initialisations."""
    src2 = src.voxel_down_sample(2.0)
    dst2 = dst.voxel_down_sample(2.0)
    centroid = np.asarray(dst2.points).mean(axis=0)

    inits = [np.eye(4)]
    if extra_init is not None:
        inits.append(extra_init)
    for axis in (0, 1):
        for sign in (1.0, -1.0):
            inits.append(about_point(rot_axis(axis, sign * NOMINAL_STEP_DEG), centroid))

    try:
        voxel = 4.0
        s_down, s_feat = fpfh(src, voxel)
        d_down, d_feat = fpfh(dst, voxel)
        dist = voxel * 1.5
        ransac = reg.registration_ransac_based_on_feature_matching(
            s_down, d_down, s_feat, d_feat, True, dist,
            reg.TransformationEstimationPointToPoint(False), 3,
            [reg.CorrespondenceCheckerBasedOnEdgeLength(0.9),
             reg.CorrespondenceCheckerBasedOnDistance(dist)],
            reg.RANSACConvergenceCriteria(400000, 0.999),
        )
        inits.append(ransac.transformation)
    except Exception as e:  # noqa: BLE001
        print(f"  RANSAC indisponible ({e}), candidats de rotation seulement")

    best = None
    for init in inits:
        res = icp_refine(src2, dst2, init)
        score = res.fitness - 0.01 * res.inlier_rmse
        if best is None or score > best[0]:
            best = (score, res)
    res = best[1]
    return res.transformation, res.fitness, res.inlier_rmse


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", type=Path, help="dossier Scan_* contenant les pose_XX.ply")
    ap.add_argument("--out", type=Path, default=None, help="fichier STL de sortie")
    ap.add_argument("--radius", type=float, default=130.0, help="rayon de crop du visage en mm")
    ap.add_argument("--mirror-x", action="store_true", help="inverse l'axe X si le resultat est en miroir")
    ap.add_argument("--rotate-z", type=float, default=0.0, help="rotation finale autour de Z en degres (0, 90, -90, 180)")
    ap.add_argument("--depth", type=int, default=9, help="profondeur de l'octree de Poisson")
    ap.add_argument("--trim", type=float, default=0.06, help="quantile de densite Poisson elimine (0 a 0.3)")
    ap.add_argument("--voxel", type=float, default=0.8, help="pas de sous-echantillonnage avant Poisson en mm")
    args = ap.parse_args()

    out = args.out or (args.folder / "visage.stl")
    poses = load_poses(args.folder, args.mirror_x)
    if not poses:
        sys.exit("Aucun fichier pose_*.ply dans ce dossier.")
    print(f"{len(poses)} pose(s) chargee(s)")

    for p in poses:
        before = len(p["pcd"].points)
        p["pcd"] = preprocess(p["pcd"], args.radius)
        print(f"  {p['label']}: {before} -> {len(p['pcd'].points)} points apres crop")

    by_label = {p["label"]: p for p in poses}
    ref_label = "face" if "face" in by_label else poses[0]["label"]
    world = {ref_label: np.eye(4)}
    warnings = []

    # Ordre de traitement : un parent doit etre recale avant son enfant
    pending = [p for p in poses if p["label"] != ref_label]
    guard = 0
    while pending and guard < 50:
        guard += 1
        remaining = []
        for p in pending:
            parent = PARENTS.get(p["label"], ref_label)
            if parent not in by_label:
                parent = ref_label
            if parent not in world:
                remaining.append(p)
                continue
            T, fit, rmse = register_pair(p["pcd"], by_label[parent]["pcd"],
                                         pose_init(p, by_label[parent], args.mirror_x))
            world[p["label"]] = world[parent] @ T
            print(f"  recalage {p['label']} -> {parent}: recouvrement {fit:.2f}, RMSE {rmse:.2f} mm")
            if fit < 0.35 or rmse > 1.5:
                warnings.append(f"{p['label']}: recalage douteux (recouvrement {fit:.2f}, RMSE {rmse:.2f} mm)")
        pending = remaining
    if pending:
        warnings.append("poses non recalees : " + ", ".join(p["label"] for p in pending))

    # Fusion : les normales de chaque nuage sont deja orientees vers sa camera et suivent
    # la transformation du nuage, on ne les recalcule donc pas apres fusion.
    merged_n = o3d.geometry.PointCloud()
    for p in poses:
        if p["label"] in world:
            q = o3d.geometry.PointCloud(p["pcd"])
            q.transform(world[p["label"]])
            merged_n += q
    merged_n = merged_n.voxel_down_sample(args.voxel)
    print(f"Nuage fusionne : {len(merged_n.points)} points")

    mesh, dens = o3d.geometry.TriangleMesh.create_from_point_cloud_poisson(merged_n, depth=args.depth)
    dens = np.asarray(dens)
    mesh.remove_vertices_by_mask(dens < np.quantile(dens, args.trim))
    mn = merged_n.get_min_bound() - 3.0
    mx = merged_n.get_max_bound() + 3.0
    mesh = mesh.crop(o3d.geometry.AxisAlignedBoundingBox(mn, mx))
    mesh.remove_degenerate_triangles()
    mesh.remove_duplicated_vertices()
    mesh.remove_duplicated_triangles()
    mesh.remove_non_manifold_edges()

    # Plus grande composante connexe
    clusters, n_tri, _ = mesh.cluster_connected_triangles()
    clusters = np.asarray(clusters)
    n_tri = np.asarray(n_tri)
    if len(n_tri) > 1:
        mesh.remove_triangles_by_mask(clusters != int(np.argmax(n_tri)))
        mesh.remove_unreferenced_vertices()

    # Repere final : Y vers le haut, Z vers l'avant du visage (rotation de 180 deg autour de X),
    # puis rotation optionnelle autour de Z selon l'orientation du capteur.
    M = rot_axis(2, args.rotate_z) @ rot_axis(0, 180.0)
    mesh.transform(M)
    merged_out = o3d.geometry.PointCloud(merged_n)
    merged_out.transform(M)
    center = mesh.get_center()
    mesh.translate(-center)
    merged_out.translate(-center)

    mesh.compute_vertex_normals()
    mesh.compute_triangle_normals()
    o3d.io.write_triangle_mesh(str(out), mesh)
    cloud_path = out.with_name(out.stem + "_cloud.ply")
    o3d.io.write_point_cloud(str(cloud_path), merged_out)

    ext = mesh.get_axis_aligned_bounding_box().get_extent()
    print(f"\nSTL : {out}")
    print(f"Nuage fusionne : {cloud_path}")
    print(f"Sommets : {len(mesh.vertices)}, triangles : {len(mesh.triangles)}")
    print(f"Dimensions (X, Y, Z) : {ext[0]:.1f} x {ext[1]:.1f} x {ext[2]:.1f} mm")
    for w in warnings:
        print("ATTENTION :", w)
    if not warnings:
        print("Aucun avertissement de recalage.")
    print("Verifier visuellement le maillage (orientation, lateralite, trous) avant tout usage.")


if __name__ == "__main__":
    main()
