# SiftEditor

**English** | [简体中文](README.zh-CN.md)

SiftEditor is a macOS editor for large text files. It includes MIT-licensed upstream code; the required copyright and license notice are preserved in [LICENSE](LICENSE).

The current fork adds EmEditor-inspired search and extraction controls, including frequent whole-line and token counting, CSV results, and a Find dialog with search history. Planned functions remain visible and disabled with `*`. Track implemented and missing functions in the [feature checklist](docs/EMEDITOR_FEATURE_CHECKLIST.md).

The project uses English and Simplified Chinese localization files.

## Build and test

Requires macOS 13 or newer, Xcode with Swift 5.9 or newer, and `rg` (ripgrep) on the build machine. `build-app.sh` bundles ripgrep and its PCRE2 library inside the single `.build/SiftEditor.app`; users of the packaged app do not need to install `rg`. The helper must support the same CPU architectures as the app.

```sh
swift test
sh build-app.sh
open .build/SiftEditor.app
```

The local app bundle uses `com.iamxwk.SiftEditor` and the `sifteditor://` settings-link scheme. The terminal command is `sifteditor` after running `scripts/install-cli.sh` against an installed app. Local `test.sql`, `testdata/`, and `.build/` are ignored by Git.

Large UTF-8 regular-expression Find and Find-dialog Extract use the bundled ripgrep helper. Search > Extract Frequent Strings also uses it to select candidate lines for regular expressions, IPv4, IPv6, email addresses, and URLs; the existing matcher performs the final extraction and counting. Whole-line and word counts retain their streaming scanner. For an unsaved large document, Find and both extraction commands scan a temporary snapshot of the current editor contents; the original file is not saved. The snapshot needs free temporary disk space roughly equal to the document size and is removed after extraction or when Find closes or the document changes.

For a distributable disk image, `scripts/make_dmg.sh` produces `.build/SiftEditor-<version>.dmg`. Each successful app package increments the patch version recorded in `VERSION`; you can set `VERSION` explicitly for a release. There is no SiftEditor release yet; signing and notarization require your own credentials.

## Project status

Planned controls remain disabled until implemented here. The bundled app uses the SiftEditor icon in `art/AppIcon.icns`.

## License

[MIT](LICENSE). The original copyright and license notice are retained.
