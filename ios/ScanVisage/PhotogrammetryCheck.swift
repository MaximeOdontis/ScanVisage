import UIKit
import RealityKit

/// Test de compatibilité d'Object Capture (PhotogrammetrySession) sur l'appareil.
/// Fichier séparé : RealityKit définit aussi un type « Scene » qui entre en conflit avec SwiftUI dans ScanVisageApp.swift.
enum PhotogrammetryCheck {
    static func run() -> String {
        var info = utsname()
        uname(&info)
        let model = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let os = UIDevice.current.systemVersion
        let head = "Appareil \(model), iOS \(os), app \(AppInfo.version)\n"
        if #available(iOS 17.0, *) {
            if PhotogrammetrySession.isSupported {
                return head + "Object Capture est SUPPORTÉ sur cet appareil : un calcul sur le téléphone est possible (qualité limitée par la mémoire, niveaux de détail à tester)."
            } else {
                return head + "Object Capture n'est PAS supporté sur cet appareil : la reconstruction doit se faire sur le Mac."
            }
        } else {
            return head + "iOS 17 ou plus est requis pour Object Capture sur iPhone."
        }
    }
}
