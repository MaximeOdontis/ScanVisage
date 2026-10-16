import Foundation
import simd

/// Similitude y ≈ s R x + t (méthode de Horn, quaternion unitaire, échelle symétrique).
struct Similarity {
    var s: Double
    var R: simd_double3x3
    var t: SIMD3<Double>
    var rms: Double

    func apply(_ x: SIMD3<Double>) -> SIMD3<Double> { s * (R * x) + t }
}

enum Alignment {

    static func similarity(from x: [SIMD3<Double>], to y: [SIMD3<Double>]) -> Similarity? {
        let n = x.count
        guard n >= 3, y.count == n else { return nil }
        var mx = SIMD3<Double>(0, 0, 0)
        var my = SIMD3<Double>(0, 0, 0)
        for i in 0..<n {
            mx += x[i]
            my += y[i]
        }
        mx /= Double(n)
        my /= Double(n)
        var sx = 0.0
        var sy = 0.0
        var S = [[Double]](repeating: [0, 0, 0], count: 3)   // S[a][b] = Σ xa * yb
        for i in 0..<n {
            let a = x[i] - mx
            let b = y[i] - my
            sx += simd_length_squared(a)
            sy += simd_length_squared(b)
            for p in 0..<3 {
                for q in 0..<3 {
                    S[p][q] += a[p] * b[q]
                }
            }
        }
        guard sx > 1e-12 else { return nil }
        let s = (sy / sx).squareRoot()
        let (xx, xy, xz) = (S[0][0], S[0][1], S[0][2])
        let (yx, yy, yz) = (S[1][0], S[1][1], S[1][2])
        let (zx, zy, zz) = (S[2][0], S[2][1], S[2][2])
        let N: [[Double]] = [
            [xx + yy + zz, yz - zy, zx - xz, xy - yx],
            [yz - zy, xx - yy - zz, xy + yx, zx + xz],
            [zx - xz, xy + yx, -xx + yy - zz, yz + zy],
            [xy - yx, zx + xz, yz + zy, -xx - yy + zz]
        ]
        let (vals, vecs) = jacobiEigen(N)
        var best = 0
        for k in 1..<4 where vals[k] > vals[best] { best = k }
        var q = [vecs[0][best], vecs[1][best], vecs[2][best], vecs[3][best]]
        let qn = (q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]).squareRoot()
        q = q.map { $0 / qn }
        let R = rotation(w: q[0], x: q[1], y: q[2], z: q[3])
        let t = my - s * (R * mx)
        var err = 0.0
        for i in 0..<n {
            err += simd_length_squared(s * (R * x[i]) + t - y[i])
        }
        return Similarity(s: s, R: R, t: t, rms: (err / Double(n)).squareRoot())
    }

    static func rotation(w: Double, x: Double, y: Double, z: Double) -> simd_double3x3 {
        simd_double3x3(rows: [
            SIMD3<Double>(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)),
            SIMD3<Double>(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)),
            SIMD3<Double>(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y))
        ])
    }

    /// Valeurs et vecteurs propres d'une matrice symétrique (méthode de Jacobi). vecs[i][k] : composante i du vecteur k.
    static func jacobiEigen(_ m: [[Double]]) -> ([Double], [[Double]]) {
        let n = m.count
        var a = m
        var v = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { v[i][i] = 1 }
        for _ in 0..<100 {
            var off = 0.0
            for p in 0..<n {
                for q in (p + 1)..<n { off += a[p][q] * a[p][q] }
            }
            if off < 1e-22 { break }
            for p in 0..<n {
                for q in (p + 1)..<n {
                    if abs(a[p][q]) < 1e-300 { continue }
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let sn = t * c
                    for k in 0..<n {
                        let akp = a[k][p]
                        let akq = a[k][q]
                        a[k][p] = c * akp - sn * akq
                        a[k][q] = sn * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k]
                        let aqk = a[q][k]
                        a[p][k] = c * apk - sn * aqk
                        a[q][k] = sn * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k][p]
                        let vkq = v[k][q]
                        v[k][p] = c * vkp - sn * vkq
                        v[k][q] = sn * vkp + c * vkq
                    }
                }
            }
        }
        return ((0..<n).map { a[$0][$0] }, v)
    }
}
