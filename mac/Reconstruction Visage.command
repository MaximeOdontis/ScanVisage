#!/bin/bash
# Double-cliquer sur ce fichier.
# Première fois : prépare l'application « Reconstruction Visage.app » (quelques minutes, une seule fois).
# Ensuite : ouvre l'application. On peut aussi double-cliquer directement sur Reconstruction Visage.app.

cd "$(dirname "$0")" || exit 1
VER="$(cat VERSION 2>/dev/null || echo 0)"
APP="Reconstruction Visage.app"
EXE="$APP/Contents/MacOS/ReconstructionVisage"

pause() { echo; read -r -p "Appuyer sur Entrée pour fermer cette fenêtre. " _; }

needs_build() {
    [ ! -x "$EXE" ] && return 0
    [ -n "$(find FaceRebuild/Sources FaceRebuild/Package.swift VERSION AppIcon.icns -newer "$EXE" -print -quit 2>/dev/null)" ] && return 0
    return 1
}

if needs_build; then
    echo "Préparation de l'application (2 à 5 minutes, une seule fois)..."
    if ! command -v swift >/dev/null 2>&1; then
        echo "Les outils Xcode sont absents. Installer Xcode (App Store), l'ouvrir une fois, puis relancer ce fichier."
        pause; exit 1
    fi
    ( cd FaceRebuild && swift build -c release --product ReconstructionVisage ) || {
        echo
        echo "La compilation a échoué. Copier le texte ci-dessus des lignes contenant « error » et l'envoyer à Claude."
        pause; exit 1
    }
    BIN="$(cd FaceRebuild && swift build -c release --show-bin-path)/ReconstructionVisage"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$BIN" "$EXE"
    [ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Reconstruction Visage</string>
    <key>CFBundleDisplayName</key><string>Reconstruction Visage</string>
    <key>CFBundleIdentifier</key><string>fr.maxime.reconstructionvisage</string>
    <key>CFBundleExecutable</key><string>ReconstructionVisage</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$APP/Contents/Info.plist" >/dev/null 2>&1
    codesign --force --sign - "$APP" >/dev/null 2>&1
    touch "$APP"
    xattr -cr "$APP" 2>/dev/null
    echo "Application prête (version $VER)."
fi

open "$APP"
