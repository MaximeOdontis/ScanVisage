import Foundation
import CoreGraphics
import simd

/// Maillage texturé lu depuis l'OBJ produit par Object Capture.
struct TexturedMesh {
    var vertices: [SIMD3<Double>] = []
    var uvs: [SIMD2<Float>] = []
    var faces: [(v: SIMD3<Int32>, t: SIMD3<Int32>)] = []   // indices à partir de 0, t = -1 si absent
    var texture: URL?
    var colors: [SIMD3<UInt8>] = []

    // MARK: Lecture OBJ

    static func loadOBJ(_ url: URL) throws -> TexturedMesh {
        var m = TexturedMesh()
        let text = try String(contentsOf: url, encoding: .utf8)
        var mtlName: String?
        text.enumerateLines { line, _ in
            if line.hasPrefix("v ") {
                let p = line.split(separator: " ", omittingEmptySubsequences: true)
                if p.count >= 4, let x = Double(p[1]), let y = Double(p[2]), let z = Double(p[3]) {
                    m.vertices.append(SIMD3(x, y, z))
                }
            } else if line.hasPrefix("vt ") {
                let p = line.split(separator: " ", omittingEmptySubsequences: true)
                if p.count >= 3, let u = Float(p[1]), let v = Float(p[2]) {
                    m.uvs.append(SIMD2(u, v))
                }
            } else if line.hasPrefix("f ") {
                let p = line.split(separator: " ", omittingEmptySubsequences: true).dropFirst()
                var vi = [Int32]()
                var ti = [Int32]()
                for tok in p {
                    let parts = tok.split(separator: "/", omittingEmptySubsequences: false)
                    guard let a = Int(parts[0]) else { continue }
                    let v = a > 0 ? a - 1 : m.vertices.count + a
                    var t = -1
                    if parts.count > 1, let b = Int(parts[1]) {
                        t = b > 0 ? b - 1 : m.uvs.count + b
                    }
                    vi.append(Int32(v))
                    ti.append(Int32(t))
                }
                if vi.count >= 3 {
                    for k in 1..<(vi.count - 1) {   // éventail si polygone
                        m.faces.append((SIMD3(vi[0], vi[k], vi[k + 1]), SIMD3(ti[0], ti[k], ti[k + 1])))
                    }
                }
            } else if line.hasPrefix("mtllib ") {
                mtlName = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let name = mtlName {
            let mtlURL = url.deletingLastPathComponent().appendingPathComponent(name)
            if let mtl = try? String(contentsOf: mtlURL, encoding: .utf8) {
                mtl.enumerateLines { line, stop in
                    let l = line.trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("map_Kd ") {
                        let file = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                        m.texture = url.deletingLastPathComponent().appendingPathComponent(file)
                        stop = true
                    }
                }
            }
        }
        return m
    }

    // MARK: Transformations

    mutating func transform(_ f: (SIMD3<Double>) -> SIMD3<Double>) {
        for i in 0..<vertices.count { vertices[i] = f(vertices[i]) }
    }

    /// Garde les triangles dont les trois sommets satisfont `keep`, puis renumérote.
    mutating func crop(_ keep: (SIMD3<Double>) -> Bool) {
        let flags = vertices.map(keep)
        crop(vertexFlags: flags)
    }

    mutating func crop(vertexFlags: [Bool]) {
        var ok = vertexFlags
        var used = [Bool](repeating: false, count: vertices.count)
        var newFaces = [(v: SIMD3<Int32>, t: SIMD3<Int32>)]()
        for f in faces {
            let a = Int(f.v.x)
            let b = Int(f.v.y)
            let c = Int(f.v.z)
            if a < ok.count, b < ok.count, c < ok.count, ok[a], ok[b], ok[c] {
                newFaces.append(f)
                used[a] = true
                used[b] = true
                used[c] = true
            }
        }
        ok = used
        var remap = [Int32](repeating: -1, count: vertices.count)
        var newV = [SIMD3<Double>]()
        var newC = [SIMD3<UInt8>]()
        let hasColors = colors.count == vertices.count
        for i in 0..<vertices.count where ok[i] {
            remap[i] = Int32(newV.count)
            newV.append(vertices[i])
            if hasColors { newC.append(colors[i]) }
        }
        for k in 0..<newFaces.count {
            let f = newFaces[k].v
            newFaces[k].v = SIMD3(remap[Int(f.x)], remap[Int(f.y)], remap[Int(f.z)])
        }
        vertices = newV
        faces = newFaces
        if hasColors { colors = newC }
    }

    /// Garde la plus grande composante connexe (retire les îlots flottants).
    mutating func keepLargestComponent() {
        let n = vertices.count
        if n == 0 { return }
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r {
                parent[r] = parent[parent[r]]
                r = parent[r]
            }
            return r
        }
        for f in faces {
            let a = find(Int(f.v.x))
            let b = find(Int(f.v.y))
            if a != b { parent[b] = a }
            let c = find(Int(f.v.z))
            let a2 = find(Int(f.v.x))
            if c != a2 { parent[c] = a2 }
        }
        var count = [Int](repeating: 0, count: n)
        for f in faces { count[find(Int(f.v.x))] += 1 }
        var best = 0
        for i in 0..<n where count[i] > count[best] { best = i }
        var keepVertex = [Bool](repeating: false, count: n)
        for i in 0..<n { keepVertex[i] = find(i) == best }
        crop(vertexFlags: keepVertex)
    }

    // MARK: Allègement hors d'une zone

    /// Fusionne les sommets situés hors de la zone `keep` par cellules de `cell` (mètres), en moyennant leurs positions.
    /// Les sommets de la zone sont conservés tels quels (pleine densité). Les coordonnées de texture des triangles
    /// ne changent pas. À faire avant `bakeVertexColors`.
    mutating func decimateOutside(keep: (SIMD3<Double>) -> Bool, cell: Double) {
        struct Key: Hashable {
            var x: Int32
            var y: Int32
            var z: Int32
        }
        var remap = [Int32](repeating: -1, count: vertices.count)
        var newV = [SIMD3<Double>]()
        var sums = [SIMD3<Double>]()
        var counts = [Int]()                  // 0 : sommet conservé tel quel
        var cells = [Key: Int32]()
        for i in 0..<vertices.count {
            let p = vertices[i]
            if keep(p) {
                remap[i] = Int32(newV.count)
                newV.append(p)
                sums.append(p)
                counts.append(0)
            } else {
                let k = Key(x: Int32(floor(p.x / cell)), y: Int32(floor(p.y / cell)), z: Int32(floor(p.z / cell)))
                if let j = cells[k] {
                    remap[i] = j
                    sums[Int(j)] += p
                    counts[Int(j)] += 1
                } else {
                    let j = Int32(newV.count)
                    cells[k] = j
                    remap[i] = j
                    newV.append(p)
                    sums.append(p)
                    counts.append(1)
                }
            }
        }
        for j in 0..<newV.count where counts[j] > 0 {
            newV[j] = sums[j] / Double(counts[j])
        }
        var newFaces = [(v: SIMD3<Int32>, t: SIMD3<Int32>)]()
        newFaces.reserveCapacity(faces.count)
        for f in faces {
            let a = remap[Int(f.v.x)]
            let b = remap[Int(f.v.y)]
            let c = remap[Int(f.v.z)]
            if a == b || b == c || a == c { continue }
            newFaces.append((SIMD3<Int32>(a, b, c), f.t))
        }
        vertices = newV
        faces = newFaces
        colors = []
    }

    // MARK: Couleurs par sommet depuis la texture

    mutating func bakeVertexColors() {
        guard let url = texture, let cg = Images.cgImage(url) else { return }
        let W = cg.width
        let H = cg.height
        let px = Images.rgbaPixels(cg)
        var col = [SIMD3<UInt8>](repeating: SIMD3(200, 200, 200), count: vertices.count)
        var done = [Bool](repeating: false, count: vertices.count)
        for f in faces {
            let vs = [f.v.x, f.v.y, f.v.z]
            let ts = [f.t.x, f.t.y, f.t.z]
            for k in 0..<3 {
                let vi = Int(vs[k])
                let ti = Int(ts[k])
                if done[vi] || ti < 0 || ti >= uvs.count { continue }
                let uv = uvs[ti]
                let x = min(W - 1, max(0, Int(uv.x * Float(W))))
                let y = min(H - 1, max(0, Int((1 - uv.y) * Float(H))))
                let o = (y * W + x) * 4
                col[vi] = SIMD3(px[o], px[o + 1], px[o + 2])
                done[vi] = true
            }
        }
        colors = col
    }

    var centroid: SIMD3<Double> {
        var c = SIMD3<Double>(0, 0, 0)
        for v in vertices { c += v }
        return vertices.isEmpty ? c : c / Double(vertices.count)
    }

    // MARK: Écriture (unités : celles des sommets)

    func writeSTL(_ url: URL, scale: Double) throws {
        var data = Data(count: 84 + 50 * faces.count)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let header = Array("FaceRebuild STL mm".utf8)
            for (i, b) in header.enumerated() { raw[i] = b }
            put32(raw, 80, UInt32(faces.count))
            var off = 84
            for f in faces {
                let a = vertices[Int(f.v.x)] * scale
                let b = vertices[Int(f.v.y)] * scale
                let c = vertices[Int(f.v.z)] * scale
                var n = simd_cross(b - a, c - a)
                let l = simd_length(n)
                n = l > 0 ? n / l : SIMD3(0, 0, 1)
                for v in [n, a, b, c] {
                    put32(raw, off, Float(v.x).bitPattern)
                    put32(raw, off + 4, Float(v.y).bitPattern)
                    put32(raw, off + 8, Float(v.z).bitPattern)
                    off += 12
                }
                off += 2
            }
        }
        try data.write(to: url, options: .atomic)
    }

