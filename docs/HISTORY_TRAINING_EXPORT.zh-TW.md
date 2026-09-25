# 歷史紀錄匯出 3DGS 訓練格式

[English](HISTORY_TRAINING_EXPORT.md) | **繁體中文**

原問題：停止掃描只保存 `review.ply`、`review-poses.jsonl` 與摘要。正式匯出會建立 COLMAP，但歷史頁只呼叫 ZIP 壓縮，且直接分享既有 ZIP，造成看得到照片卻缺少 `sparse/0`。

現在兩條匯出入口都呼叫 `ExportManager.writeTrainingDataset`。歷史匯出使用 review 姿態（缺少時讀取正式修正姿態／原始姿態），合併續掃新增的影格；只將 `.keep` 影格列入相機模型，存在 RGB 選幀報告時再依選用 ID 過濾。已存點雲最多讀入 250,000 點，舊掃描沒有點雲時使用既有的有界預覽重建。原始照片與深度不會刪除。

產物包含 `images/`、`sparse/0/cameras.bin`、`sparse/0/images.bin`、`sparse/0/points3D.bin`、`points.ply` 與 `poses_refined.jsonl`。COLMAP 相機與點雲使用一致的座標轉換。`points.ply` 仍依原有約定保留 ARKit 世界座標，COLMAP 訓練器應讀取 `sparse/0/points3D.bin`。

匯出前先檢查影格 ID、姿態長度與有限值、內參、影像檔名及檔案存在性；沒有有效訓練影格時回報錯誤，不再靜默略過 sparse。失敗不替換前一份 ZIP。每次進入歷史詳情時清除 UI 中可直接分享的快取 URL，要求重新準備完整訓練包。

空點雲仍產生合法的零筆 `points3D.bin` 與空 `points.ply`，避免留用舊點雲；這不保證外部 3DGS 訓練器能在沒有種子點時直接開始訓練。`gaussians.ply` 是訓練結果，不是匯出格式本身。手機端訓練的檢查點與模型放在 `gaussian-training/`，資料集 ZIP 不含這個資料夾（改壓縮一份不含它的硬連結鏡像，不複製任何媒體）；模型另有自己的 `scan_…-3dgs.zip`。舊版掃描若已含模型，仍會隨整份掃描保留、匯出或刪除。

壓縮檔改以系統分享表分享檔案本身。SwiftUI 的 `ShareLink(item: URL)` 只交出檔案連結，只有 AirDrop 與「檔案」能接收，LINE、Teams 會失敗。檔案非常大時，仍可能超過接收端 App 自己的大小限制。

## 驗證

```sh
swiftc arkit-3dgs-scanner/Capture/Localization.swift arkit-3dgs-scanner/Capture/TrainingFrameSelector.swift -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,ExportManager}.swift \
  arkit-3dgs-scanner/History/ScanLibrary.swift tools/test_history_training_export.swift \
  -o /tmp/fable-history-export-test
/tmp/fable-history-export-test
```

14 項檢查包含：只有預覽的舊包、ZIP 取代、三個 COLMAP binary 的數量／內參／姿態／座標解析、品質篩選、修正姿態優先、原始資料保留、實際 ZIP 內容、缺圖與畸形姿態、失敗保留舊包、零點輸出。另通過歷史紀錄 8 項與擷取／ZIP 流程 4 項回歸；iPhone 與 Simulator 未簽章 Debug 建置成功。

## 修復已下載的舊掃描

`tools/prepare_training_export.swift` 使用相同的歷史匯出路徑，接收一個掃描資料夾，補寫訓練檔並在同層產生 ZIP。先複製原資料夾再執行，可保留原封不動的備份。

```sh
swiftc arkit-3dgs-scanner/Capture/Localization.swift arkit-3dgs-scanner/Capture/TrainingFrameSelector.swift -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,ExportManager}.swift \
  arkit-3dgs-scanner/History/ScanLibrary.swift tools/prepare_training_export.swift \
  -o /tmp/fable-prepare-training-export
/tmp/fable-prepare-training-export /path/to/scan_directory
```

## 掃描中繼資料檔名

新掃描使用 `capture-meta.json`，避免外部訓練器將 `meta.json` 誤判為其他資料格式。舊掃描仍可從 `meta.json` 讀取日期與 LiDAR 設定；準備訓練資料或重新打包時會改名，保留原始 JSON bytes 與未知欄位。新舊檔並存時使用 `capture-meta.json`，舊檔另存為 `capture-meta-legacy-UUID.json`，不覆寫任何版本。

已分享出去的舊 ZIP 不會自動變更，請用新版重新匯出，或將解壓後的 `meta.json` 改成 `capture-meta.json`。`tools/arkit2gs.py` 同時支援新舊檔名。
