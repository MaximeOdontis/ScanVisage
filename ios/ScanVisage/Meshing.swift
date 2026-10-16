import Foundation
import simd

struct Mesh {
    var vertices: [SIMD3<Float>] = []
    var indices: [UInt32] = []   // 3 indices par triangle
    /// Couleur RGB par sommet (vide si le maillage n'est pas coloré).
    var colors: [SIMD3<UInt8>] = []

    var triangleCount: Int { indices.count / 3 }
    var hasColors: Bool { !colors.isEmpty && colors.count == vertices.count }
}

/// Normales par sommet (moyenne pondérée par l'aire des triangles voisins).
func vertexNormals(_ m: Mesh) -> [SIMD3<Float>] {
    let n = m.vertices.count
    var acc = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: n)
    var t = 0
    while t + 2 < m.indices.count {
        let a = Int(m.indices[t])
        let b = Int(m.indices[t + 1])
        let c = Int(m.indices[t + 2])
        let fn = simd_cross(m.vertices[b] - m.vertices[a], m.vertices[c] - m.vertices[a])
        acc[a] += fn
        acc[b] += fn
        acc[c] += fn
        t += 3
    }
    for i in 0..<n {
        let l = simd_length(acc[i])
        acc[i] = l > 0 ? acc[i] / l : SIMD3<Float>(0, 0, 1)
    }
    return acc
}

// MARK: - Naive Surface Nets

/// Extrait l'isosurface phi = 0 (orientation : normales vers l'extérieur, c'est-à-dire vers phi croissant).
func extractMesh(from vol: TSDFVolume) -> Mesh {
    let nx = vol.nx
    let ny = vol.ny
    let nz = vol.nz
    let cx = nx - 1
    let cy = ny - 1
    let cz = nz - 1
    let phi = vol.phi
    let wt = vol.w
    let vs = Float(vol.voxel)
    let ox = Float(vol.origin.x)
    let oy = Float(vol.origin.y)
    let oz = Float(vol.origin.z)

    var cellIndex = [Int32](repeating: -1, count: cx * cy * cz)
    var verts = [SIMD3<Float>]()

    let ea: [Int] = [0, 2, 4, 6, 0, 1, 4, 5, 0, 1, 2, 3]
    let eb: [Int] = [1, 3, 5, 7, 2, 3, 6, 7, 4, 5, 6, 7]
    var cv = [Float](repeating: 0, count: 8)
    let plane = nx * ny

    for k in 0..<cz {
        for j in 0..<cy {
            for i in 0..<cx {
                let b0 = (k * ny + j) * nx + i
                var ok = true
                var mask = 0
                for c in 0..<8 {
                    let idx = b0 + (c & 1) + ((c >> 1) & 1) * nx + ((c >> 2) & 1) * plane
                    if wt[idx] <= 0 { ok = false; break }
                    let v = phi[idx]
                    cv[c] = v
                    if v < 0 { mask |= (1 << c) }
                }
                if !ok || mask == 0 || mask == 255 { continue }

                var sum = SIMD3<Float>(0, 0, 0)
                var cnt: Float = 0
                for e in 0..<12 {
                    let a = ea[e]
                    let b = eb[e]
                    let va = cv[a]
                    let vb = cv[b]
                    if (va < 0) != (vb < 0) {
                        let t = va / (va - vb)
                        let pa = SIMD3<Float>(Float(a & 1), Float((a >> 1) & 1), Float((a >> 2) & 1))
                        let pb = SIMD3<Float>(Float(b & 1), Float((b >> 1) & 1), Float((b >> 2) & 1))
                        sum += pa + (pb - pa) * t
                        cnt += 1
                    }
                }
                if cnt == 0 { continue }
                let g = sum / cnt + SIMD3<Float>(Float(i), Float(j), Float(k))
                let p = SIMD3<Float>(ox + g.x * vs, oy + g.y * vs, oz + g.z * vs)
                cellIndex[(k * cy + j) * cx + i] = Int32(verts.count)
                verts.append(p)
            }
        }
    }

    func cellId(_ p: SIMD3<Int>) -> Int32 {
        if p.x < 0 || p.y < 0 || p.z < 0 || p.x >= cx || p.y >= cy || p.z >= cz { return -1 }
        return cellIndex[(p.z * cy + p.y) * cx + p.x]
    }

    var idxOut = [UInt32]()
    idxOut.reserveCapacity(verts.count * 6)
    let dims = [nx, ny, nz]

    for a in 0..<3 {
        let b = (a + 1) % 3
        let c = (a + 2) % 3
        var ea3 = SIMD3<Int>(0, 0, 0); ea3[a] = 1
        var eb3 = SIMD3<Int>(0, 0, 0); eb3[b] = 1
        var ec3 = SIMD3<Int>(0, 0, 0); ec3[c] = 1

        for pk in 0..<nz {
            for pj in 0..<ny {
                for pi in 0..<nx {
                    let p = SIMD3<Int>(pi, pj, pk)
                    if p[a] >= dims[a] - 1 || p[b] < 1 || p[c] < 1 { continue }
                    let i0 = (pk * ny + pj) * nx + pi
                    let q1 = p &+ ea3
                    let i1 = (q1.z * ny + q1.y) * nx + q1.x
                    if wt[i0] <= 0 || wt[i1] <= 0 { continue }
                    let s0 = phi[i0]
                    let s1 = phi[i1]
                    if (s0 < 0) == (s1 < 0) { continue }

                    let id0 = cellId(p)
                    let id1 = cellId(p &- eb3)
                    let id2 = cellId(p &- eb3 &- ec3)
                    let id3 = cellId(p &- ec3)
                    if id0 < 0 || id1 < 0 || id2 < 0 || id3 < 0 { continue }

                    let v0 = verts[Int(id0)]
                    let v1 = verts[Int(id1)]
                    let v2 = verts[Int(id2)]
                    let v3 = verts[Int(id3)]
                    let n1 = simd_cross(v1 - v0, v2 - v0)
                    let n2 = simd_cross(v2 - v0, v3 - v0)
                    let n = n1 + n2
                    let outDir: Float = s0 < 0 ? 1 : -1
                    let flip = n[a] * outDir < 0
                    let u0 = UInt32(id0)
                    let u1 = UInt32(id1)
                    let u2 = UInt32(id2)
                    let u3 = UInt32(id3)
                    if flip {
                        idxOut.append(u0); idxOut.append(u2); idxOut.append(u1)
                        idxOut.append(u0); idxOut.append(u3); idxOut.append(u2)
                    } else {
                        idxOut.append(u0); idxOut.append(u1); idxOut.append(u2)
                        idxOut.append(u0); idxOut.append(u2); idxOut.append(u3)
                    }
                }
            }
        }
    }
    return Mesh(vertices: verts, indices: idxOut)
}