    func writePLY(_ url: URL, scale: Double) throws {
        let hasColors = colors.count == vertices.count
        let header = "ply\nformat binary_little_endian 1.0\ncomment FaceRebuild, millimetres\nelement vertex \(vertices.count)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face \(faces.count)\nproperty list uchar int vertex_indices\nend_header\n"
        var data = Data(header.utf8)
        var body = Data(count: vertices.count * 15 + faces.count * 13)
        body.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            var off = 0
            for i in 0..<vertices.count {
                let p = vertices[i] * scale
                put32(raw, off, Float(p.x).bitPattern)
                put32(raw, off + 4, Float(p.y).bitPattern)
                put32(raw, off + 8, Float(p.z).bitPattern)
                let c = hasColors ? colors[i] : SIMD3<UInt8>(200, 200, 200)
                raw[off + 12] = c.x
                raw[off + 13] = c.y
                raw[off + 14] = c.z
                off += 15
            }
            for f in faces {
                raw[off] = 3
                put32(raw, off + 1, UInt32(bitPattern: f.v.x))
                put32(raw, off + 5, UInt32(bitPattern: f.v.y))
                put32(raw, off + 9, UInt32(bitPattern: f.v.z))
                off += 13
            }
        }
        data.append(body)
        try data.write(to: url, options: .atomic)
    }

    /// OBJ texturé (copie la texture à côté).
    func writeOBJ(_ url: URL, scale: Double) throws {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var texName: String?
        if let tex = texture {
            let name = base + "_texture." + tex.pathExtension
            let dest = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: tex, to: dest)
            texName = name
            let mtl = "newmtl visage\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nmap_Kd \(name)\n"
            try mtl.write(to: dir.appendingPathComponent(base + ".mtl"), atomically: true, encoding: .utf8)
        }
        var s = ""
        s.reserveCapacity(vertices.count * 40 + faces.count * 30)
        if texName != nil { s += "mtllib \(base).mtl\nusemtl visage\n" }
        for v in vertices {
            let p = v * scale
            s += String(format: "v %.4f %.4f %.4f\n", p.x, p.y, p.z)
        }
        for t in uvs { s += String(format: "vt %.6f %.6f\n", t.x, t.y) }
        let withUV = texName != nil && !uvs.isEmpty
        for f in faces {
            if withUV && f.t.x >= 0 && f.t.y >= 0 && f.t.z >= 0 {
                s += "f \(f.v.x + 1)/\(f.t.x + 1) \(f.v.y + 1)/\(f.t.y + 1) \(f.v.z + 1)/\(f.t.z + 1)\n"
            } else {
                s += "f \(f.v.x + 1) \(f.v.y + 1) \(f.v.z + 1)\n"
            }
        }
        try s.write(to: url, atomically: true, encoding: .utf8)
    }
}

private func put32(_ raw: UnsafeMutableRawBufferPointer, _ off: Int, _ v: UInt32) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { src in
        raw.baseAddress!.advanced(by: off).copyMemory(from: src.baseAddress!, byteCount: 4)
    }
}
