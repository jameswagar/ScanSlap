#!/bin/bash
set -euo pipefail

EXPECTED_DMG_MD5="2814298d2e652fdee4bb80fb915c1f31"
EXPECTED_DMG_SHA1="231b967f1c1e20e06f54ac27f71b4de57723dcf0"
EXPECTED_FIRMWARE_SHA256="df35e67c676981b2802587ab0b7e84ce4a7bdf4877e4d338dc380fdad67386c1"
PFU_SIGNER="Developer ID Installer: PFU LIMITED (XW4U7W2E9L)"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /path/to/MacManagerV72L50WW.dmg-or-archive.zip" >&2
    exit 64
fi

SOURCE="$1"
[[ -f "$SOURCE" ]] || { echo "File not found: $SOURCE" >&2; exit 66; }
command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh" >&2; exit 69; }
command -v scanimage >/dev/null || { echo "Install SANE first: brew install sane-backends" >&2; exit 69; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scanslap-firmware.XXXXXX")"
MOUNT="$WORK/mount"
DMG="$WORK/MacManagerV72L50WW.dmg"
EXPANDED="$WORK/expanded"
cleanup() {
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$MOUNT"

case "${SOURCE##*.}" in
    zip|ZIP)
        unzip -p "$SOURCE" MacManagerV72L50WW.dmg > "$DMG"
        ;;
    dmg|DMG)
        cp "$SOURCE" "$DMG"
        ;;
    *)
        echo "Expected the Internet Archive ZIP or MacManagerV72L50WW.dmg" >&2
        exit 65
        ;;
esac

ACTUAL_MD5="$(md5 -q "$DMG")"
ACTUAL_SHA1="$(shasum "$DMG" | cut -d' ' -f1)"
[[ "$ACTUAL_MD5" == "$EXPECTED_DMG_MD5" ]] || { echo "DMG MD5 mismatch" >&2; exit 74; }
[[ "$ACTUAL_SHA1" == "$EXPECTED_DMG_SHA1" ]] || { echo "DMG SHA-1 mismatch" >&2; exit 74; }

diskutil image attach --readOnly --nobrowse --mountPoint "$MOUNT" "$DMG" >/dev/null
PKG="$MOUNT/ScanSnap Manager.pkg"
SIGNATURE="$(pkgutil --check-signature "$PKG")"
grep -Fq "$PFU_SIGNER" <<<"$SIGNATURE" || { echo "Package is not signed by the expected PFU identity" >&2; exit 77; }
pkgutil --expand-full "$PKG" "$EXPANDED"

FIRMWARE="$EXPANDED/ScansnapManager.pkg/Payload/ScanSnap/ScanSnap Manager.app/Contents/Resources/Firmware/300M_0B00.nal"
[[ -f "$FIRMWARE" ]] || { echo "S300M firmware was not found in the PFU package" >&2; exit 65; }
ACTUAL_FIRMWARE_SHA256="$(shasum -a 256 "$FIRMWARE" | cut -d' ' -f1)"
[[ "$ACTUAL_FIRMWARE_SHA256" == "$EXPECTED_FIRMWARE_SHA256" ]] || { echo "Firmware SHA-256 mismatch" >&2; exit 74; }

SUPPORT="$HOME/Library/Application Support/ScanSnap S300M"
mkdir -p "$SUPPORT/firmware" "$SUPPORT/sane"
install -m 0644 "$FIRMWARE" "$SUPPORT/firmware/300M_0B00.nal"
printf 'epjitsu\n' > "$SUPPORT/sane/dll.conf"
printf '%s\n%s\n%s\n' \
    '# Local firmware extracted from the user'"'"'s PFU ScanSnap Manager package.' \
    "firmware $SUPPORT/firmware/300M_0B00.nal" \
    'usb 0x04c5 0x117f' > "$SUPPORT/sane/epjitsu.conf"

SANE_CONFIG_DIR="$SUPPORT/sane" scanimage -L
echo "Installed verified S300M firmware and SANE configuration in: $SUPPORT"
