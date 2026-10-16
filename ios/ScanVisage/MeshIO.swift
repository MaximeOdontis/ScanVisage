import Foundation
import simd

enum MeshIO {

    /// Écriture d'un entier 32 bits little endian à un offset quelconque (sans contrainte d'alignement).
    private static func put32(_ raw: UnsafeMutableRawBufferPointer, _ off: Int, _ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { src in
            raw.baseAddress!.advanced(by: off).copyMemory(from: src.baseAddress!, byteCount: 4)
        }
    }

    /// STL binaire. Unités : millimètres (les sommets sont en mètres). Le maillage est centré sur son barycentre.
    /// Axes : X = gauche du patient, Y = haut, Z = vers l'observateur.
    static func writeBinarySTL(_ m: Mesh, to url: URL) throws {
        let nTri = m.triangleCount
        var c = SIMD3<Float>(0, 0, 0)
        for v in m.vertices { c += v }
        if !m.vertices.isEmpty { c /= Float(m.vertices.count) }
        let scale: Float = 1000

        var data = Data(count: 84 + 50 * nTri)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let header = Array("ScanVisage STL mm".utf8)
            for (i, byte) in header.enumerated() where i < 80 {
                raw[i] = byte
            }
            raw.storeBytes(of: UInt32(nTri).littleEndian, toByteOffset: 80, as: UInt32.self)
            var off = 84
            for t in 0..<nTri {
                let a: SIMD3<Float> = (m.vertices[Int(m.indices[3 * t])] - c) * scale
                let b: SIMD3<Float> = (m.vertices[Int(m.indices[3 * t + 1])] - c) * scale
                let d: SIMD3<Float> = (m.vertices[Int(m.indices[3 * t + 2])] - c) * scale
                var nrm: SIMD3<Float> = simd_cross(b - a, d - a)
                let len = simd_length(nrm)
                if len > 0 { nrm /= len } else { nrm = SIMD3<Float>(0, 0, 1) }
                let floats: [Float] = [nrm.x, nrm.y, nrm.z, a.x, a.y, a.z, b.x, b.y, b.z, d.x, d.y, d.z]
                for f in floats {
                    raw.storeBytes(of: f.bitPattern.littleEndian, toByteOffset: off, as: UInt32.self)
                    off += 4
                }
                off += 2   // attribut (déjà à zéro)
            }
        }
        try data.write(to: url, options: .atomic)
    }

    /// PLY binaire little endian, x y z en float (mètres), couleur RGB optionnelle (3 octets par point).
    static func writePLY(points: [Float], colors: [UInt8]? = nil, to url: URL) throws {
        let n = points.count / 3
        let withColor = (colors?.count ?? 0) == n * 3 && n > 0
        var header = "ply\nformat binary_little_endian 1.0\nelement vertex \(n)\nproperty float x\nproperty float y\nproperty float z\n"
        if withColor {
            header += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        }
        header += "end_header\n"
        var data = Data(header.utf8)
        if !withColor {
            points.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        } else if let col = colors {
            let rec = 15
            var body = Data(count: n * rec)
            body.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                var off = 0
                for i in 0..<n {
                    put32(raw, off, points[3 * i].bitPattern)
                    put32(raw, off + 4, points[3 * i + 1].bitPattern)
                    put32(raw, off + 8, points[3 * i + 2].bitPattern)
                    raw[off + 12] = col[3 * i]
                    raw[off + 13] = col[3 * i + 1]
                    raw[off + 14] = col[3 * i + 2]
                    off += rec
                }
            }
            data.append(body)
        }
        try data.write(to: url, options: .atomic)
    }

    /// PLY binaire du maillage : sommets en millimètres (centrés sur le barycentre, comme le STL),
    /// couleur RGB par sommet (gris clair si le maillage n'est pas coloré) et faces triangulaires.
    static func writeMeshPLY(_ m: Mesh, to url: URL) throws {
        let nv = m.vertices.count
        let nt = m.triangleCount
        var c = SIMD3<Float>(0, 0, 0)
        for v in m.vertices { c += v }
        if nv > 0 { c /= Float(nv) }
        let scale: Float = 1000
        let colored = m.hasColors

        let header = "ply\nformat binary_little_endian 1.0\ncomment ScanVisage maillage en mm\nelement vertex \(nv)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face \(nt)\nproperty list uchar int vertex_indices\nend_header\n"
        var data = Data(header.utf8)
        var body = Data(count: nv * 15 + nt * 13)
        body.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            var off = 0
            for i in 0..<nv {
                let p: SIMD3<Float> = (m.vertices[i] - c) * scale
                put32(raw, off, p.x.bitPattern)
                put32(raw, off + 4, p.y.bitPattern)
                put32(raw, off + 8, p.z.bitPattern)
                if colored {
                    let col = m.colors[i]
                    raw[off + 12] = col.x
                    raw[off + 13] = col.y
                    raw[off + 14] = col.z
                } else {
                    raw[off + 12] = 215
                    raw[off + 13] = 215
                    raw[off + 14] = 215
                }
                off += 15
            }
            for t in 0..<nt {
                raw[off] = 3
                put32(raw, off + 1, UInt32(m.indices[3 * t]))
                put32(raw, off + 5, UInt32(m.indices[3 * t + 1]))
                put32(raw, off + 9, UInt32(m.indices[3 * t + 2]))
                off += 13
            }
        }
        data.append(body)
        try data.write(to: url, options: .atomic)
    }
}
