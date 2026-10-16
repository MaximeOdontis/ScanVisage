import Foundation
import simd

// MARK: - Conversions

@inline(__always) func f3(_ v: V3) -> SIMD3<Float> {
    SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
}

@inline(__always) func f33(_ m: simd_double3x3) -> simd_float3x3 {
    simd_float3x3(columns: (f3(m.columns.0), f3(m.columns.1), f3(m.columns.2)))
}

// MARK: - Filtre bilatéral de la profondeur

/// Lisse la profondeur en préservant les bords (fenêtre (2r+1)², sigma spatial en pixels, sigma de profondeur en mètres).
/// Validé sur un scan réel : avec la fusion à troncature de 7 mm, la rugosité du visage passe d'environ 0,9 à 0,2 mm.
func bilateralFilter(_ depth: [Float], width W: Int, height H: Int,
                     radius: Int = 3, sigmaSpace: Float = 1.5, sigmaRange: Float = 0.003) -> [Float] {
    var out = [Float](repeating: Float.nan, count: W * H)
    if depth.count != W * H || W == 0 || H == 0 { return depth }
    let r = radius
    let side = 2 * r + 1
    var spatial = [Float](repeating: 0, count: side * side)
    for dy in -r...r {
        for dx in -r...r {
            spatial[(dy + r) * side + dx + r] = expf(-Float(dx * dx + dy * dy) / (2 * sigmaSpace * sigmaSpace))
        }
    }
    let inv2 = 1 / (2 * sigmaRange * sigmaRange)
    depth.withUnsafeBufferPointer { dp in
        out.withUnsafeMutableBufferPointer { op in
            spatial.withUnsafeBufferPointer { sp in
                guard let d = dp.baseAddress, let o = op.baseAddress, let sw = sp.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: H) { y in
                    for x in 0..<W {
                        let c = d[y * W + x]
                        if !(c > 0.05) { continue }
                        var acc: Float = 0
                        var ws: Float = 0
                        for dy in -r...r {
                            let yy = y + dy
                            if yy < 0 || yy >= H { continue }
                            for dx in -r...r {
                                let xx = x + dx
                                if xx < 0 || xx >= W { continue }
                                let v = d[yy * W + xx]
                                if !(v > 0.05) { continue }
                                let diff = v - c
                                let w = sw[(dy + r) * side + dx + r] * expf(-diff * diff * inv2)
                                acc += w * v
                                ws += w
                            }
                        }
                        o[y * W + x] = ws > 0 ? acc / ws : c
                    }
                }
            }
        }
    }
    return out
}

// MARK: - Nuage de points avec normales

/// Points (repère capteur, mètres) et normales orientées vers la caméra.
struct ViewCloud {
    var points: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var count: Int { points.count }
}

/// Un point tous les `step` pixels ; normale par produit vectoriel des voisins à ±`step` pixels.
func makeViewCloud(depth: [Float], intr: Intrinsics, step: Int = 2) -> ViewCloud {
    let W = intr.width
    let H = intr.height
    let s = max(1, step)
    var out = ViewCloud()
    if depth.count != W * H { return out }
    let fx = Float(intr.fx)
    let fy = Float(intr.fy)
    let cx = Float(intr.cx)
    let cy = Float(intr.cy)
    func point(_ x: Int, _ y: Int) -> SIMD3<Float>? {
        let z = depth[y * W + x]
        if !(z > 0.05) { return nil }
        return SIMD3<Float>((Float(x) - cx) * z / fx, (Float(y) - cy) * z / fy, z)
    }
    out.points.reserveCapacity((W / s) * (H / s) / 2)
    out.normals.reserveCapacity((W / s) * (H / s) / 2)
    var y = s
    while y < H - s {
        var x = s
        while x < W - s {
            if let p = point(x, y), let l = point(x - s, y), let r = point(x + s, y),
               let u = point(x, y - s), let d = point(x, y + s) {
                let gx = r - l
                let gy = d - u
                if abs(gx.z) < 0.01 && abs(gy.z) < 0.01 {
                    var n = simd_cross(gx, gy)
                    let len = simd_length(n)
                    if len > 1e-12 {
                        n /= len
                        if simd_dot(n, p) > 0 { n = -n }
                        out.points.append(p)
                        out.normals.append(n)
                    }
                }
            }
            x += s
        }
        y += s
    }
    return out
}

