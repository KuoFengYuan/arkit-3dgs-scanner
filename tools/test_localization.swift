import Foundation

@main struct LocalizationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let en = Bundle(path: root.appendingPathComponent("en.lproj").path)!
        let zh = Bundle(path: root.appendingPathComponent("zh-Hant.lproj").path)!
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1; print("PASS: \(message)")
        }
        func english(_ message: LocalizedMessage) -> String { L10n.render(message, language: .english, bundle: en) }
        func chinese(_ message: LocalizedMessage) -> String { L10n.render(message, language: .traditionalChinese, bundle: zh) }
        check(AppLanguage.resolve(nil) == .traditionalChinese, "first launch defaults to Traditional Chinese")
        check(AppLanguage.resolve("unsupported") == .traditionalChinese, "unknown preferences fall back to Chinese")
        check(AppLanguage.resolve("en") == .english, "saved English preference is respected")
        check(chinese("掃描紀錄") == "掃描紀錄", "Chinese lookup")
        check(english("掃描紀錄") == "Scan history", "English lookup")
        check(english("\(12) 張影像") == "12 images", "dynamic count translates before interpolation")
        check(chinese("\(12) 張影像") == "12 張影像", "Chinese dynamic count")
        check(english("逐張匹配拍攝影像… \(50)%") == "Matching captured images… 50%", "literal percent survives interpolation")
        let filename = "my%photo中文.jpg"
        check(english("找不到訓練影像：\(filename)") == "Training image not found: " + filename,
              "user filenames remain verbatim and are not interpreted as format strings")
        check(String(format: english("拍攝時間 +%02d:%02d"), 1, 9) == "Capture time +01:09", "printf templates retain numeric argument types")
        check(english("尚未翻譯的備援文字") == "尚未翻譯的備援文字", "unknown key has readable source fallback")
        check(english("\(3) 張拍攝時的運動估計偏高；這不代表照片已模糊，也不單獨要求補拍。")
              .contains("does not confirm blur"), "risk message does not assert blur")
        check(english("\(2) 張視角細節偏弱，建議檢查或補拍（影格 \("7, 9")）。")
              == "2 views have weak detail. Review or recapture them (frames 7, 9).", "weak-detail warning keeps frame IDs")
        let defaults = UserDefaults.standard
        let oldPreference = defaults.object(forKey: AppLanguage.preferenceKey)
        defer {
            if let oldPreference { defaults.set(oldPreference, forKey: AppLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        check(AppLanguage.current == .english, "runtime reads persisted preference")
        var room = FloorPlanRoom(label: "livingRoom", polygon2D: [], areaM2: 0, labelAt: [0, 0])
        // Custom labels are user content and are never looked up in localization resources.
        room.customLabel = "My room 客廳"
        check(room.displayName == "My room 客廳", "custom room names are preserved")
        defaults.removeObject(forKey: AppLanguage.preferenceKey)
        check(AppLanguage.current == .traditionalChinese, "removed preference returns to Chinese")
        print("\(checks) localization checks passed")
    }
}
