import Foundation
import simd

typealias V3 = SIMD3<Double>

/// Intrinsèques de la caméra de profondeur (en pixels de la carte de profondeur).
struct Intrinsics {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var width: Int
    var height: Int
}

/// Transformation rigide : p' = R * p + t
struct RigidPose {
    var R: simd_double3x3
    var t: V3

    static var identity: RigidPose {
        RigidPose(R: matrix_identity_double3x3, t: V3(0, 0, 0))
    }

    func apply(_ p: V3) -> V3 {
        let rp: V3 = R * p
        return rp + t
    }

    func inverse() -> RigidPose {
        let rt: simd_double3x3 = R.transpose
        let it: V3 = rt * t
        return RigidPose(R: rt, t: -it)
    }

    /// self ∘ other : applique `other` puis `self`.
    func compose(_ other: RigidPose) -> RigidPose {
        let r: simd_double3x3 = R * other.R
        let ot: V3 = R * other.t
        return RigidPose(R: r, t: ot + t)
    }

    var rotationAngleDegrees: Double {
        let tr: Double = R.columns.0.x + R.columns.1.y + R.columns.2.z
        let c: Double = min(1.0, max(-1.0, (tr - 1.0) / 2.0))
        return acos(c) * 180.0 / Double.pi
    }
}

/// Formule de Rodrigues : vecteur rotation -> matrice.
func rodrigues(_ w: V3) -> simd_double3x3 {
    let th: Double = simd_length(w)
    if th < 1e-12 { return matrix_identity_double3x3 }
    let k: V3 = w / th
    let c0 = V3(0, k.z, -k.y)
    let c1 = V3(-k.z, 0, k.x)
    let c2 = V3(k.y, -k.x, 0)
    let K = simd_double3x3(columns: (c0, c1, c2))
    let K2: simd_double3x3 = K * K
    let a: simd_double3x3 = sin(th) * K
    let b: simd_double3x3 = (1.0 - cos(th)) * K2
    let s: simd_double3x3 = matrix_identity_double3x3 + a
    return s + b
}

/// Résolution d'un système linéaire n x n (A en ligne-majeure) par élimination de Gauss avec pivot.
func solveLinear(_ aIn: [Double], _ bIn: [Double], n: Int) -> [Double]? {
    var A = aIn
    var b = bIn
    for col in 0..<n {
        var piv = col
        var best = abs(A[col * n + col])
        var r = col + 1
        while r < n {
            let v = abs(A[r * n + col])
            if v > best { best = v; piv = r }
            r += 1
        }
        if best < 1e-15 { return nil }
        if piv != col {
            for c in 0..<n {
                let tmp = A[col * n + c]
                A[col * n + c] = A[piv * n + c]
                A[piv * n + c] = tmp
            }
            let tb = b[col]
            b[col] = b[piv]
            b[piv] = tb
        }
        let d = A[col * n + col]
        var rr = col + 1
        while rr < n {
            let f = A[rr * n + col] / d
            if f != 0 {
                for c in col..<n {
                    A[rr * n + c] -= f * A[col * n + c]
                }
                b[rr] -= f * b[col]
            }
            rr += 1
        }
    }
    var x = [Double](repeating: 0, count: n)
    var i = n - 1
    while i >= 0 {
        var s = b[i]
        var c = i + 1
        while c < n {
            s -= A[i * n + c] * x[c]
            c += 1
        }
        x[i] = s / A[i * n + i]
        i -= 1
    }
    return x
}
