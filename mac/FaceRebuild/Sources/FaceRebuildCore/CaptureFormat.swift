import Foundation

/// Même format que l'app iPhone (PhotoCaptureManager.swift).
struct PhotoFrame: Codable {
    let index: Int
    let image: String
    let mask: String?
    let width: Int
    let height: Int
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    let cameraToWorld: [Float]
    let azimuthDeg: Double
    let elevationDeg: Double
    let distance: Double
    let faceBox: [Double]?
    let maskOrientation: String
    let timestamp: Double
    let segment: String?          // "visage" ou "bouche" (HD+Mouth) ; absent dans les anciennes captures
}

struct PhotoCapture: Codable {
    let version: Int
    let device: String
    let date: String
    let faceCenter: [Float]
    let frontal: [Float]
    let frames: [PhotoFrame]
    let appVersion: String?
}
