import Foundation
import simd

struct TSDFSample {
    var value: Double
    var grad: V3
}

/// Volume TSDF dans le repère visage.
/// phi[k][j][i] : positif devant la surface, négatif derrière. Position du voxel = origin + (i, j, k) * voxel.
final class TSDFVolume {
    let nx: Int
    let ny: Int
    let nz: Int
    let origin: V3
    let voxel: Double
    let trunc: Double
    let wmax: Float
    var phi: [Float]
    var w: [Float]

    /// Masque de la tête dans le repère visage ARKit (origine au centre de la tête, environ 12 cm derrière
    /// le bout du nez ; Y haut, Z hors du visage, X vers la gauche du patient). Dimensions mesurées sur un scan réel :
    /// bout du nez vers z = 0,12, menton vers y = -0,10, front et cheveux jusqu'à y = 0,15.
    /// Exclut épaules, cou et fond, qui ne bougent pas avec la tête. `margin` élargit le masque (mètres).
    static func insideHead(_ x: Double, _ y: Double, _ z: Double, margin: Double = 0) -> Bool {
        if y < -0.125 - margin || y > 0.15 + margin || z < -0.06 - margin || z > 0.165 + margin { return false }
        let ex = x / (0.11 + margin)
        let ez = (z - 0.03) / (0.135 + margin)
        return ex * ex + ez * ez <= 1.0
    }

    /// Voxels dont le centre est dans la tête (1) ou non (0).
    let roi: [UInt8]

    init(origin: V3, nx: Int, ny: Int, nz: Int, voxel: Double, trunc: Double, wmax: Float = 60) {
        self.origin = origin
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.voxel = voxel
        self.trunc = trunc
        self.wmax = wmax
        self.phi = [Float](repeating: 1, count: nx * ny * nz)
        self.w = [Float](repeating: 0, count: nx * ny * nz)
        var mask = [UInt8](repeating: 0, count: nx * ny * nz)
        for k in 0..<nz {
            let z = origin.z + Double(k) * voxel
            for j in 0..<ny {
                let y = origin.y + Double(j) * voxel
                let row = (k * ny + j) * nx
                for i in 0..<nx {
                    let x = origin.x + Double(i) * voxel
                    if TSDFVolume.insideHead(x, y, z) { mask[row + i] = 1 }
                }
            }
        }
        self.roi = mask
    }

    // MARK: Poids par pixel

    /// Poids d'un pixel de profondeur : cos² de l'angle entre le rayon et la normale estimée
    /// (gradient mesuré sur ±`span` pixels, beaucoup moins bruité que sur ±1 pixel).
    /// 0 pour un pixel invalide, au bord d'un objet ou trop oblique (très bruité).
    static func pixelWeights(depth: [Float], intr: Intrinsics, span: Int = 3) -> [Float] {
        let W = intr.width
        let H = intr.height
        let s = max(1, span)
        var out = [Float](repeating: 0, count: W * H)
        let fx = Float(intr.fx)
        let fy = Float(intr.fy)
        if W <= 2 * s || H <= 2 * s { return out }
        let jump = 0.02 * Float(s)
        let inv2s = 1.0 / Float(2 * s)
        for y in s..<(H - s) {
            for x in s..<(W - s) {
                let i = y * W + x
                let z = depth[i]
                if !(z > 0.05) { continue }
                let l = depth[i - s]
                let r = depth[i + s]
                let u = depth[i - s * W]
                let d = depth[i + s * W]
                if !(l > 0.05 && r > 0.05 && u > 0.05 && d > 0.05) { continue }
                if abs(r - l) > jump || abs(d - u) > jump { continue }
                let sx = (r - l) * inv2s * fx / z
                let sy = (d - u) * inv2s * fy / z
                let c2 = 1.0 / (1.0 + sx * sx + sy * sy)
                if c2 > 0.06 { out[i] = c2 }
            }
        }
        return out
    }

    // MARK: Intégration d'une carte de profondeur

