# ARKit 3DGS Scanner

**用 iPhone 掃描，直接在手機上訓練 3D Gaussian Splatting，或匯出資料集。**

[English](README.md) | **繁體中文**

**本專案為個人研究專案，供非商業用途使用。[PolyForm Noncommercial License 1.0.0](LICENSE) 不允許商業用途。**

## 訓練優化亮點

> [!IMPORTANT]
> **模型訓練已加速：以下 F21171 基準測試中，iPhone 17 Pro 快 1.39 倍，Mac（M1 Pro）最高快 1.45 倍。** 三份掃描的品質比較也顯示，相對本專案最初的 MRNF 訓練器，**PSNR 提升 1.65–2.48 dB**。

### 訓練速度：優化前後比較

F21171，固定 **10,000 次迭代**、960 px、開啟 PPISP、高斯上限 600,000，使用 715 張訓練照片與同一批 143 張保留照片。這次速度優化前後的訓練方法與設定相同。

| 裝置 | 優化前 | 優化後 | 加速倍數 |
| --- | --- | --- | --- |
| Mac，M1 Pro（前後各跑兩次） | 374.2／386.7 s | **261.7／277.6 s** | **1.37–1.45 倍** |
| iPhone 17 Pro（前後均為 `serious` 散熱狀態） | 769.4 s | **553.1 s** | **1.39 倍** |

