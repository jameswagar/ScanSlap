# ScanSlap

A native macOS scanning app for the discontinued Fujitsu ScanSnap S300M.

ScanSlap keeps scanner transport, document processing, and the SwiftUI interface separate. It calls the established SANE `epjitsu` backend rather than reimplementing Fujitsu's USB protocol.

## Current features

- Front, back, and duplex ADF scanning
- Color, grayscale, and line-art modes
- 150, 300, and 600 DPI presets
- Automatic page-length detection
- Multipage searchable and image-only PDF output
- Numbered JPEG and PNG page sets
- Lossless multipage TIFF output
- Automatic portrait rotation
- Searchable PDFs using on-device Apple Vision OCR
- Configurable output folder
- Scanner discovery and clear error reporting

The S300M has a true optical ceiling of 600 DPI. Fujitsu's historical 1200-DPI monochrome mode was software-derived, so ScanSlap intentionally caps capture at the scanner's native 600 DPI.

## Requirements

- macOS 14 or newer
- Fujitsu ScanSnap S300M connected over USB (`04c5:117f`)
- [Homebrew](https://brew.sh)
- SANE backends:

```bash
brew install sane-backends
```

- A lawful local copy of the PFU ScanSnap Manager package containing `300M_0B00.nal`

## Firmware setup

Firmware is proprietary to PFU and is **not included in this repository or in ScanSlap builds**.

The following Internet Archive item contains `MacManagerV72L50WW.dmg`, a PFU-signed and Apple-notarized ScanSnap Manager package:

<https://archive.org/details/mac-manager-v-72-l-50-ww>

Download either the item ZIP or `MacManagerV72L50WW.dmg`, then run:

```bash
./scripts/install-firmware.sh ~/Downloads/mac-manager-v-72-l-50-ww.zip
```

The installer performs all of these checks before copying anything:

- DMG MD5: `2814298d2e652fdee4bb80fb915c1f31`
- DMG SHA-1: `231b967f1c1e20e06f54ac27f71b4de57723dcf0`
- Package signer: `Developer ID Installer: PFU LIMITED (XW4U7W2E9L)`
- Firmware SHA-256: `df35e67c676981b2802587ab0b7e84ce4a7bdf4877e4d338dc380fdad67386c1`

The script extracts only the S300M firmware needed for local interoperability and writes it under:

```text
~/Library/Application Support/ScanSnap S300M/
```

The archive is hosted by a third party. Users are responsible for ensuring that their download and local use comply with applicable law and licensing terms.

## Build and install

```bash
./scripts/build-app.sh
rm -rf /Applications/ScanSlap.app
ditto build/ScanSlap.app /Applications/ScanSlap.app
open /Applications/ScanSlap.app
```

The local build is ad-hoc signed. A public notarized binary would require an Apple Developer ID signing identity.

## Tests

The repository uses a standalone Swift specification executable because some Command Line Tools-only installations do not include a working XCTest runtime:

```bash
swift run ScanSlapCoreSpec
swift build -c release
```

The specifications exercise scanner command construction, device-status parsing, page ordering, multipage PDF generation, and embedded searchable text.

## Architecture

- `ScanSlapCore`: deterministic scanner commands, process execution, page collection, PDF assembly, and OCR
- `ScanSlap`: native SwiftUI application
- `ScanSlapCoreSpec`: executable regression specifications
- `scripts/install-firmware.sh`: validates and extracts user-supplied PFU firmware
- `scripts/build-app.sh`: produces an ad-hoc signed `.app` bundle

SANE is an external runtime dependency and is invoked through `scanimage`; its source is not copied into this project.

## Known limitations

- Only the S300M USB ID is configured.
- Deskew and blank-page removal are not yet implemented.
- Public builds are not Developer ID signed or notarized.

## License

ScanSlap source code is available under the MIT License. PFU firmware and SANE remain under their respective licenses.
