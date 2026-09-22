# Language support

**English** | [繁體中文](LOCALIZATION.zh-TW.md)

Documentation defaults to English. Every Markdown document has a Traditional Chinese `.zh-TW.md` counterpart and a reciprocal language link. Keep examples, behavior, limitations, and maintenance changes consistent across both versions.

The app defaults to **Traditional Chinese**, independent of device language. Choose 繁體中文 or English on the home screen; `app.language` in UserDefaults persists the choice. Missing or unrecognized values fall back to Traditional Chinese. SwiftUI receives the selected locale without rebuilding the scan session. Change language from the home screen before entering capture or history.

`Capture/Localization.swift` provides `AppLanguage`, `LocalizedMessage`, and `L10n`. User-facing labels, dynamic errors/progress, quality guidance, accessibility labels, and built-in floor-plan names use `L10n.text`. Translation resources are `en.lproj/Localizable.strings` and `zh-Hant.lproj/Localizable.strings`.

```swift
Text(L10n.text("掃描紀錄"))
Text(L10n.text("\(count) 張影像"))
String(format: L10n.text("拍攝時間 +%02d:%02d"), minutes, seconds)
```

Interpolation translates the complete sentence before inserting values. Add the `%@` template to both resources, preserving printf placeholder types/order. Literal percentages in interpolated messages are escaped as `%%`. User filenames and custom room names remain verbatim. JSON field names, status codes, capture filenames, and semantic drawing identifiers never depend on language. Developer logs are not a translated user interface.

Camera permission descriptions have both `InfoPlist.strings` resources. iOS chooses system permission dialogs, Settings, and share-sheet language using its own app/system language rules; the in-app picker does not override those system surfaces. New UI resources support English and Traditional Chinese, with `zh-Hant` as the development fallback. Unsupported-language app text falls back to Chinese.

## Checks

```sh
python3 tools/check_project.py
bash tools/test_localization.sh
```

The project check validates branch naming, Markdown counterparts and local links, used localization keys, nonempty English/Chinese resources, and placeholder parity. Localization and quality regression tests cover Chinese default/fallback, English rendering, dynamic values, percent escaping, formatting, quality messages, stable serialized reports, and unchanged custom names. Build both iOS targets to verify packaged resources.

Simulator interaction checks cover home language switching, persistence after relaunch, and history labels. Real-device camera permissions, live AR guidance, accessibility, smaller screens, and large text still need device-specific review; Simulator cannot validate LiDAR capture.
