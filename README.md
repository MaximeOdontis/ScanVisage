# Scan Visage : visage du patient en STL avec un iPhone

L'app propose deux modes au lancement :

- **Photo HD (recommandé)** : caméra arrière, photos haute résolution prises automatiquement pendant que l'opérateur tourne autour du patient immobile, puis **reconstruction photogrammétrique sur Mac** (Object Capture d'Apple) avec l'outil `mac/FaceRebuild`. C'est la technique des applications de scan facial dentaire du commerce : le détail (pores, rides, dents avec écarteur) vient des photos. Voir la section **Photo HD** ci-dessous.
- **TrueDepth** : caméra frontale, calcul sur l'iPhone. Rapide, mais limité par le capteur de profondeur (640 x 480 points, environ 1 mm de bruit). Décrit dans le reste de ce document.

## Photo HD : caméra arrière et reconstruction sur Mac

### Capture sur l'iPhone

1. Patient assis, tête appuyée si possible, expression constante, écarteur (type OptraGate) si les dents doivent être visibles. Lumière **diffuse et constante** (pas de soleil direct, pas de flash), fond quelconque (il est masqué).
2. Dans l'app : **Photo HD**. Téléphone en portrait, caméra arrière vers le visage, à 30 à 40 cm. L'opérateur voit l'écran.
3. Touchez **Démarrer (de face)** et restez de face environ une seconde : l'app repère le visage, puis **verrouille l'exposition, la balance des blancs et la mise au point** (indispensable pour une texture homogène).
3 bis. **Choisir le mode** avant de démarrer : **Rapide** (environ 20 photos, 30 à 45 s, 2 anneaux : dessus et face, pas de dessous), **Standard** (37 photos, ce qui est décrit ci-dessous), **Précis** (environ 65 photos, 4 anneaux, plus près : 25 à 30 cm, 2 à 3 min). Les durées et nombres de photos sont des estimations ; l'écart de qualité entre les modes n'a pas été mesuré, à comparer sur un même patient.
4. Tournez lentement autour du visage, sans vous arrêter. La grille en bas montre 37 positions : à hauteur du visage, tous les 10° de -80° (côté droit du patient) à +80° (côté gauche) ; au-dessus (+20°) et en dessous (-25°), tous les 15°. Une photo est prise automatiquement (petit son) en passant sur une case grise, **dès que le flou de bougé prévu est faible** : pas besoin de s'arrêter, il suffit de ralentir. La case devient verte ; le cadre jaune indique la case où vous êtes.
5. **Terminer** devient actif à 20 photos ; visez toutes les cases. La capture s'arrête seule quand les 37 sont prises. Durée habituelle : 40 s à 1 min 30.
6. **Partager (zip)** et envoyez le zip au Mac (AirDrop). Le dossier contient `img_XXX.jpg` (pleine résolution, orientation brute du capteur), `mask_XXX.png` (masque de la personne) et `capture.json` (pose ARKit et intrinsèques de chaque photo).

Conseils : plus la lumière est forte, plus l'exposition est courte et plus vous pouvez tourner vite (le seuil de flou s'adapte à l'exposition verrouillée au départ). Coudes près du corps ; pour l'anneau du dessous, abaissez-vous plutôt que de basculer le téléphone. Le visage est suivi par sa position 3D repérée au départ (et non plus par la détection de visage, qui échouait sur les profils) : gardez-le simplement dans la partie centrale de l'image.

### Version HD+Mouth (zone bouche en haute densité)

Pour comparer ensuite avec des empreintes 3D (scanner intra-oral, empreinte numérisée), la bouche peut être capturée de plus près et reconstruite en plus haute densité que le reste du visage.
- **iPhone :** activer « HD+Mouth » avant « Démarrer ». Faire d'abord la séquence visage comme d'habitude. À la fin, l'app demande de s'approcher de la bouche (environ 20 à 25 cm), de la centrer dans le repère jaune et de toucher « Démarrer la bouche » : la mise au point est refaite sur la bouche, puis balayer lentement de gauche à droite en 2 à 3 passages (un peu plus haut, face, un peu plus bas). Les photos sont prises seules (12 à 40). Le patient ne doit pas bouger entre les deux séquences : ne pas lui demander d'ouvrir ou de changer d'expression.
- **Export :** au moment du partage, le nom du dossier peut être modifié (le zip prend le même nom).
- **Mac :** dans Reconstruction Visage, le choix « HD+Mouth » est proposé automatiquement quand la capture contient une séquence bouche. Fichiers : `visage_HD_bouche.stl/.ply/.obj` (visage entier, bouche en pleine densité, reste allégé à 0,6 mm) et `bouche_HD.stl/.ply` (zone bouche seule, **même repère** que le visage).
- **Limites non vérifiées :** à 20 à 25 cm la profondeur de champ de l'objectif principal est de l'ordre de 1 à 2 cm (estimation), donc seules les lèvres et les dents antérieures seront nettes ; la distance minimale de mise au point de l'iPhone 15 Plus est à tester. La précision réelle de la zone bouche n'est pas mesurée et ne doit pas être présumée suffisante pour un recalage d'empreinte sans contrôle sur un modèle de référence. L'allègement par fusion de sommets hors de la bouche peut laisser quelques triangles irréguliers à la limite de la zone.