/// Garde les points dont la position dans le repère visage (pose visage -> capteur) est dans la tête
/// (élargie de `margin`), puis sous-échantillonne régulièrement à `maxCount` points au plus.
func selectHeadPoints(_ cloud: ViewCloud, pose: RigidPose, margin: Double, maxCount: Int = Int.max) -> ViewCloud {
    let inv = pose.inverse()
    let R = f33(inv.R)
    let t = f3(inv.t)
    var sel = ViewCloud()
    for k in 0..<cloud.count {
        let x = R * cloud.points[k] + t
        if TSDFVolume.insideHead(Double(x.x), Double(x.y), Double(x.z), margin: margin) {
            sel.points.append(cloud.points[k])
            sel.normals.append(cloud.normals[k])
        }
    }
    return subsample(sel, maxCount: maxCount)
}

// MARK: - Grille de recherche du plus proche voisin

/// Grille régulière (tri par comptage) : plus proche voisin dans un rayon <= taille de cellule.
final class PointGrid {
    let points: [SIMD3<Float>]
    let cell: Float
    private let inv: Float
    private var origin = SIMD3<Float>(0, 0, 0)
    private var nx = 0
    private var ny = 0
    private var nz = 0
    private var starts: [Int32] = []
    private var order: [Int32] = []

    init(points: [SIMD3<Float>], cell: Float) {
        self.points = points
        self.cell = cell
        self.inv = 1 / cell
        if points.isEmpty { return }
        var lo = points[0]
        var hi = points[0]
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        origin = lo
        nx = Int(((hi.x - lo.x) * inv).rounded(.down)) + 1
        ny = Int(((hi.y - lo.y) * inv).rounded(.down)) + 1
        nz = Int(((hi.z - lo.z) * inv).rounded(.down)) + 1
        let total = nx * ny * nz
        if total <= 0 || total > 30_000_000 { nx = 0; return }
        var counts = [Int32](repeating: 0, count: total + 1)
        var cellOf = [Int32](repeating: 0, count: points.count)
        for (i, p) in points.enumerated() {
            let c = cellIndex(p)
            cellOf[i] = Int32(c)
            counts[c + 1] += 1
        }
        for c in 0..<total { counts[c + 1] += counts[c] }
        starts = counts
        var fill = counts
        order = [Int32](repeating: 0, count: points.count)
        for i in 0..<points.count {
            let c = Int(cellOf[i])
            order[Int(fill[c])] = Int32(i)
            fill[c] += 1
        }
    }

    private func cellIndex(_ p: SIMD3<Float>) -> Int {
        let ix = min(nx - 1, max(0, Int(((p.x - origin.x) * inv).rounded(.down))))
        let iy = min(ny - 1, max(0, Int(((p.y - origin.y) * inv).rounded(.down))))
        let iz = min(nz - 1, max(0, Int(((p.z - origin.z) * inv).rounded(.down))))
        return (iz * ny + iy) * nx + ix
    }

    /// Indice du point le plus proche de `q` à moins de `maxDist` (qui doit être <= `cell`), ou nil.
    func nearest(_ q: SIMD3<Float>, maxDist: Float) -> Int? {
        if nx == 0 { return nil }
        let fx = ((q.x - origin.x) * inv).rounded(.down)
        let fy = ((q.y - origin.y) * inv).rounded(.down)
        let fz = ((q.z - origin.z) * inv).rounded(.down)
        if fx < -1 || fy < -1 || fz < -1 || fx > Float(nx) || fy > Float(ny) || fz > Float(nz) { return nil }
        let cx = Int(fx)
        let cy = Int(fy)
        let cz = Int(fz)
        var best = -1
        var bestD = maxDist * maxDist
        for z in max(0, cz - 1)...min(nz - 1, cz + 1) {
            for y in max(0, cy - 1)...min(ny - 1, cy + 1) {
                for x in max(0, cx - 1)...min(nx - 1, cx + 1) {
                    let c = (z * ny + y) * nx + x
                    let s = Int(starts[c])
                    let e = Int(starts[c + 1])
                    if s == e { continue }
                    for k in s..<e {
                        let idx = Int(order[k])
                        let d = simd_length_squared(points[idx] - q)
                        if d < bestD {
                            bestD = d
                            best = idx
                        }
                    }
                }
            }
        }
        return best >= 0 ? best : nil
    }
}

// MARK: - ICP point-plan

