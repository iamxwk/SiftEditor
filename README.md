# SiftEditor

**English** | [简体中文](README.zh-CN.md)

SiftEditor is a macOS editor for large text files. It includes MIT-licensed upstream code; the required copyright and license notice are preserved in [LICENSE](LICENSE).

The current fork adds EmEditor-inspired search and extraction controls, including frequent whole-line and token counting, CSV results, and a Find dialog with search history. Planned functions remain visible and disabled with `*`. Track implemented and missing functions in the [feature checklist](docs/EMEDITOR_FEATURE_CHECKLIST.md).

The project uses English and Simplified Chinese localization files.

## Build and test

Requires macOS 13 or newer and Xcode with Swift 5.9 or newer.

```sh
swift test
sh build-app.sh
open .build/SiftEditor.app
```

The local app bundle uses `com.iamxwk.SiftEditor` and the `sifteditor://` settings-link scheme. The terminal command is `sifteditor` after running `scripts/install-cli.sh` against an installed app. Local `test.sql`, `testdata/`, and `.build/` are ignored by Git.

For a distributable disk image, `scripts/make_dmg.sh` produces `.build/SiftEditor-1.24.1.dmg` with the current inherited version. There is no SiftEditor release yet; signing and notarization require your own credentials.

## Project status

Planned controls remain disabled until implemented here. The bundled app uses the SiftEditor icon in `art/AppIcon.icns`.

## License

[MIT](LICENSE). The original copyright and license notice are retained.