### Reconstruction sur le Mac

Prérequis : Mac Apple Silicon (M1 ou plus), macOS 14 ou plus, Xcode installé et ouvert au moins une fois.

**Sans Terminal.** Dans le dossier `mac/`, double-cliquer sur **`Reconstruction Visage.command`**.
- Première fois seulement : clic droit sur le fichier, **Ouvrir**, puis confirmer (macOS bloque les fichiers téléchargés). Une fenêtre de Terminal s'ouvre et prépare l'application pendant 2 à 5 minutes sans rien à taper, puis lance **Reconstruction Visage.app** (créée à côté). Fermer ensuite la fenêtre de Terminal.
- Ensuite, double-cliquer directement sur **Reconstruction Visage.app** (si macOS la bloque la première fois : clic droit, Ouvrir).
- Dans la fenêtre : **Choisir le dossier...** (le dossier des photos reçues de l'iPhone, ou directement le fichier `.zip` partagé, il est décompressé automatiquement; on peut aussi glisser le dossier dans la fenêtre), régler la qualité, **Lancer la reconstruction**. À la fin, **Ouvrir le dossier du résultat** (`resultat`, à côté des photos) : `visage.stl`, `visage_couleur.ply`, `visage.obj` + texture, `rapport.json`.
- Qualité : Standard 300 000 polygones, Élevé 600 000 (défaut), Maximum 1 000 000, Ultra 4 000 000 avec texture 16K (très long, 16 Go de mémoire ou plus conseillés, fichiers de plusieurs centaines de Mo). Au-delà de 600 000 polygones le gain de précision géométrique est faible : la limite est la résolution des photos, pas le maillage. L'aspect photo-réaliste vient de la texture : utiliser `visage.obj` avec `visage_texture.png`, le PLY n'a qu'une couleur par sommet. Compter quelques minutes sur un M3.

Ligne de commande (facultatif) : `cd mac/FaceRebuild && swift run -c release FaceRebuild <dossier_ou_zip> [dossier_sortie] [--polygons 600000] [--detail full|medium|reduced|raw] [--no-mask]`. Les avertissements `Failed to resolve reference ... baked_mesh_..._roughness0.png` sont internes à Object Capture et sans conséquence.

L'outil :
1. lance Object Capture (`PhotogrammetrySession`) avec un masque de la tête par photo (masque de personne de l'iPhone limité à une ellipse autour du visage : cheveux et oreilles gardés, épaules exclues) ;
2. récupère la position de chaque caméra et calcule la similitude (échelle, rotation, translation) qui les superpose aux positions ARKit : le modèle passe en **mètres réels** et vertical ;
3. place le maillage dans le repère du visage, le découpe (tête seule, plus grande partie connexe) ;
4. exporte dans `resultat/` : `visage.stl` (mm), `visage_couleur.ply` (mm, couleur par sommet), `visage.obj` + `visage.mtl` + texture (mm), `rapport.json`, et le modèle brut d'Object Capture dans `object_capture/`.

Repère des exports : X vers la gauche du patient, Y vers le haut, Z sortant du visage, origine au centre du maillage.

### Contrôles à faire

- `rapport.json` donne `ecartCamerasMm` : l'écart entre les positions de caméra d'Object Capture et celles d'ARKit après mise à l'échelle. Quelques millimètres : normal. Au-delà de 10 mm, le patient a bougé ou le suivi ARKit a dérivé : refaites la capture.
- **Échelle** : elle vient du suivi ARKit (centrale inertielle et caméra), précision attendue de l'ordre de 1 à 2 %, non mesurée ici. Pour un usage dentaire, vérifiez-la : collez une petite règle ou un repère de 10 mm sur le front, ou mesurez une distance au pied à coulisse (largeur de l'écarteur, distance intercanthale) et comparez dans le logiciel. Une étude sur Qlone, une application de photogrammétrie du commerce, utilisait justement un repère de 10 mm pour l'échelle.
- **Latéralité** : collez une pastille sur la joue droite du patient avant la capture et vérifiez sa position sur le modèle.
- Alignement avec l'empreinte optique : dans exocad ou 3Shape, par les dents (écarteur indispensable).

### État de validation du mode Photo HD

- Écrit sans Xcode ni iPhone : **ni compilé, ni testé**. Attendez-vous à des erreurs de compilation à me renvoyer.
- Le calcul de la similitude (Horn, valeurs propres par Jacobi) a été vérifié en Python sur des données simulées (échelle retrouvée à 0,01 %, rotation à moins de 0,05°).
- Non vérifié : le format exact des poses renvoyées par Object Capture (l'outil teste deux conventions et garde la meilleure), l'orientation du masque de personne (détectée automatiquement), le comportement d'Object Capture avec des photos de visage et des masques, la précision finale.
- Précision attendue d'après la littérature pour la photogrammétrie sur smartphone : erreur moyenne d'environ 1 mm sur des mesures linéaires du visage (Qlone, version antérieure : 0,98 ± 0,77 mm contre 0,75 ± 0,53 mm pour un système fixe 3dMD). À confirmer sur votre propre chaîne.

---

# Mode TrueDepth : calcul sur l'iPhone

Deux façons de scanner, au choix sur l'écran de départ :

- **Le téléphone tourne** (par défaut, le plus précis). Le patient reste immobile et regarde droit devant lui. Un opérateur tient le téléphone, écran et caméra frontale tournés vers le patient, à 30 cm, et le déplace autour du visage en suivant la voix : face, côté droit, côté gauche, dessous, dessus, puis les diagonales selon le mode.
- **La tête tourne**. Le téléphone est posé, le patient tourne la tête devant l'écran, qui se comporte comme un miroir. Utile pour se scanner seul, mais moins précis : quand la tête tourne ou s'incline, les tissus mous (joues, lèvres) se déplacent un peu. Mesuré sur un scan réel : après recalage, le front concorde entre les poses à 0,1 à 0,6 mm près, les joues et les lèvres sont décalées de 1 à 2 mm en médiane, jusqu'à 3 mm menton baissé.

Dans les deux cas, l'app détecte automatiquement quand l'angle est atteint : un son « cling », une vibration et « Stop ». On **tient la position** quelques secondes (de petits mouvements sont tolérés), puis une vibration indique de passer à la suite. À la fin, l'iPhone calcule lui-même le modèle (barre de progression) et l'exporte en STL et en PLY couleur.

Principe : ARKit (suivi du visage par la caméra TrueDepth) donne la position **approximative** de la caméra par rapport au visage, qui sert au guidage. C'est la même mesure que le téléphone ou la tête bouge. À chaque arrêt, l'app garde un à quatre blocs de profondeur (moyenne de quelques images où la tête n'a presque pas bougé) et une image couleur. Après la capture : filtre bilatéral de la profondeur, **recalage multivue ICP** de toutes les vues (les poses ARKit sont fausses de 1 à 3 cm sur les vues tournées, mesuré sur un scan réel), fusion dans un volume TSDF (voxels de 1,2 ou 1,5 mm, troncature de 7 mm), extraction de la surface (Surface Nets), lissage (Taubin), couleurs par projection dans les images, export en millimètres.

Le zip partagé contient :

```
pose_01.ply  pose_01.json   face
pose_02.ply  pose_02.json   profil_droit   (côté droit du visage vu par la caméra)
pose_03.ply  pose_03.json   profil_gauche
pose_04.ply  pose_04.json   dessous        (caméra sous le menton, ou menton levé)
pose_05.ply  pose_05.json   dessus         (caméra au-dessus du front, ou menton baissé)
visage.stl                  maillage fusionné, en mm
visage_couleur.ply          même maillage avec la couleur par sommet, en mm
```

Les cinq PLY de pose sont en mètres, dans le repère du capteur, avec la couleur (rouge, vert, bleu) de chaque point, et sont désormais des moyennes de plusieurs images. Le JSON contient `yawDeg`, `pitchDeg`, `sensorFromFace` (pose de la tête après recalage global), `framesAveraged`, `refinedShiftMm` et `refinedRotationDeg` (correction apportée à la pose ARKit : un contrôle qualité), et les intrinsèques de la caméra couleur. `captureStyle` vaut `phoneMoves` ou `headMoves`. Les poses sont nommées par le côté du visage vu, quel que soit le mode (les anciens noms droite, gauche, haut, bas restent lus). `python/process.py` utilise `sensorFromFace` pour initialiser son recalage.

Contenu du projet :

```
ios/ScanVisage/     13 fichiers Swift à copier dans un projet Xcode (les deux modes)
mac/Reconstruction Visage.command    fichier à double-cliquer (prépare puis ouvre l'application Mac)
mac/FaceRebuild/    code Mac de reconstruction du mode Photo HD (package Swift : bibliothèque, application, ligne de commande)
ios/Assets.xcassets      icône de l'app
python/process.py   reconstruction PLY -> STL (optionnel, voie Poisson sur Mac)
python/check_sphere.py   validation métrique avec un objet de diamètre connu
```

## État de validation (à lire avant tout)

- **Retraitement d'un scan réel** (5 poses envoyées le 12/10, nez à 37 cm) en Python, avec exactement les étapes du nouveau calcul : le visage est reconnaissable (nez, lèvres, menton, profil), en couleur, là où l'ancien calcul donnait une « éponge ». Les vues recalées s'emboîtent à 1,2 mm près (écart médian point-plan). Rugosité de la surface du visage (écart à une surface lisse locale de 5 mm) : 0,9 à 1,0 mm avec l'ancien réglage de fusion, 0,2 mm avec le nouveau.
- Ce que ce retraitement a montré :
  - les poses ARKit des vues tournées étaient fausses de 18 à 30 mm au niveau du visage, ce que l'ancien recalage (limité à 12 mm) ne pouvait pas corriger ;
  - la zone de la tête coupait le bout du nez et les côtés ;
  - le bruit du capteur est figé : 80 images moyennées sans bouger gardent environ 0,7 mm de bruit local. Ce sont les vues différentes qui le réduisent, d'où la tolérance aux petits mouvements et les blocs multiples par arrêt.
- Le même scan montre des écarts entre poses localisés sur les tissus mous (joues, lèvres : 1 à 2 mm en médiane, jusqu'à 3 mm menton baissé) alors que le front concorde à moins de 0,6 mm : cohérent avec un déplacement des tissus quand la tête bouge, d'où le mode « le téléphone tourne ». Une partie de ces écarts vient aussi du capteur sur les surfaces obliques (1,3 mm sur le nez, qui ne se déforme pas). Le mode opérateur n'a pas encore été essayé.
- Plusieurs initialisations différentes du recalage donnent des poses un peu différentes (le visage est une surface lisse qui peut « glisser »), mais des formes de visage visuellement identiques. Pas de mesure de précision absolue possible sans objet de référence (étape 8).
- Le code Swift **n'a pas été compilé ni exécuté** (pas de Xcode ni d'iPhone ici). Il reprend la logique validée en Python, ligne à ligne pour le recalage. Attendez-vous à quelques erreurs de compilation : copiez les messages Xcode et renvoyez-les.
- Non vérifiable sans iPhone : l'effet des blocs multiples par arrêt, la vitesse de calcul. Le sens droite/gauche suit maintenant la documentation d'ARKit, vérifiée sur vos données ; le test de sens au premier lancement confirme l'aperçu en miroir.
- Compilez en **Release** (Product > Scheme > Edit Scheme > Run > Build Configuration > Release) : en Debug le calcul final est 20 à 50 fois plus lent.
- Aucune validation clinique. Ne pas utiliser pour une décision thérapeutique tant que la précision n'est pas mesurée sur votre chaîne (étape 8).

## 1. Prérequis

- iPhone avec Face ID (X ou plus récent) sous iOS 16 ou plus. Le simulateur ne fonctionne pas (pas de capteur TrueDepth).
- Mac avec Xcode récent (App Store) et un câble USB.
- Un Apple ID. Un compte gratuit suffit pour installer sur votre propre iPhone (l'app expire au bout de 7 jours et doit être relancée depuis Xcode). Le programme développeur payant sert à TestFlight et à la distribution.
- Python 3.10 à 3.12 recommandé pour Open3D.

## 2. Créer le projet Xcode

1. Xcode, **File > New > Project > iOS > App**.
2. Product Name : `ScanVisage`. Interface : **SwiftUI**. Language : **Swift**. Team : votre Apple ID (ajoutez-le dans Xcode > Settings > Accounts si besoin). Bundle Identifier : unique, par exemple `com.votrenom.scanvisage`.
3. Dans le navigateur de gauche, supprimez `ContentView.swift` et `ScanVisageApp.swift` générés (Move to Trash).
4. Glissez **tous les fichiers .swift** du dossier `ios/ScanVisage/` (13 fichiers) dans le groupe `ScanVisage` du projet. Cochez **Copy items if needed** et la cible `ScanVisage`. Si vous mettez à jour un projet existant, remplacez les fichiers déjà présents et ajoutez les nouveaux (`PhotoCaptureManager`, `PhotoCaptureView`, `DepthProcessing`, `Colorize`, `ColorFrame`…).

## 3. Réglages du projet

Cliquez sur le projet (icône bleue en haut à gauche), cible `ScanVisage` :

**Onglet General**
- Supported Destinations : gardez **iPhone** uniquement (supprimez Mac, Apple Vision et iPad si présents). Sinon Xcode compile pour macOS et signale « No such module UIKit ».
- Destination de build (barre du haut) : votre iPhone ou **Any iOS Device (arm64)**, jamais « My Mac ».
- Minimum Deployments : iOS 16.0 ou plus.
- Device Orientation : cochez **Portrait** uniquement.
- Icône (obligatoire pour TestFlight) : si le projet n'a pas de `Assets.xcassets`, glissez le dossier `ios/Assets.xcassets` fourni dans le groupe `ScanVisage` du navigateur Xcode (Copy items if needed, cible cochée). Il contient déjà `AppIcon` avec l'icône 1024 x 1024 sans transparence. Puis, dans **General > App Icons and Launch Screen**, choisissez **AppIcon** dans le champ App Icon.

**Onglet Info** (Custom iOS Target Properties, bouton +), ajoutez ces 3 clés :

| Clé | Valeur |
|---|---|
| `Privacy - Camera Usage Description` (NSCameraUsageDescription) | `Scan 3D du visage avec les caméras de l'iPhone.` |
| `Application supports iTunes file sharing` (UIFileSharingEnabled) | `YES` |
| `Supports opening documents in place` (LSSupportsOpeningDocumentsInPlace) | `YES` |
| `App Uses Non-Exempt Encryption` (ITSAppUsesNonExemptEncryption), pour TestFlight | `NO` |

Les deux dernières rendent les scans visibles dans l'app Fichiers de l'iPhone.

**Onglet Build Settings** (si vous utilisez Xcode 26 ou plus)
- Cherchez `Default Actor Isolation` et choisissez **nonisolated** (le défaut des nouveaux projets est `MainActor`, ce qui provoque des erreurs de concurrence dans le gestionnaire de capture).
- Si des erreurs de concurrence persistent, mettez `Swift Language Version` sur **Swift 5**.

**Mode Release (obligatoire pour la vitesse)** : en Debug le calcul est 10 à 50 fois plus lent et le suivi décroche. Menu **Product > Scheme > Edit Scheme > Run > Build Configuration = Release**. Gardez-le tant que vous testez. Pour TestFlight, l'archive est déjà en Release.

**Onglet Signing & Capabilities** : Automatically manage signing activé, Team sélectionnée.

## 4. Installer sur l'iPhone

1. Branchez l'iPhone, déverrouillez-le, touchez **Faire confiance** à la demande.
2. iPhone : **Réglages > Confidentialité et sécurité > Mode développeur** : activez, redémarrez, confirmez.
3. Dans Xcode, sélectionnez votre iPhone dans la barre du haut (à la place d'un simulateur), puis **Cmd + R**.
4. Au premier lancement, si l'app est refusée : iPhone > **Réglages > Général > VPN et gestion de l'appareil**, touchez votre Apple ID, **Faire confiance**. Relancez.
5. Acceptez l'accès à la caméra.

## 5. Faire un scan

### 5.1 Le téléphone tourne autour du visage (par défaut)

1. Patient assis, dos droit, tête appuyée si possible (dossier, appui-tête, mur), visage neutre, bouche fermée, regard sur un point fixe droit devant lui (pas sur le téléphone, ses yeux le suivraient). Il ne bouge plus jusqu'à la fin. Lumière diffuse et constante, pas de soleil direct, pas de lunettes, cheveux dégagés.
2. L'opérateur tient le téléphone à deux mains, en portrait, **écran et caméra frontale tournés vers le patient**, le bout du nez à **30 cm**. Il ne voit pas l'écran : la voix guide, et elle signale aussi « Rapprochez le téléphone », « Éloignez un peu le téléphone » et « Visage perdu ». Le patient voit l'écran, il ne doit pas réagir aux consignes.
3. Choisissez « Le téléphone tourne » et la qualité, touchez **Démarrer le scan**, puis placez le téléphone face au visage pendant le compte à rebours de 5 secondes.
4. Suivez la voix. Le téléphone se déplace sur une sphère de 30 cm de rayon centrée sur le visage, **caméra toujours pointée vers le nez**. À chaque « Stop », tenez le téléphone le plus stable possible jusqu'à la vibration.

| Étape | Mouvement du téléphone | Détection automatique |
|---|---|---|
| Face | Face au visage | écart sous 6° (10° une fois atteint) |
| Profil droit | Vers la droite du patient | 42° ou plus |
| Profil gauche | Vers la gauche du patient | 42° ou plus |
| Dessous | Sous le menton, en visant le visage | 25° ou plus |
| Dessus | Au-dessus du front, en visant le visage | 22° ou plus |
| Diagonales (Précis, Maximal) | En bas et en haut, de chaque côté | 65 % de l'amplitude de chaque axe |
| Intermédiaires (Maximal) | À mi-chemin avant chaque profil, dessous et dessus | environ 50 % |

Chaque pose est suivie d'un retour face au visage. L'anneau autour de l'ovale s'allume du côté du visage déjà scanné, tel qu'il apparaît dans le miroir.

Conseils : gestes lents, coudes près du corps, distance constante (c'est elle qui compte le plus), pas de mouvement brusque entre deux poses. Pour le dessous, accroupissez-vous un peu plutôt que de basculer le téléphone.

### 5.2 La tête tourne (téléphone posé)

1. Téléphone **immobile** et vertical, sur un support (pile de livres, trépied, pied de smartphone), caméra frontale à hauteur du visage. Patient assis face à l'écran, **le bout du nez à 30 cm de l'écran** (28 à 33 cm). Le message indique la distance du nez et demande de se rapprocher au-delà de 36 cm. C'est le premier facteur de qualité : le bruit du capteur croît avec le carré de la distance (à 37 cm il est environ 1,5 fois plus fort qu'à 30 cm). Fond uni, lumière diffuse de face, pas de soleil direct, pas de lunettes, cheveux dégagés, visage neutre, bouche fermée.
2. **Test de sens (affiché automatiquement au premier lancement).** Tournez la tête vers VOTRE droite. Deux choses doivent aller vers la droite de l'écran : votre image, comme dans un miroir, et le point blanc. Levez le menton : le point monte.
   - Votre image va à gauche : désactivez « Image en miroir ».
   - Le point va à l'inverse de votre image alors que l'image est un miroir : activez « Inverser le point » et signalez-le-moi (cela ne devrait plus arriver).
   Touchez « Le sens est correct ». Les réglages sont mémorisés et restent accessibles par « Test de sens ». Les consignes « droite » et « gauche » sont celles du patient : dans le miroir, sa droite est à droite de l'écran, comme la flèche.
3. Choisissez la **qualité** :

Le tableau des modes vaut pour les deux façons de scanner :

| Mode | Poses | Maintien par pose | Voxel final | Durée |
|---|---|---|---|---|
| Rapide | 5 (face, droite, gauche, haut, bas) | 1,2 s (1,8 s de face) | 1,5 mm | environ 40 s |
| Précis | 9 (les 5 + 4 diagonales) | 2,2 s (3,3 s de face) | 1,2 mm | environ 1 min 30 |
| Maximal | 13 (les 9 + 4 poses intermédiaires à mi-course) | 3 s (4,5 s de face) | 1,2 mm | environ 2 min 30 |

4. Touchez **Démarrer le scan**. Après un compte à rebours de 3 secondes, la voix enchaîne les consignes. À chaque arrêt : « Stop » et cling quand l'angle est atteint, puis **tenez la position** pendant que la barre se remplit, vibration de fin, consigne suivante. De petits mouvements sont tolérés : la zone cible s'élargit une fois atteinte, et la barre ne recule pas. Si la tête bouge de plus de 1,2° ou 4 mm, l'app commence simplement un nouveau bloc de profondeur (jusqu'à 4 par pose, les plus longs sont gardés) : ces petits changements de point de vue améliorent même le résultat.

| Étape | Mouvement | Détection automatique |
|---|---|---|
| Face | Regarder l'écran de face | rotation et inclinaison sous 6° (10° une fois atteinte) |
| Profil gauche | Tourner la tête vers sa droite | rotation de 38° ou plus |
| Profil droit | Tourner la tête vers sa gauche | 38° ou plus |
| Dessous | Lever le menton | 22° ou plus |
| Dessus | Baisser le menton | 18° ou plus |
| Diagonales (Précis, Maximal) | Menton levé ou baissé en tournant à droite et à gauche | 65 % de l'amplitude de chaque axe |
| Intermédiaires (Maximal) | Un arrêt à mi-course avant chaque pose | environ 50 % de l'amplitude |

Chaque pose est suivie d'un retour au centre (sous 8°). Une fois la cible atteinte, on peut revenir jusqu'à 20 % en deçà sans perdre l'arrêt.

5. L'anneau autour de l'ovale se remplit dans la direction de chaque mouvement. Le bas de l'écran affiche le numéro de pose, la rotation, l'inclinaison, et un avertissement orange si le nez est à plus de 36 cm.
6. À la fin, une barre de progression montre le calcul (filtrage, recalage des poses, fusion, surface, couleurs), quelques dizaines de secondes en Release. L'aperçu 3D s'affiche, avec un bouton **Couleur : oui / non**. **Partager (zip)** envoie le dossier.

Conseils : mouvements lents (2 à 3 secondes par mouvement), épaules fixes, même expression du début à la fin, téléphone qui ne bouge pas, éclairage constant (la couleur est fusionnée entre plusieurs images, une lumière qui change se verrait en raccords). Les amplitudes se modifient dans `CaptureStyle` (`yawTarget`, `pitchUpTarget`, `pitchDownTarget`), les tolérances en haut de `ScanEngine` (`centerTol`, `blockMaxDegrees`, `blockMaxShift`) et les durées dans `ScanMode`.

## 5 bis. Qualité : ce qui limite et ce qui a été fait

Mesures sur vos fichiers : une image seule a un bruit d'environ 1,6 mm. Ce bruit est en grande partie **figé** (motif du projecteur infrarouge et filtrage d'Apple) : 80 images moyennées sans bouger gardent environ 0,7 mm de bruit local, en stries. Il ne baisse vraiment qu'en combinant des points de vue différents.

Ce que la version actuelle fait :
- **Recalage multivue ICP** (point-plan, seuils de 30 mm à 3 mm, chaque vue recalée sur toutes les autres, deux passages). Sur votre scan, il a corrigé des erreurs de pose ARKit de 18 à 30 mm.
- **Blocs multiples par pose** : un à quatre points de vue légèrement différents par arrêt, tous fusionnés.
- **Filtre bilatéral** de la profondeur (lisse sans arrondir les bords nets) et **troncature TSDF de 7 mm** : sur votre scan, la rugosité du visage passe de 0,9 à 0,2 mm.
- Poids de fusion calculés sur un voisinage de ±3 pixels (moins bruités) : les pixels obliques (flancs du nez, bords du visage) pèsent peu.
- Zone de la tête mesurée sur votre scan (bout du nez, menton, front) : épaules, cou et fond exclus.
- Voxels de 1,2 mm (1,5 mm en Rapide) : 1,0 mm n'apportait rien de mesurable avec ce capteur.
- Lissage de Taubin, qui réduit le bruit sans rétrécir le visage.

Ce que vous pouvez faire en plus :
- **Distance** : nez à 30 cm. C'est le réglage qui compte le plus.
- **Support rigide** : le moindre mouvement du téléphone dégrade la fusion.
- **Patient** : pas de lunettes, cheveux dégagés, pas de barbe longue, peau mate (le front brillant ou le maquillage brillant donne des trous). Un voile de poudre matifiante aide.
- **Ne pas parler, ne pas serrer les dents** entre les positions.
- **Fermeture des trous** (arrière de la tête, dessous du menton) : dans Meshmixer, Blender ou MeshLab, si le STL doit être imprimé.
- **Échelle** : mesurez l'erreur d'échelle avec la balle de 40 mm (étape 8). Si elle est constante, elle peut être corrigée par un facteur.

## 6. Voie optionnelle : reconstruction Poisson sur Mac

Le zip contient les 5 PLY, qui peuvent être recalés et fusionnés par le script Python (utile pour comparer avec le STL embarqué).

```bash
cd python
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

python process.py ~/Downloads/Scan_20261012_153000 --out ~/Desktop/visage_poisson.stl --rotate-z 90
```

Le script affiche recouvrement et RMSE de chaque recalage et signale un avertissement si le recouvrement est inférieur à 0,35 ou le RMSE supérieur à 1,5 mm. Options : `--radius`, `--rotate-z`, `--mirror-x`, `--depth`, `--trim`. Notez que les PLY sont des trames brutes uniques (non filtrées par Apple, plus bruitées que l'ancienne moyenne de 15 images) : le STL embarqué, qui fusionne des dizaines de trames, est normalement meilleur.

## 7. Vérifier orientation et latéralité (obligatoire)

Le STL est exprimé dans le repère de la tête donné par ARKit : Y = haut de la tête, Z = sortant du visage, X = gauche du patient. Il n'a pas été vérifié sur un iPhone réel.

- **Orientation** : si le visage est couché ou à l'envers dans l'aperçu, touchez **Pivoter 90°** jusqu'à ce qu'il soit droit. Le STL du dossier est réécrit à chaque fois.
- **Latéralité** : avant le scan, collez une pastille sur la joue **droite** du patient. Vue de face dans l'aperçu, elle doit apparaître **à gauche** de l'écran, comme en regardant la personne en face. Sinon touchez **Miroir** (inverse l'axe X et le sens des triangles). Cette vérification est indispensable en dentisterie : une inversion droite/gauche est silencieuse et dangereuse.
- Le STL et `visage_couleur.ply` sont en **millimètres**, centrés sur le barycentre. Pivoter et Miroir réécrivent les deux.

## 8. Mesurer la précision sur votre propre chaîne

1. Échelle et bruit de la capture : scannez une **balle de ping-pong de 40 mm** fixée sur un support fin (c'est une sphère mate, ça ne remplace pas la peau). Ajustez une sphère sur le STL (MeshLab, CloudCompare) et comparez le diamètre. `python/check_sphere.py` fait la même chose sur un PLY de pose : `python check_sphere.py Scan_XXXX/pose_01.ply --diameter 40`.
2. Suivi sur le mouvement : scannez un objet rigide asymétrique mesuré au pied à coulisse (buste en plâtre, mannequin) et comparez des distances entre repères.
3. Référence : comparez le STL à un scan de référence (scanner facial ou de bureau validé) et mesurez des distances entre points anatomiques. C'est la seule façon de connaître l'erreur réelle sur des visages.

## 9. Dépannage

| Symptôme | Piste |
|---|---|
| Erreur de compilation Swift | Copiez le message exact et renvoyez-le |
| « Cet appareil n'a pas de capteur TrueDepth » | iPhone sans Face ID, ou simulateur |
| Écran noir | Permission caméra refusée (Réglages > ScanVisage), ou clé `NSCameraUsageDescription` manquante |
| Le message n'indique pas de visage détecté | Visage hors de 15 à 80 cm, trop de trous de profondeur (soleil, lunettes, reflets) |
| « Repère perdu » en permanence | Build en Debug (passer en Release), mouvement trop rapide, téléphone qui bouge, épaules qui suivent la tête |
| « Maillage insuffisant » | Mouvement trop court ou suivi perdu très tôt. Recommencez plus lentement |
| Visage déformé, dédoublé | Dérive du suivi ou mouvement du patient. Recommencez, mouvement plus lent et moins ample |
| Visage couché ou en miroir | Étape 7 |
| « Pas assez de poses » | Suivi perdu ou mouvement trop rapide pendant les arrêts. Tenez la position après « Stop » |
| Visage en « éponge » ou dédoublé | Envoyez le zip : les JSON contiennent `refinedShiftMm` (correction de chaque pose) |
| Couleurs décalées (reflets sur le mauvais endroit) | Alignement couleur/profondeur incorrect : envoyez un pose_01.ply et son JSON |
| Les flèches et mon image vont en sens contraire | Test de sens, étape 5 |
| Téléphone qui chauffe | Normal en calcul continu. Laissez refroidir entre deux scans |

## 10. Limites connues

- La pose ARKit sert de point de départ ; la géométrie fait le reste (recalage multivue). Le visage étant une surface lisse, le recalage peut légèrement « glisser » le long des joues et du front, sans effet visible sur la forme dans nos essais. `refinedShiftMm` (au bout du nez) et `refinedRotationDeg` dans les JSON indiquent la correction appliquée à chaque pose. La profondeur fournie par ARKit est filtrée par Apple et peut baver si la tête bouge vite.
- Pas de correction de la distorsion optique de la caméra de profondeur.
- Le volume de reconstruction mesure 22 x 27,5 x 22,5 cm autour de la tête (voxels de 1,2 ou 1,5 mm). Cheveux, barbe, lunettes, bijoux et peau brillante dégradent la profondeur.
- Mode « le téléphone tourne » : le patient ne doit pas bouger du tout (appui-tête conseillé). Mode « la tête tourne » : seule la tête doit bouger, les épaules et le cou qui suivent créent des incohérences. Dans les deux cas, expression constante.
- La couleur dépend de l'exposition automatique de la caméra : un gain de luminosité est estimé par image pour atténuer les raccords, mais des différences de teinte peuvent subsister. Les zones jamais vues par la caméra (dessous du menton, côtés extrêmes) reçoivent la couleur des voisins.
- Le STL fait 10 à 25 Mo ; le calcul final consomme environ 300 Mo de mémoire.
- Précision non établie sur patients (étape 8).
- Réglementation : un logiciel qui sert à une décision diagnostique ou thérapeutique peut relever du règlement européen sur les dispositifs médicaux (MDR). Usage personnel ou de recherche plus léger, mais à anticiper pour toute diffusion.
