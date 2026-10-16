import Foundation
import CoreVideo
import ARKit
import simd

/// Image couleur de la caméra frontale (YCbCr 4:2:0 recopié), avec ses intrinsèques.
/// Le repère est celui du capteur : x vers la droite de l'image, y vers le bas, z devant.
/// La carte de profondeur ARKit est alignée sur cette caméra (même centre optique).
struct ColorFrame {
    let width: Int
    let height: Int
    let yPlane: [UInt8]       // width * height
    let cbcr: [UInt8]         // (width / 2) * (height / 2) * 2, Cb puis Cr entrelacés
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    let videoRange: Bool

    /// Copie le tampon ARKit. Retourne nil si le format n'est pas du YCbCr biplanaire 4:2:0.
    static func capture(_ buffer: CVPixelBuffer, camera: ARCamera) -> ColorFrame? {
        let fmt = CVPixelBufferGetPixelFormatType(buffer)
        let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let video = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if !(full || video) || CVPixelBufferGetPlaneCount(buffer) < 2 { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let ch = CVPixelBufferGetHeightOfPlane(buffer, 1)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        var yArr = [UInt8](repeating: 0, count: w * h)
        yArr.withUnsafeMutableBytes { dst in
            for r in 0..<h {
                memcpy(dst.baseAddress!.advanced(by: r * w), yBase.advanced(by: r * yStride), w)
            }
        }
        var cArr = [UInt8](repeating: 128, count: cw * ch * 2)
        cArr.withUnsafeMutableBytes { dst in
            for r in 0..<ch {
                memcpy(dst.baseAddress!.advanced(by: r * cw * 2), cBase.advanced(by: r * cStride), cw * 2)
            }
        }

        let k = camera.intrinsics
        let res = camera.imageResolution
        let sx = Double(w) / Double(res.width)
        let sy = Double(h) / Double(res.height)
        return ColorFrame(width: w, height: h, yPlane: yArr, cbcr: cArr,
                          fx: Double(k.columns.0.x) * sx, fy: Double(k.columns.1.y) * sy,
                          cx: Double(k.columns.2.x) * sx, cy: Double(k.columns.2.y) * sy,
                          videoRange: video)
    }

    /// Couleur RGB (0 à 255) au pixel flottant (u, v). nil hors image.
    func rgb(u: Double, v: Double) -> SIMD3<Float>? {
        if !(u >= 1 && v >= 1 && u < Double(width - 2) && v < Double(height - 2)) { return nil }
        let x0 = Int(u)
        let y0 = Int(v)
        let ax = Float(u - Double(x0))
        let ay = Float(v - Double(y0))
        let i = y0 * width + x0
        let y00 = Float(yPlane[i])
        let y10 = Float(yPlane[i + 1])
        let y01 = Float(yPlane[i + width])
        let y11 = Float(yPlane[i + width + 1])
        let top = y00 * (1 - ax) + y10 * ax
        let bot = y01 * (1 - ax) + y11 * ax
        let yy = top * (1 - ay) + bot * ay

        let cw = width / 2
        let ci = (min(Int(v * 0.5), height / 2 - 1) * cw + min(Int(u * 0.5), cw - 1)) * 2
        let cb = Float(cbcr[ci]) - 128
        let cr = Float(cbcr[ci + 1]) - 128

        var yv = yy
        var kr: Float = 1.402
        var kgb: Float = 0.344136
        var kgr: Float = 0.714136
        var kb: Float = 1.772
        if videoRange {
            yv = (yy - 16) * 1.164383
            kr *= 1.138393
            kgb *= 1.138393
            kgr *= 1.138393
            kb *= 1.138393
        }
        let r = yv + kr * cr
        let g = yv - kgb * cb - kgr * cr
        let b = yv + kb * cb
        return SIMD3<Float>(min(255, max(0, r)), min(255, max(0, g)), min(255, max(0, b)))
    }

    /// Projette un point du repère capteur et retourne sa couleur.
    func color(atSensorPoint p: V3) -> SIMD3<Float>? {
        if !(p.z > 0.05) { return nil }
        let u = fx * p.x / p.z + cx
        let v = fy * p.y / p.z + cy
        return rgb(u: u, v: v)
    }
}