/// Affine la pose (visage -> capteur) d'une vue sur une cible fixe exprimée dans le repère visage.
/// Correspondance : plus proche voisin à moins de `maxDist`, normales compatibles (moins de 60°).
/// Résidu point-plan, pondération de Huber (1,5 mm).
func icpRefine(source: ViewCloud, pose: RigidPose, grid: PointGrid, targetNormals: [SIMD3<Float>],
               maxDist: Float, iterations: Int, huber: Double = 0.0015, minMatches: Int = 200) -> RigidPose {
    var pose = pose
    for _ in 0..<iterations {
        let inv = pose.inverse()
        let R = f33(inv.R)
        let t = f3(inv.t)
        var A = [Double](repeating: 0, count: 36)
        var b = [Double](repeating: 0, count: 6)
        var matches = 0
        for k in 0..<source.count {
            let x = R * source.points[k] + t
            guard let j = grid.nearest(x, maxDist: maxDist) else { continue }
            let nt = targetNormals[j]
            let ns = R * source.normals[k]
            if simd_dot(nt, ns) <= 0.5 { continue }
            let r = Double(simd_dot(x - grid.points[j], nt))
            let c = simd_cross(x, nt)
            let jv = SIMD8<Double>(Double(c.x), Double(c.y), Double(c.z),
                                   Double(nt.x), Double(nt.y), Double(nt.z), 0, 0)
            let w = 1.0 / max(1.0, abs(r) / huber)
            for a in 0..<6 {
                let wa = w * jv[a]
                b[a] -= wa * r
                for cc in a..<6 {
                    A[a * 6 + cc] += wa * jv[cc]
                }
            }
            matches += 1
        }
        if matches < minMatches { break }
        for a in 0..<6 {
            for cc in 0..<a {
                A[a * 6 + cc] = A[cc * 6 + a]
            }
            A[a * 6 + a] += 1e-9
        }
        guard let xi = solveLinear(A, b, n: 6) else { break }
        let corr = RigidPose(R: rodrigues(V3(xi[0], xi[1], xi[2])), t: V3(xi[3], xi[4], xi[5]))
        // points du repère visage : X' = C X ; nouvelle pose = pose ∘ C⁻¹
        pose = pose.compose(corr.inverse())
    }
    return pose
}

/// Points et normales (repère visage) des vues `views`, limités à la tête.
func faceFrameTarget(_ views: [(cloud: ViewCloud, pose: RigidPose)]) -> (points: [SIMD3<Float>], normals: [SIMD3<Float>]) {
    var pts = [SIMD3<Float>]()
    var nrm = [SIMD3<Float>]()
    for v in views {
        let inv = v.pose.inverse()
        let R = f33(inv.R)
        let t = f3(inv.t)
        for k in 0..<v.cloud.count {
            let x = R * v.cloud.points[k] + t
            if TSDFVolume.insideHead(Double(x.x), Double(x.y), Double(x.z)) {
                pts.append(x)
                nrm.append(R * v.cloud.normals[k])
            }
        }
    }
    return (pts, nrm)
}

/// Recalage multivue : chaque vue (sauf la première, fixe) est recalée sur l'ensemble des autres,
/// avec des seuils de 30 mm à 3 mm. Les poses ARKit peuvent être fausses de plusieurs centimètres
/// sur les vues tournées : mesuré sur un scan réel (18 à 30 mm), d'où le seuil de départ large.
/// `clouds` : nuages déjà limités à la tête (avec marge). `poses` : visage -> capteur, modifiées en place.
func multiViewICP(clouds: [ViewCloud], poses: inout [RigidPose],
                  levels: [Float] = [0.03, 0.02, 0.012, 0.008, 0.005, 0.003],
                  sweeps: Int = 2, iterations: Int = 3, maxSource: Int = 6000,
                  progress: ((Double) -> Void)? = nil) {
    let n = clouds.count
    if n < 2 || poses.count != n { return }
    let sources = clouds.map { subsample($0, maxCount: maxSource) }
    let total = Double(levels.count * sweeps * (n - 1))
    var done = 0.0
    for level in levels {
        for _ in 0..<sweeps {
            for i in 1..<n {
                progress?(done / total)
                done += 1
                if sources[i].count < 200 { continue }
                var others = [(cloud: ViewCloud, pose: RigidPose)]()
                for j in 0..<n where j != i {
                    others.append((clouds[j], poses[j]))
                }
                let target = faceFrameTarget(others)
                if target.points.count < 500 { continue }
                let grid = PointGrid(points: target.points, cell: level)
                poses[i] = icpRefine(source: sources[i], pose: poses[i], grid: grid,
                                     targetNormals: target.normals, maxDist: level, iterations: iterations)
            }
        }
    }
    progress?(1)
}

/// Sous-échantillonnage régulier.
func subsample(_ c: ViewCloud, maxCount: Int) -> ViewCloud {
    if c.count <= maxCount || maxCount <= 0 { return c }
    var sub = ViewCloud()
    let stride = Double(c.count) / Double(maxCount)
    var f = 0.0
    while Int(f) < c.count && sub.count < maxCount {
        let k = Int(f)
        sub.points.append(c.points[k])
        sub.normals.append(c.normals[k])
        f += stride
    }
    return sub
}
