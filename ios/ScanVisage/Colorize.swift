import Foundation
import simd

/// Couleur par sommet, calculée en projetant le maillage (repère visage) dans les images couleur des arrêts.
/// - visibilité : face tournée vers la caméra (cos > 0,2) et profondeur mesurée cohérente avec le sommet (anti-occlusion)
/// - fusion : moyenne pondérée par cos², après normalisation de la luminosité de chaque image
///   (l'exposition automatique varie d'une pose à l'autre)
func colorizeMesh(_ mesh: Mesh, stops: [KeyFrame], progress: ((Double) -> Void)? = nil) -> [SIMD3<UInt8>] {
    let n = mesh.vertices.count
    if n == 0 { return [] }
    let normals = vertexNormals(mesh)

    // Une entrée par arrêt qui possède une image couleur
    var samples = [[SIMD4<Float>]]()      // (r, g, b, poids) par sommet, poids 0 = invisible
    for (ci, kf) in stops.enumerated() {
        progress?(Double(ci) / Double(max(1, stops.count)) * 0.8)
        guard let color = kf.color, let intr = kf.intr, !kf.depth.isEmpty else { continue }
        let pose = kf.pose
        let center: V3 = pose.inverse().t
        let centerF = SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
        let W = intr.width
        let H = intr.height
        var arr = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: n)
        for i in 0..<n {
            let v = mesh.vertices[i]
            let toCam: SIMD3<Float> = centerF - v
            let len = simd_length(toCam)
            if !(len > 1e-4) { continue }
            let cosT = simd_dot(normals[i], toCam / len)
            if cosT < 0.2 { continue }
            let p: V3 = pose.apply(V3(Double(v.x), Double(v.y), Double(v.z)))
            if !(p.z > 0.1) { continue }
            let u = intr.fx * p.x / p.z + intr.cx
            let vv = intr.fy * p.y / p.z + intr.cy
            let ix = Int(u.rounded())
            let iy = Int(vv.rounded())
            if ix < 1 || iy < 1 || ix >= W - 1 || iy >= H - 1 { continue }
            let d = kf.depth[iy * W + ix]
            if !(d > 0.05) { continue }
            if abs(p.z - Double(d)) > 0.008 { continue }
            guard let rgb = color.color(atSensorPoint: p) else { continue }
            arr[i] = SIMD4<Float>(rgb.x, rgb.y, rgb.z, cosT * cosT)
        }
        samples.append(arr)
    }
    progress?(0.8)

    func lum(_ s: SIMD4<Float>) -> Float { 0.299 * s.x + 0.587 * s.y + 0.114 * s.z }

    // Luminosité de référence par sommet
    var refNum = [Float](repeating: 0, count: n)
    var refDen = [Float](repeating: 0, count: n)
    for arr in samples {
        for i in 0..<n where arr[i].w > 0 {
            refNum[i] += arr[i].w * lum(arr[i])
            refDen[i] += arr[i].w
        }
    }
    // Gain par image
    var gains = [Float](repeating: 1, count: samples.count)
    for (ci, arr) in samples.enumerated() {
        var num: Float = 0
        var den: Float = 0
        for i in 0..<n where arr[i].w > 0 && refDen[i] > 0 {
            num += arr[i].w * (refNum[i] / refDen[i])
            den += arr[i].w * lum(arr[i])
        }
        if den > 0 && num > 0 { gains[ci] = min(1.33, max(0.75, num / den)) }
    }

    var acc = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: n)
    var wsum = [Float](repeating: 0, count: n)
    for (ci, arr) in samples.enumerated() {
        let g = gains[ci]
        for i in 0..<n where arr[i].w > 0 {
            acc[i] += SIMD3<Float>(arr[i].x, arr[i].y, arr[i].z) * (g * arr[i].w)
            wsum[i] += arr[i].w
        }
    }
    samples = []
    progress?(0.9)

    var col = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: n)
    var has = [Bool](repeating: false, count: n)
    var meanSum = SIMD3<Float>(0, 0, 0)
    var meanCount: Float = 0
    for i in 0..<n where wsum[i] > 0 {
        col[i] = acc[i] / wsum[i]
        has[i] = true
        meanSum += col[i]
        meanCount += 1
    }
    let mean: SIMD3<Float> = meanCount > 0 ? meanSum / meanCount : SIMD3<Float>(200, 170, 150)

    // Sommets jamais vus : propagation depuis les voisins
    for _ in 0..<10 {
        var add = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: n)
        var cnt = [Float](repeating: 0, count: n)
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = Int(mesh.indices[t])
            let b = Int(mesh.indices[t + 1])
            let c = Int(mesh.indices[t + 2])
            if !has[a] {
                if has[b] { add[a] += col[b]; cnt[a] += 1 }
                if has[c] { add[a] += col[c]; cnt[a] += 1 }
            }
            if !has[b] {
                if has[a] { add[b] += col[a]; cnt[b] += 1 }
                if has[c] { add[b] += col[c]; cnt[b] += 1 }
            }
            if !has[c] {
                if has[a] { add[c] += col[a]; cnt[c] += 1 }
                if has[b] { add[c] += col[b]; cnt[c] += 1 }
            }
            t += 3
        }
        var changed = false
        for i in 0..<n where !has[i] && cnt[i] > 0 {
            col[i] = add[i] / cnt[i]
            has[i] = true
            changed = true
        }
        if !changed { break }
    }
    for i in 0..<n where !has[i] { col[i] = mean }

    // Lissage léger des couleurs (réduit le grain et les raccords entre images)
    do {
        var add = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: n)
        var cnt = [Float](repeating: 0, count: n)
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = Int(mesh.indices[t])
            let b = Int(mesh.indices[t + 1])
            let c = Int(mesh.indices[t + 2])
            add[a] += col[b] + col[c]
            add[b] += col[a] + col[c]
            add[c] += col[a] + col[b]
            cnt[a] += 2
            cnt[b] += 2
            cnt[c] += 2
            t += 3
        }
        for i in 0..<n where cnt[i] > 0 {
            col[i] = col[i] * 0.5 + (add[i] / cnt[i]) * 0.5
        }
    }

    var out = [SIMD3<UInt8>]()
    out.reserveCapacity(n)
    for i in 0..<n {
        let c = col[i]
        out.append(SIMD3<UInt8>(UInt8(min(255, max(0, c.x.rounded()))),
                                UInt8(min(255, max(0, c.y.rounded()))),
                                UInt8(min(255, max(0, c.z.rounded())))))
    }
    progress?(1.0)
    return out
}