    /// `pose` envoie le repère visage vers le repère capteur (x droite, y bas, z devant).
    /// Profondeur interpolée en bilinéaire, pondérée par `weights` (cos² de l'incidence), limitée au masque de la tête.
    /// Un `weight` négatif (même pose, mêmes données) retire exactement une trame précédemment intégrée.
    func integrate(depth: [Float], weights: [Float], intr: Intrinsics, pose: RigidPose, weight: Float = 1) {
        let nx = self.nx
        let ny = self.ny
        let nz = self.nz
        let W = intr.width
        let H = intr.height
        let fx = intr.fx
        let fy = intr.fy
        let cx = intr.cx
        let cy = intr.cy
        let tr = self.trunc
        let wm = self.wmax
        let wf = weight
        let stepI: V3 = pose.R.columns.0 * self.voxel
        let stepJ: V3 = pose.R.columns.1 * self.voxel
        let stepK: V3 = pose.R.columns.2 * self.voxel
        let ro: V3 = pose.R * self.origin
        let base: V3 = ro + pose.t

        roi.withUnsafeBufferPointer { rp in
            depth.withUnsafeBufferPointer { dp in
                weights.withUnsafeBufferPointer { gp in
                    self.phi.withUnsafeMutableBufferPointer { pp in
                        self.w.withUnsafeMutableBufferPointer { wp in
                            guard let rptr = rp.baseAddress, let dptr = dp.baseAddress, let gptr = gp.baseAddress,
                                  let pptr = pp.baseAddress, let wptr = wp.baseAddress else { return }
                            DispatchQueue.concurrentPerform(iterations: nz) { k in
                                let qk: V3 = base + stepK * Double(k)
                                for j in 0..<ny {
                                    var q: V3 = qk + stepJ * Double(j)
                                    let rowBase = (k * ny + j) * nx
                                    for i in 0..<nx {
                                        let idx = rowBase + i
                                        let z = q.z
                                        if rptr[idx] != 0 && z > 0.05 {
                                            let inv = 1.0 / z
                                            let uf = fx * q.x * inv + cx
                                            let vf = fy * q.y * inv + cy
                                            if uf >= 0 && vf >= 0 && uf < Double(W - 1) && vf < Double(H - 1) {
                                                let x0 = Int(uf)
                                                let y0 = Int(vf)
                                                let ax = Float(uf - Double(x0))
                                                let ay = Float(vf - Double(y0))
                                                let i00 = y0 * W + x0
                                                let d00 = dptr[i00]
                                                let d10 = dptr[i00 + 1]
                                                let d01 = dptr[i00 + W]
                                                let d11 = dptr[i00 + W + 1]
                                                if d00 > 0.05 && d10 > 0.05 && d01 > 0.05 && d11 > 0.05 {
                                                    let dmin = min(min(d00, d10), min(d01, d11))
                                                    let dmax = max(max(d00, d10), max(d01, d11))
                                                    let ni = (ay >= 0.5 ? i00 + W : i00) + (ax >= 0.5 ? 1 : 0)
                                                    let gw = gptr[ni]
                                                    if dmax - dmin < 0.012 && gw > 0 {
                                                        let top = d00 * (1 - ax) + d10 * ax
                                                        let bot = d01 * (1 - ax) + d11 * ax
                                                        let d = top * (1 - ay) + bot * ay
                                                        let sdf = Double(d) - z
                                                        if sdf > -tr {
                                                            let ph = Float(min(1.0, max(-1.0, sdf / tr)))
                                                            let wi = gw * wf
                                                            let w0 = wptr[idx]
                                                            let wn = w0 + wi
                                                            if wn > 1e-3 {
                                                                pptr[idx] = (pptr[idx] * w0 + ph * wi) / wn
                                                                wptr[idx] = min(wn, wm)
                                                            } else {
                                                                // poids négatif (retrait d'une trame) qui vide le voxel
                                                                pptr[idx] = 1
                                                                wptr[idx] = 0
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        q += stepI
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Échantillonnage trilinéaire

    /// Valeur de phi et gradient (en 1/m) à la position P (repère visage). nil si hors volume ou non observé.
    func sample(_ P: V3) -> TSDFSample? {
        let gx = (P.x - origin.x) / voxel
        let gy = (P.y - origin.y) / voxel
        let gz = (P.z - origin.z) / voxel
        guard gx >= 0, gy >= 0, gz >= 0,
              gx < Double(nx - 1), gy < Double(ny - 1), gz < Double(nz - 1) else { return nil }
        let x0 = Int(gx)
        let y0 = Int(gy)
        let z0 = Int(gz)
        let fx = gx - Double(x0)
        let fy = gy - Double(y0)
        let fz = gz - Double(z0)

        let sy = nx
        let sz = nx * ny
        let i000 = (z0 * ny + y0) * nx + x0
        let i100 = i000 + 1
        let i010 = i000 + sy
        let i110 = i010 + 1
        let i001 = i000 + sz
        let i101 = i001 + 1
        let i011 = i001 + sy
        let i111 = i011 + 1

        if w[i000] <= 0 || w[i100] <= 0 || w[i010] <= 0 || w[i110] <= 0 { return nil }
        if w[i001] <= 0 || w[i101] <= 0 || w[i011] <= 0 || w[i111] <= 0 { return nil }

        let v000 = Double(phi[i000])
        let v100 = Double(phi[i100])
        let v010 = Double(phi[i010])
        let v110 = Double(phi[i110])
        let v001 = Double(phi[i001])
        let v101 = Double(phi[i101])
        let v011 = Double(phi[i011])
        let v111 = Double(phi[i111])

        let c00 = v000 * (1 - fx) + v100 * fx
        let c10 = v010 * (1 - fx) + v110 * fx
        let c01 = v001 * (1 - fx) + v101 * fx
        let c11 = v011 * (1 - fx) + v111 * fx
        let c0 = c00 * (1 - fy) + c10 * fy
        let c1 = c01 * (1 - fy) + c11 * fy
        let val = c0 * (1 - fz) + c1 * fz

        let ax: Double = (v100 - v000) * (1 - fy) * (1 - fz) + (v110 - v010) * fy * (1 - fz)
        let bx: Double = (v101 - v001) * (1 - fy) * fz + (v111 - v011) * fy * fz
        let ay: Double = (v010 - v000) * (1 - fx) * (1 - fz) + (v110 - v100) * fx * (1 - fz)
        let by: Double = (v011 - v001) * (1 - fx) * fz + (v111 - v101) * fx * fz
        let az: Double = (v001 - v000) * (1 - fx) * (1 - fy) + (v101 - v100) * fx * (1 - fy)
        let bz: Double = (v011 - v010) * (1 - fx) * fy + (v111 - v110) * fx * fy
        let g = V3(ax + bx, ay + by, az + bz) / voxel
        return TSDFSample(value: val, grad: g)
    }

    // MARK: Recalage direct d'une trame sur le modèle

    /// Retourne la correction C (repère visage) à appliquer aux points rétroprojetés : Tq_nouveau = Tq ∘ C⁻¹.
    func refine(depth: [Float], intr: Intrinsics, pose: RigidPose,
                step: Int, iters: Int, maxT: Double, maxDeg: Double, minPts: Int) -> (correction: RigidPose, count: Int, ok: Bool) {
        let W = intr.width
        let H = intr.height
        let inv = pose.inverse()
        var pts = [V3]()
        pts.reserveCapacity((W / step) * (H / step))
        var v = 0
        while v < H {
            var u = 0
            while u < W {
                let d = depth[v * W + u]
                if d > 0.05 && d < 1.5 {
                    let dd = Double(d)
                    let q = V3((Double(u) - intr.cx) * dd / intr.fx, (Double(v) - intr.cy) * dd / intr.fy, dd)
                    pts.append(inv.apply(q))
                }
                u += step
            }
            v += step
        }

        var C = RigidPose.identity
        var nsel = 0
        var J = [Double](repeating: 0, count: 6)
        let half = 0.5 * trunc

        for _ in 0..<iters {
            var A = [Double](repeating: 0, count: 36)
            var b = [Double](repeating: 0, count: 6)
            nsel = 0
            for p0 in pts {
                let pc: V3 = C.apply(p0)
                guard let s = sample(pc) else { continue }
                if abs(s.value) >= 0.8 { continue }
                let r = s.value * trunc
                let g: V3 = s.grad * trunc
                let wgt = 1.0 / max(1.0, abs(r) / half)
                let jr: V3 = simd_cross(pc, g)
                J[0] = jr.x; J[1] = jr.y; J[2] = jr.z
                J[3] = g.x; J[4] = g.y; J[5] = g.z
                for a in 0..<6 {
                    let wa = wgt * J[a]
                    b[a] -= wa * r
                    for c in a..<6 {
                        A[a * 6 + c] += wa * J[c]
                    }
                }
                nsel += 1
            }
            if nsel < minPts {
                return (RigidPose.identity, nsel, false)
            }
            for a in 0..<6 {
                for c in 0..<a {
                    A[a * 6 + c] = A[c * 6 + a]
                }
                A[a * 6 + a] += 1e-9
            }
            guard let x = solveLinear(A, b, n: 6) else {
                return (RigidPose.identity, nsel, false)
            }
            let th = V3(x[0], x[1], x[2])
            let tv = V3(x[3], x[4], x[5])
            let dT = RigidPose(R: rodrigues(th), t: tv)
            C = dT.compose(C)
        }
        let tn = simd_length(C.t)
        if !(tn <= maxT) || !(C.rotationAngleDegrees <= maxDeg) {
            return (RigidPose.identity, nsel, false)
        }
        return (C, nsel, true)
    }
}