// MARK: - Lissage laplacien

func laplacianSmooth(_ m: inout Mesh, iterations: Int, lambda: Float = 0.5) {
    for _ in 0..<iterations {
        smoothStep(&m, factor: lambda)
    }
}

/// Lissage de Taubin : alterne un pas de lissage (lambda) et un pas inverse (mu < 0).
/// Réduit le bruit sans faire rétrécir le visage comme un lissage laplacien répété.
func taubinSmooth(_ m: inout Mesh, iterations: Int, lambda: Float = 0.5, mu: Float = -0.53) {
    for _ in 0..<iterations {
        smoothStep(&m, factor: lambda)
        smoothStep(&m, factor: mu)
    }
}

private func smoothStep(_ m: inout Mesh, factor: Float) {
    let n = m.vertices.count
    if n == 0 { return }
    var acc = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: n)
    var cnt = [Float](repeating: 0, count: n)
    var t = 0
    while t + 2 < m.indices.count {
        let a = Int(m.indices[t])
        let b = Int(m.indices[t + 1])
        let c = Int(m.indices[t + 2])
        let va = m.vertices[a]
        let vb = m.vertices[b]
        let vc = m.vertices[c]
        acc[a] += vb + vc
        acc[b] += va + vc
        acc[c] += va + vb
        cnt[a] += 2
        cnt[b] += 2
        cnt[c] += 2
        t += 3
    }
    for i in 0..<n {
        if cnt[i] > 0 {
            let mean = acc[i] / cnt[i]
            m.vertices[i] += (mean - m.vertices[i]) * factor
        }
    }
}

// MARK: - Plus grande composante connexe

func largestComponent(_ m: Mesh) -> Mesh {
    let n = m.vertices.count
    if n == 0 || m.indices.isEmpty { return m }
    var parent = Array(0..<n)

    func find(_ x: Int) -> Int {
        var r = x
        while parent[r] != r {
            parent[r] = parent[parent[r]]
            r = parent[r]
        }
        return r
    }

    var t = 0
    while t + 2 < m.indices.count {
        let a = Int(m.indices[t])
        let b = Int(m.indices[t + 1])
        let c = Int(m.indices[t + 2])
        let ra = find(a)
        let rb = find(b)
        if ra != rb { parent[rb] = ra }
        let rc = find(c)
        let ra2 = find(a)
        if rc != ra2 { parent[rc] = ra2 }
        t += 3
    }

    var triCount = [Int](repeating: 0, count: n)
    t = 0
    while t + 2 < m.indices.count {
        triCount[find(Int(m.indices[t]))] += 1
        t += 3
    }
    var best = 0
    var bestCount = -1
    for i in 0..<n where triCount[i] > bestCount {
        bestCount = triCount[i]
        best = i
    }

    var remap = [Int32](repeating: -1, count: n)
    let keepColors = m.hasColors
    var out = Mesh()
    t = 0
    while t + 2 < m.indices.count {
        let a = Int(m.indices[t])
        if find(a) == best {
            for o in 0..<3 {
                let vi = Int(m.indices[t + o])
                if remap[vi] < 0 {
                    remap[vi] = Int32(out.vertices.count)
                    out.vertices.append(m.vertices[vi])
                    if keepColors { out.colors.append(m.colors[vi]) }
                }
                out.indices.append(UInt32(remap[vi]))
            }
        }
        t += 3
    }
    return out
}

// MARK: - Transformations d'orientation

/// Rotation de `quarterTurns` quarts de tour autour de Z (sens trigonométrique vu de +Z), puis miroir en X éventuel.
func transformedMesh(_ m: Mesh, quarterTurns: Int, mirror: Bool) -> Mesh {
    var out = m
    let k = ((quarterTurns % 4) + 4) % 4
    if k != 0 || mirror {
        for i in 0..<out.vertices.count {
            var v = out.vertices[i]
            for _ in 0..<k {
                v = SIMD3<Float>(-v.y, v.x, v.z)
            }
            if mirror { v.x = -v.x }
            out.vertices[i] = v
        }
        if mirror {
            var t = 0
            while t + 2 < out.indices.count {
                let tmp = out.indices[t + 1]
                out.indices[t + 1] = out.indices[t + 2]
                out.indices[t + 2] = tmp
                t += 3
            }
        }
    }
    return out
}