Mac 的加速倍數以優化前兩次的平均時間計算；優化後第 2 次同時在編譯 Xcode 專案。手機若改與另一個起始較涼的優化前測試（658.0 s）比較，則快 1.19 倍。手機使用 iOS 27.0 的 Release 基準測試版本，直接呼叫訓練器，不含即時預覽。其他 iPhone、高品質、全解析度訓練與一般訓練畫面尚未量測。詳見[完整速度基準測試](docs/ON_DEVICE_3DGS.zh-TW.md#加快大型掃描的訓練步驟)。

### PSNR：累積的品質改善

以 iPhone 17 Pro 採集的掃描，在 Mac 上評分；**保留照片經測試時姿態對齊，PSNR 越高越好**。MRNF 基底是本專案最初的 Swift／Metal 實作。目前結果包含精準度改良與較長的預設，將部分省下的時間用於更多迭代。

| 掃描 | 最初的 MRNF 基底 | 精準度改良後、加速前 | 目前訓練器 | 相對最初基底的提升 |
| --- | --- | --- | --- | --- |
| FBDA13 | 27.56 dB | 29.13 dB | **30.04 dB** | **+2.48 dB** |
| 7F2187 | 24.25 dB | 25.97 dB | **26.66 dB** | **+2.41 dB** |
| 9F8040 | 27.45 dB | 28.31 dB | **29.10 dB** | **+1.65 dB** |

這些提升來自歷次訓練改良的累積效果，不能全部歸因於最新的速度優化。詳見[方法與比較](docs/ON_DEVICE_3DGS.zh-TW.md#方法)與[速度及較長的預設](docs/ON_DEVICE_3DGS.zh-TW.md#速度與較長的預設)。

### PSNR：最新速度優化在相同工作量下的比較

上述 F21171 固定 10,000 次迭代的基準測試，同時檢查速度與品質。Mac 數值為每個版本兩次執行的平均；手機為每個版本一次、相同散熱狀態下的結果。

| 裝置／指標 | 優化前 | 優化後 | 差異 |
| --- | --- | --- | --- |
| Mac：保留照片對齊後 PSNR | 23.861 dB | **23.859 dB** | −0.002 dB |
| Mac：1,920 px 排除色差後 PSNR | 25.329 dB | **25.354 dB** | +0.025 dB |
| iPhone 17 Pro：保留照片對齊後 PSNR | 23.946 dB | **23.907 dB** | −0.039 dB |

PSNR 差異落在 Mac 基準重跑最高約 0.10 dB 的波動範圍內。排除色差的評分會先校正整體亮度與色彩差異。Mac 的空像素比例平均增加 0.4 個百分點；前後各只有兩次，尚無法判定這項差異。詳見[完整品質結果與量測方式](docs/ON_DEVICE_3DGS.zh-TW.md#加快大型掃描的訓練步驟)。

<a href="docs/media/demo.mp4"><img src="docs/media/demo.gif" width="320" alt="一次掃描從擷取到完成 3DGS 模型：掃描、融合、訓練與完成的模型"></a>

*20 秒循環，8 倍速。[觀看 1 分鐘影片](docs/media/demo.mp4)（2.7 倍速）：掃描桌面、優化資料，並在 iPhone 上訓練 3DGS 模型。*

本專案研究如何在 iPhone 上採集並重建 3D 場景。用 ARKit 擷取照片、相機姿態與點雲，在手機上完成優化，再用 iPhone 的 GPU 訓練 3DGS 模型，或匯出 COLMAP 資料集給電腦上的訓練器。採集、優化與手機端訓練均在裝置上執行，App 不會上傳掃描資料。

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

以上述基準測試實測過 iPhone 17 Pro 的訓練速度、記憶體用量與散熱狀態；其他裝置與含即時預覽的訓練畫面仍待量測。Mac 與 Simulator 結果不能用來推定 iPhone 效能。操作方式、方法、實測結果與檔案格式詳見[手機端 3DGS 訓練](docs/ON_DEVICE_3DGS.zh-TW.md)。

## 開發

遵循 [貢獻流程](CONTRIBUTING.zh-TW.md) 與 [工作規範](AGENTS.zh-TW.md)：使用任務分支（`Feature/`、`Bugfix/`、`Enhance/`），開 PR 到 `main`，合併後刪除分支。貢獻流程裡列出檢查指令、程式結構與可選的 Python 工具。

素材目錄已包含 1024 × 1024 的 App 圖示，可用於 iOS 封存版本與 TestFlight 發佈。

```sh
python3 tools/check_project.py
bash tools/test_localization.sh
```

## 版權與授權

Copyright © 2026 Kuo Feng-Yuan（[KuoFengYuan](https://github.com/KuoFengYuan)）。本專案採用 [PolyForm Noncommercial License 1.0.0](LICENSE)；該授權未授予的權利均予保留。

**本專案為個人研究專案**，並非任何雇主或機構的產品，未經其背書，也不代表其立場。本專案依現狀提供，不附任何擔保。

- **本授權僅允許非商業用途**，包含手機端 3DGS 訓練器。可依 [LICENSE](LICENSE) 定義的允許用途使用、修改與再散布，包含非商業研究及個人學習；商業用途不在本授權範圍內。
- **必須標註作者**：再散布時須提供授權條款或其網址，以及 [NOTICE](NOTICE) 中以 `Required Notice:` 開頭的作者署名。將 [LICENSE](LICENSE) 與 [NOTICE](NOTICE) 隨複製或衍生作品一同保留，即可提供兩者。
- **版權涵蓋範圍**：原始碼、文件，以及 `docs/media` 中的示範錄影，均為作者本人的作品。每個原始碼檔開頭都有 `SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0` 檔頭。
- **App 圖示**：由作者指示 AI 影像生成工具製作。這類影像在部分法域可能不受著作權保護；在作者享有權利的範圍內，以相同條款授權。
- 3DGS 訓練器是以 Swift 與 Metal 獨立實作。其中不含原版 3D Gaussian Splatting（Inria／MPII）與 Mip-Splatting 的程式碼，這兩者只允許非商用；也不含 LichtFeld Studio（GPL-3.0）的程式碼。參考的論文與專案列在 [NOTICE](NOTICE)。
- **檔案格式**：COLMAP 匯出與 SOG 模型檔依照 COLMAP 與 PlayCanvas 文件所定義的格式。兩者的程式碼都未包含在內，讀寫程式是本專案自行撰寫。
- **第三方軟體**：App 只使用 Apple 的系統框架。Python 工具需要另外安裝的套件（`tools/requirements.txt`），各自依其授權；本 repo 未包含任何第三方套件。
- **商標**：Apple、iPhone、ARKit 與 Metal 是 Apple Inc. 的商標。其他產品與專案名稱屬於各自的所有者，僅用於說明相容性，不代表任何背書。
- 部分方法仍可能涉及第三方專利；本授權未授予第三方專利的權利。

**先前發布內容：** 截至 commit `d5d8e31` 以 Apache 2.0 發布的內容，仍保有原授權的權利，包含商業使用；本次變更不撤回已授予的權利。詳見[授權範圍與歷史](docs/LICENSING.zh-TW.md)及[歷史 Apache 2.0 條款](licenses/Apache-2.0.txt)。

原始碼已與參考實作比對過，見[來源與授權](docs/ON_DEVICE_3DGS.zh-TW.md#來源與授權)。

## 文件索引

| 主題 | 文件 |
| --- | --- |
| 掃描 | [掃描架構](docs/CAPTURE_ARCHITECTURE.zh-TW.md) · [介面設計](docs/INTERFACE_DESIGN.zh-TW.md) · [即時預覽與品質閘門](docs/LIDAR_QUALITY_AND_PREVIEW.zh-TW.md) · [拍攝吞吐量](docs/CAPTURE_THROUGHPUT.zh-TW.md) · [裝置操作](docs/DEVICE_NOTES.zh-TW.md) |
| 處理 | [融合進度與預覽](docs/FUSION_REVIEW.zh-TW.md) · [姿態精修](docs/POSE_REFINEMENT.zh-TW.md) · [閉環修正與公尺尺度](docs/LOOP_CLOSURE_AND_SCALE.zh-TW.md) · [LiDAR 多視角共識](docs/LIDAR_SURFACE_CONSENSUS.zh-TW.md) · [無 LiDAR 重建](docs/CAMERA_ONLY_ACCURACY.zh-TW.md) · [表面重建](docs/SURFACE_RECONSTRUCTION.zh-TW.md) · [融合診斷](docs/SCAN_FUSION_DIAGNOSTICS.zh-TW.md) · [大場景記憶體](docs/LARGE_SCAN_MEMORY.zh-TW.md) |
| 3DGS | [手機端訓練](docs/ON_DEVICE_3DGS.zh-TW.md) · [訓練架構](docs/ON_DEVICE_3DGS_ARCHITECTURE.zh-TW.md) · [手機端資料優化](docs/ON_DEVICE_TRAINING_QUALITY.zh-TW.md) · [外部訓練](docs/TRAINING.zh-TW.md) |
| 資料 | [匯出](docs/HISTORY_TRAINING_EXPORT.zh-TW.md) · [座標慣例](docs/COORDINATES.zh-TW.md) · [語系說明](docs/LOCALIZATION.zh-TW.md) |

每份文件開頭都有英文版連結。回報可重現的問題時，請附上裝置、掃描模式、建置設定、處理報告，可以的話再附一小份掃描樣本。
