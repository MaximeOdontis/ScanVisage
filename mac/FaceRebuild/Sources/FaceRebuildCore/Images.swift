import Foundation
import CoreVideo
import CoreGraphics
import ImageIO

enum Images {

    /// Charge une image (JPEG, PNG) dans un CVPixelBuffer BGRA, sans rotation.
    static func pixelBuffer(_ url: URL) -> CVPixelBuffer? {
        guard let cg = cgImage(url) else { return nil }
        let w = cg.width
        let h = cg.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    static func cgImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Pixels en niveaux de gris (8 bits), ligne par ligne depuis le haut.
    static func grayPixels(_ cg: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cg.width * cg.height)
        out.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                   bytesPerRow: cg.width, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
        }
        return out
    }

    /// Pixels RGBA (8 bits par canal), ligne par ligne depuis le haut.
    static func rgbaPixels(_ cg: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        out.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                   bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
        }
        return out
    }

    /// Masque de la tête à la taille de l'image brute (paysage) : masque de personne de l'iPhone
    /// (redressé en portrait) intersecté avec une ellipse autour du rectangle du visage (cheveux et oreilles inclus,
    /// épaules exclues). Retourne nil si aucune information de masque n'est disponible.
    static func headMask(frame f: PhotoFrame, folder: URL, width W: Int, height H: Int) -> CVPixelBuffer? {
        var person: [UInt8]?
        var mw = 0
        var mh = 0
        if let name = f.mask, let cg = cgImage(folder.appendingPathComponent(name)) {
            person = grayPixels(cg)
            mw = cg.width
            mh = cg.height
        }
        let box = f.faceBox
        if person == nil && box == nil { return nil }
        // Le masque Vision est normalement dans l'image redressée (portrait). S'il est en paysage, il est brut.
        let maskIsPortrait = mh >= mw

        // Ellipse de la tête dans l'image redressée (portrait : largeur H, hauteur W), coordonnées pixel depuis le haut
        var ell: (cx: Double, cy: Double, ax: Double, ay: Double)?
        if let b = box, b.count == 4 {
            let uw = Double(H)
            let uh = Double(W)
            let cxn = b[0] + b[2] / 2
            // centre remonté : inclut front et cheveux ; bas de l'ellipse un tiers de visage sous le menton
            // (le cou et les épaules sont exclus, les polygones restent sur le visage)
            let cyn = b[1] + b[3] * 0.65
            ell = (cxn * uw, (1 - cyn) * uh, b[2] * 0.9 * uw, b[3] * 1.0 * uh)
        }

        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, W, H, kCVPixelFormatType_OneComponent8,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary,
                                  &pb) == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buf)
        for v in 0..<H {
            let row = base.advanced(by: v * stride).assumingMemoryBound(to: UInt8.self)
            for u in 0..<W {
                // pixel brut (u, v) -> image redressée par rotation horaire : u' = H - 1 - v, v' = u
                let up = Double(H - 1 - v)
                let vp = Double(u)
                var inside = true
                if let e = ell {
                    let dx = (up - e.cx) / e.ax
                    let dy = (vp - e.cy) / e.ay
                    inside = dx * dx + dy * dy <= 1
                }
                if inside, let p = person {
                    let mx: Int
                    let my: Int
                    if maskIsPortrait {
                        mx = min(mw - 1, Int(up / Double(H) * Double(mw)))
                        my = min(mh - 1, Int(vp / Double(W) * Double(mh)))
                    } else {
                        mx = min(mw - 1, Int(Double(u) / Double(W) * Double(mw)))
                        my = min(mh - 1, Int(Double(v) / Double(H) * Double(mh)))
                    }
                    inside = p[my * mw + mx] > 127
                }
                row[u] = inside ? 255 : 0
            }
        }
        return buf
    }
}
