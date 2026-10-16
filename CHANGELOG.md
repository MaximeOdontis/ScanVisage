# Journal des versions

Règle : à chaque livraison, mettre à jour ce fichier, `VERSION`, `AppInfo.version` (iOS, PhotoCaptureManager.swift) et `ToolVersion.current` (Mac, Version.swift). Le zip livré porte le numéro dans son nom.

## 2.0.4
- Correction de compilation iPhone : conflit de nom `Scene` entre SwiftUI et RealityKit. Le test de compatibilité est déplacé dans `PhotogrammetryCheck.swift`.

## 2.0.3
- App iPhone : bouton « Tester le calcul sur ce téléphone » (écran d'accueil) qui indique si Object Capture est supporté sur l'appareil.

## 2.0.2
- Icône de l'application Mac (`mac/AppIcon.icns`), ajoutée automatiquement à Reconstruction Visage.app.

## 2.0.1
- Correction de compilation Mac : la texture 16K (qualités Ultra et HD+Mouth) n'existe que sous macOS 15 ou plus ; sous macOS 14 la texture reste en 8K.

## 2.0.0 HD+Mouth
- Capture iPhone : option « HD+Mouth », deuxième séquence de près sur la bouche (photos prises automatiquement dès que l'image est nette et que le téléphone a bougé de 2,5 cm ou 8°, 12 à 40 photos), mise au point refaite sur la bouche.
- Mac : qualité « HD+Mouth » (3 000 000 de polygones), maillage conservé en pleine densité dans une zone autour de la bouche (centre déduit des axes optiques de la séquence bouche), allégé ailleurs. Exports : `visage_HD_bouche.stl/.ply/.obj` et `bouche_HD.stl/.ply` (zone bouche seule, même repère).
- Export iPhone : le dossier de capture peut être renommé avant le partage du zip.
- Numéro de version affiché dans l'app iPhone, la fenêtre Mac, `capture.json` et `rapport.json`.

## 1.x (non numérotées)
- Mode TrueDepth, mode Photo HD (caméra arrière, reconstruction Object Capture), application Mac à double-clic, qualités Standard à Ultra, modes de capture Rapide/Standard/Précis.
