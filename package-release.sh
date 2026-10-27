#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

app_path="${1:-$PWD/build/Spy.app}"
release_dir="${2:-$PWD/build/release}"
[[ -d "$app_path" && -f "$app_path/Contents/MacOS/Spy" ]] || { print -u2 "Build Spy.app before packaging."; exit 1; }
app_path="${app_path:A}"
mkdir -p "$release_dir"
release_dir="${release_dir:A}"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_path/Contents/Info.plist")
[[ "$version" == [0-9]* && "$version" != */* ]] || { print -u2 "Invalid bundle version."; exit 1; }
codesign --verify --deep --strict "$app_path"

release_stage=$(mktemp -d "${TMPDIR:-/tmp/}Spy-Release.XXXXXX")
trap 'rm -rf "$release_stage"' EXIT INT TERM
ditto "$app_path" "$release_stage/Spy.app"
ln -s /Applications "$release_stage/Applications"
cp README.txt "$release_stage/Инструкция.txt"
cat > "$release_stage/Установка.txt" <<'INSTALL'
Spy для Mac с Apple Silicon

1. Откройте образ и перенесите Spy.app на значок «Applications».
2. Откройте Spy из папки «Программы».
3. Предоставьте разрешение macOS на запись экрана; микрофон — по желанию.

Это локальная сборка. Она не подписана Developer ID и не нотариализована
Apple; macOS может ограничить её запуск. Исходники и инструкция по сборке:
https://github.com/Pechivoa/Spy

Проверяйте SHA-256 загруженного файла по опубликованному SHA256SUMS.txt.
Личные записи, настройки и ключи подписи в установщик не входят.
INSTALL

artifact_stem="Spy-${version}-macOS-arm64"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$release_dir/$artifact_stem.zip"
hdiutil create -volname "Spy $version" -srcfolder "$release_stage" -format UDZO -ov "$release_dir/$artifact_stem.dmg"
(
    cd "$release_dir"
    shasum -a 256 "$artifact_stem.zip" "$artifact_stem.dmg" > SHA256SUMS.txt
)
print "Release assets: $release_dir"
