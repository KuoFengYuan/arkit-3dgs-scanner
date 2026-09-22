# 語言支援

[English](LOCALIZATION.md) | **繁體中文**

文件英文優先，每份 Markdown 有 .zh-TW.md 繁中對照並互相連結。範例、行為、限制與維護修改需同步。

App 不依裝置語言，預設**繁體中文**。首頁可選繁體中文或 English，以 UserDefaults 的 app.language 記住偏好；沒有設定或值無效時回退繁中。SwiftUI 使用所選 locale，不重建掃描 session。請在首頁切換，再進入掃描或歷史。

Capture/Localization.swift 提供 AppLanguage、LocalizedMessage、L10n。UI 標籤、動態錯誤／進度、品質提示、無障礙及內建房間名皆使用 L10n.text；資源位於 en.lproj/Localizable.strings 與 zh-Hant.lproj/Localizable.strings。

```swift
Text(L10n.text("掃描紀錄"))
Text(L10n.text("\(count) 張影像"))
String(format: L10n.text("拍攝時間 +%02d:%02d"), minutes, seconds)
```

先翻譯整句，再代入值。兩份資源都加入 %@ 樣板，保留 printf 參數型別與順序；插值句子的百分號用 %%。使用者檔名及自訂房間名不翻譯。JSON 欄位、狀態碼、檔名與製圖語意識別碼不隨語言改變。開發 log 不屬於翻譯介面。

相機權限另提供雙語 InfoPlist.strings。iOS 依系統／App 語言選擇權限對話框、設定與分享介面；App 內切換不覆寫系統介面。資源包含 en 與 zh-Hant，development fallback 為 zh-Hant，未支援的 App 文字回退中文。

## 檢查

```sh
python3 tools/check_project.py
bash tools/test_localization.sh
```

專案檢查分支命名、Markdown 對照及本機連結、使用的語系 key、中英文完整性與參數一致性。語系與品質回歸測試涵蓋中文預設／回退、英文、動態值、百分比、format、品質訊息、報告序列化不變與自訂名稱不變。兩個 iOS 目標建置確認資源打包。

模擬器互動檢查首頁切換、重開保留與歷史標籤。實機相機權限、AR 提示、無障礙、小螢幕及大字體仍需對應裝置驗證；Simulator 無法驗證 LiDAR。
