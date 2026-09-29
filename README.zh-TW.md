# ARKit 3DGS Scanner

**用 iPhone 掃描，直接在手機上訓練 3D Gaussian Splatting，或匯出資料集。**

[English](README.md) | **繁體中文**

<a href="docs/media/demo.mp4"><img src="docs/media/demo.gif" width="320" alt="一次掃描從擷取到完成 3DGS 模型：掃描、融合、訓練與完成的模型"></a>

*20 秒循環，8 倍速。[觀看 1 分鐘影片](docs/media/demo.mp4)（2.7 倍速）：掃描桌面、優化資料，並在 iPhone 上訓練 3DGS 模型。*

用 ARKit 擷取照片、相機姿態與點雲，在手機上完成優化，再用 iPhone 的 GPU 訓練 3DGS 模型，或匯出 COLMAP 資料集給電腦上的訓練器。資料不會上傳。

## 主要功能

- **有沒有 LiDAR 都能掃。** 依移動量與畫質自動挑選關鍵影格。LiDAR 深度會跨視角融合；純相機掃描保留驗證過的稀疏點，也可以再用影像估計深度。大空間裡 App 會提示回到拍過的區域，用來修正漂移。詳見[掃描架構](docs/CAPTURE_ARCHITECTURE.zh-TW.md)與[無 LiDAR 重建](docs/CAMERA_ONLY_ACCURACY.zh-TW.md)。
- **在手機上優化資料。** 挑選清晰照片；相機姿態精修只有在照片對齊檢查變好時才套用；多視角深度融合。詳見[姿態精修](docs/POSE_REFINEMENT.zh-TW.md)與 [LiDAR 多視角共識](docs/LIDAR_SURFACE_CONSENSUS.zh-TW.md)。
- **訓練前先檢查。** 查看點雲、回放拍攝路線、續掃補拍，並可量測或校正公尺尺度。詳見[融合進度與預覽](docs/FUSION_REVIEW.zh-TW.md)與[公尺尺度](docs/LOOP_CLOSURE_AND_SCALE.zh-TW.md)。
- **在 iPhone 上訓練 3DGS。** 以 MRNF 為基礎的 Metal 訓練器，加上姿態精修、LiDAR 深度種子與深度損失；訓練中可旋轉查看即時預覽、暫停與續訓，完成後輸出體積小的 SOG 模型分享。詳見[手機端 3DGS 訓練](docs/ON_DEVICE_3DGS.zh-TW.md)。
- **匯出 COLMAP 資料集。** 原始照片、`sparse/0`、深度與姿態打包成一個 ZIP。詳見[匯出](docs/HISTORY_TRAINING_EXPORT.zh-TW.md)與[外部訓練](docs/TRAINING.zh-TW.md)。
- **掃描紀錄。** 停止掃描後自動保存，可以預覽、訓練、另存優化版本、匯出或刪除。
- **繁體中文（預設）與英文**，在首頁切換。

```text
掃描 → 資料優化 → 檢查點雲 ─┬─ 在 iPhone 上訓練 3DGS → 檢視／分享模型
                 │          └─ 匯出 COLMAP ZIP → 外部 3DGS 訓練
                 └─ 續掃補拍
```

## 快速開始

**需求：** Xcode 26 以上，以及 iOS 17 以上的 iPhone 或 iPad。手機端訓練需要 A14 或更新的晶片；LiDAR 深度需要有 LiDAR 的裝置。Simulator 只能檢查介面，不能真的進行 AR 掃描。

```sh
git clone https://github.com/KuoFengYuan/arkit-3dgs-scanner.git
open arkit-3dgs-scanner/arkit-3dgs-scanner.xcodeproj
```

1. 在 Xcode 選 `arkit-3dgs-scanner` scheme、自己的簽章 Team 與實體裝置，然後執行。
2. 按「開始掃描」，在場景中移動，讓每個表面都從幾個不同位置被拍到。
3. 停止後等待處理完成，檢查點雲；有缺漏就續掃。
4. 按「訓練 3DGS」在手機上建立模型，或按「匯出 3DGS 訓練資料」分享 ZIP 給電腦上的訓練器。

## 在 iPhone 上訓練 3DGS

| 品質 | 迭代次數 | Gaussian 上限 |
| --- | --- | --- |
| 快速預覽 | 4,000 | 300,000 |
| 標準（建議） | 10,000 | 600,000 |
| 高品質 | 20,000 | 1,000,000 |

- **解析度：** 訓練影像可選 960（預設）、1,440，或照片原始的 1,920 px。
- **迭代次數：** 照片多的掃描會自動增加次數；開始前可以自行調整。
- **訓練中：** 可以繼續使用 App 的其他功能。手機過熱、電量不足、記憶體吃緊或切到其他 App 時，會先存檔再暫停。iOS 26 加上 Background GPU Access 權限後，可以在背景繼續訓練。
- **隨時提前完成**，之後可以用「加強模型」繼續訓練。
- **分享：** `scan_…-3dgs.zip` 內含 `gaussians.sog`，SuperSplat、PlayCanvas 與 LichtFeld Studio 可以直接開啟。

iPhone 上的訓練速度、記憶體用量與發熱還沒實測，Mac 與 Simulator 的結果不能代替。操作方式、方法、實測結果與檔案格式詳見[手機端 3DGS 訓練](docs/ON_DEVICE_3DGS.zh-TW.md)。

## 開發

遵循 [貢獻流程](CONTRIBUTING.zh-TW.md) 與 [工作規範](AGENTS.zh-TW.md)：使用任務分支（`Feature/`、`Bugfix/`、`Enhance/`），開 PR 到 `main`，合併後刪除分支。貢獻流程裡列出檢查指令、程式結構與可選的 Python 工具。

```sh
python3 tools/check_project.py
bash tools/test_localization.sh
```

## 授權

Copyright 2026 Kuo Feng-Yuan（[KuoFengYuan](https://github.com/KuoFengYuan)）。本專案採用 [Apache License 2.0](LICENSE)。

**本專案為個人研究專案**，並非任何雇主或機構的產品，未經其背書，也不代表其立場。本專案依現狀提供，不附任何擔保。

- **可以商用**，包含手機端 3DGS 訓練器；也可以修改與再散布。
- **必須標註作者**：任何複製或衍生作品都要保留 [LICENSE](LICENSE) 與 [NOTICE](NOTICE)，並註明原作者為 Kuo Feng-Yuan（KuoFengYuan）。
- 3DGS 訓練器是以 Swift 與 Metal 獨立實作。其中不含原版 3D Gaussian Splatting（Inria／MPII）與 Mip-Splatting 的程式碼，這兩者只允許非商用；也不含 LichtFeld Studio（GPL-3.0）的程式碼。參考的論文與專案列在 [NOTICE](NOTICE)。
- 部分方法仍可能涉及第三方專利；以上不構成法律意見，商用前請自行確認。

## 文件索引

| 主題 | 文件 |
| --- | --- |
| 掃描 | [掃描架構](docs/CAPTURE_ARCHITECTURE.zh-TW.md) · [介面設計](docs/INTERFACE_DESIGN.zh-TW.md) · [即時預覽與品質閘門](docs/LIDAR_QUALITY_AND_PREVIEW.zh-TW.md) · [拍攝吞吐量](docs/CAPTURE_THROUGHPUT.zh-TW.md) · [裝置操作](docs/DEVICE_NOTES.zh-TW.md) |
| 處理 | [融合進度與預覽](docs/FUSION_REVIEW.zh-TW.md) · [姿態精修](docs/POSE_REFINEMENT.zh-TW.md) · [閉環修正與公尺尺度](docs/LOOP_CLOSURE_AND_SCALE.zh-TW.md) · [LiDAR 多視角共識](docs/LIDAR_SURFACE_CONSENSUS.zh-TW.md) · [無 LiDAR 重建](docs/CAMERA_ONLY_ACCURACY.zh-TW.md) · [表面重建](docs/SURFACE_RECONSTRUCTION.zh-TW.md) · [融合診斷](docs/SCAN_FUSION_DIAGNOSTICS.zh-TW.md) · [大場景記憶體](docs/LARGE_SCAN_MEMORY.zh-TW.md) |
| 3DGS | [手機端訓練](docs/ON_DEVICE_3DGS.zh-TW.md) · [訓練架構](docs/ON_DEVICE_3DGS_ARCHITECTURE.zh-TW.md) · [手機端資料優化](docs/ON_DEVICE_TRAINING_QUALITY.zh-TW.md) · [外部訓練](docs/TRAINING.zh-TW.md) |
| 資料 | [匯出](docs/HISTORY_TRAINING_EXPORT.zh-TW.md) · [座標慣例](docs/COORDINATES.zh-TW.md) · [語系說明](docs/LOCALIZATION.zh-TW.md) |

每份文件開頭都有英文版連結。回報可重現的問題時，請附上裝置、掃描模式、建置設定、處理報告，可以的話再附一小份掃描樣本。
