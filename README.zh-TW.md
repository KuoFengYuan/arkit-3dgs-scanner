# ARKit 3DGS Scanner

[English](README.md) | **繁體中文**

使用 ARKit 擷取照片、相機姿態與點雲，在手機完成品質檢查、姿態精修、深度融合和預覽，再匯出標準 COLMAP 資料集供外部 3D Gaussian Splatting（3DGS）訓練使用。

**目前 App 專注於掃描與資料準備，已移除手機端 3DGS 訓練及訓練結果檢視器。** 照片篩選、相機精修、點雲重融合仍在手機執行，不需要上傳。GitHub、本機專案及 scheme 均為 `arkit-3dgs-scanner`；App 識別碼保留 `itri.fable`，讓既有安裝與掃描資料延續。

```text
開始掃描 → 自動擷取影像 → 停止與資料優化 → 檢查點雲
                                            ├─ 續掃補拍
                                            └─ 匯出 3DGS 訓練資料 ZIP
掃描紀錄 → 照片／點雲／路線預覽 → 優化資料／匯出／刪除
```

新增中英文科技感融合進度頁、第一人稱路線回放與分段匯出保護。詳見[融合進度、第一人稱預覽與匯出穩定性](docs/FUSION_REVIEW.zh-TW.md)。

- **實驗性表面重建：** 有上限的局部 RGB-D 姿態精修與稀疏 TSDF 表面點，保留完整 voxel 融合備援。TSDF 使用單一有界暫存檔與批次寫入保留完整精度；達點數上限時以穩定空間順序取樣。融合另加入單張 JPEG 預讀與精確深度有效性快取，不改取樣或門檻。詳見[流程、效能比較與限制](docs/SURFACE_RECONSTRUCTION.zh-TW.md)。

## 主要功能

| 功能 | 說明 |
| --- | --- |
| ARKit 掃描 | 依位移、轉角與品質自動保存關鍵影格；保存逐幀相機內參、姿態與時間戳 |
| LiDAR 開關 | 開拍前選擇使用深度掃描，或以 RGB、ARKit 稀疏特徵及可選影像重建採集 |
| 點雲融合 | 即時點雲預覽；停止後以多視角深度支持與有界修正減少重影、厚層和雜點 |
| 手機端資料優化 | 選擇清晰照片、跨幀匹配、驗證局部精修與有界閉環修正、以相同姿態重新融合深度 |
| 公尺尺度 | 點雲選點量距、已知長度校正、獨立距離驗證，同步匯出縮放後相機與點雲 |
| 歷史紀錄 | 停止後自動保存；可預覽、另存優化版本、匯出、單筆／多選／全部刪除 |
| 影像與路線回放 | 照片和 3D 相機位置同步；可調 FPS、拖曳進度、全螢幕及自動跟隨 |
| 平面圖 | 在支援的模式與裝置上擷取或推估結構，成功時可預覽及匯出 |
| 訓練資料匯出 | 原始影像、標準 COLMAP `sparse/0`、PLY、姿態及品質報告 |

## 快速開始

1. 使用 Xcode 26 或更新版本開啟 `arkit-3dgs-scanner.xcodeproj`，選取 `arkit-3dgs-scanner` scheme 與自己的簽章 Team。 Run 預設使用最佳化 Release；需要逐行除錯時才選 `arkit-3dgs-scanner-Debug`。詳見[融合速度與表面重影](docs/SCAN_FUSION_DIAGNOSTICS.zh-TW.md)。
2. 安裝至支援 ARKit 的 iPhone／iPad；專案最低部署版本為 iOS 17。LiDAR 深度與 RoomPlan 功能需對應硬體支援。
3. 按「開始掃描」，允許相機存取，等待追蹤就緒；開拍前選擇 LiDAR、精細掃描等設定。
4. 沿著空間移動，從不同角度拍到同一表面。停止後等待資料優化，檢查點雲與缺漏，必要時「續掃」。
5. 按「匯出 3DGS 訓練資料」，將 ZIP 分享到電腦；解壓後由支援 COLMAP 資料集的外部訓練器載入。

Simulator 可驗證一般介面與資料流程，不能代替真機 ARKit／LiDAR 掃描。已安裝的舊版 App 不會自動取得原始碼變更，需重新建置安裝。

## 介面與操作

首頁優先顯示掃描紀錄，首次操作指南可按需展開。開拍前點選「掃描設定」，以可捲動面板調整掃描模式、品質、相機與座標系。表面重建會明確顯示已包含姿態精修；若要獨立調整精修，請先關閉表面重建。

成果頁將品質資訊放進獨立可捲動面板，避免長篇診斷遮住點雲。歷史預覽的「更多操作」包含空間尺度驗證、資料優化與刪除，底部主按鈕負責匯出或分享。刪除仍需確認，並移除所選掃描的完整資料。掃描工具具有 44 點觸控範圍與輔助使用標籤，新增操作均提供繁體中文與英文。

## 掃描模式與品質

### LiDAR 與純相機模式

| 模式 | 採集與重建 |
| --- | --- |
| LiDAR 開啟 | RGB、相機姿態、感測深度與可信度；可使用 mesh 補洞、RoomPlan 與 LiDAR 輔助姿態精修 |
| LiDAR 關閉 | RGB、相機姿態、經驗證的稀疏特徵點；可在停止後用多視角照片估算幾何，不保存 LiDAR 深度 |

模式只能在開拍前切換。`capture-meta.json` 分別記錄硬體能力 `lidarAvailable` 與本次選擇 `lidarEnabled`。開關控制 App 請求與使用的深度功能，不是感測器電源控制，也無法保證 ARKit 內部完全不用 LiDAR。

相機模式依賴紋理、清晰度與視差，不能把影像推估深度視為感測器量測。詳見 [相機模式精度](docs/CAMERA_ONLY_ACCURACY.zh-TW.md)。

### 厚層、重影與姿態精修

- 重融合優先選不同位置的參考深度；需要多視角支持，再沿原相機射線作最多 2 cm 的共識修正。
- 修正前後檢查可信度、深度邊界、遮擋與自由空間矛盾；mesh 補點同樣需要支持，避免重新補回厚層。
- 「精細掃描」逐張匹配影像，以保持 ARKit 相鄰影格運動的聯合光束法平差精修相機，並做有界重訪閉環驗證；使用自訂演算法，沒有移植 COLMAP／Ceres。局部姿態精修會先沿路線試算，通過才完整執行；試算被拒絕時保留已接受姿態，TSDF 仍繼續。照片驗證也會檢查修正後失去投影的樣本。結果須通過保留觀測與照片對齊檢查（比對重疊影格的影像紋理）才套用。兩份掃描的桌機重跑中，舊精修未通過此檢查；新精修讓寬基線 NCC 中位數提高約 0.02，局部表面階段則被拒絕。資料不足或驗證失敗時保留既有姿態。詳見[姿態精修](docs/POSE_REFINEMENT.zh-TW.md)。
- RGB 照片選用與深度融合分開：實際清晰度與視角差異決定訓練照片，可靠深度仍可保留。原始照片不因篩選而刪除。

569 幀掃描的局部厚度中位數曾由 8.94 降到 7.01 cm（約 21.6%）。這是固定局部區域的表面一致性量測，包含真實家具／多層結構，**不是絕對尺寸精度，也不保證 3DGS 無殘影**。方法、效能代價與限制見 [LiDAR 表面共識](docs/LIDAR_SURFACE_CONSENSUS.zh-TW.md)。

3 公尺以外的深度使用獨立的 4 公分格，避免遠距雜訊迫使近距表面粗化。**新增覆蓋保護為實驗選項，預設關閉**：以最終表面檢查缺口與邊界，並在可見性清理保護局部區域。實際重播找回部分覆蓋，但局部厚度增加，因此維持正式預設融合行為；不能宣稱尺寸精度已提升。見[距離優先](docs/LIDAR_SURFACE_CONSENSUS.zh-TW.md)與[覆蓋驗證及重播結果](docs/SCAN_FUSION_DIAGNOSTICS.zh-TW.md)。

### 大場景記憶體

逐幀讀取照片與深度，參考深度快取上限 8 幀／2 MiB；融合 grid 依記憶體預算限制並在必要時粗化，手機輸出點數上限目前為 250,000。這些限制仍用於掃描後處理，移除訓練器不代表可以無限制提高點數。

已有 1,000 幀合成深度串流測試，並保留取消與低記憶體回退。這不是實機長時間掃描不閃退的保證。詳見 [大場景記憶體](docs/LARGE_SCAN_MEMORY.zh-TW.md) 與 [採集吞吐量](docs/CAPTURE_THROUGHPUT.zh-TW.md)。

兩次 iPhone 17 Pro 閃退已定位為融合達 100% 後的 stderr 日誌寫入例外，已改用系統日誌。處理前清除採集快取、停止被遮住的相機渲染，插入／粗化內部檢查壓力，並預留 192 MiB 加單幀工作區；回退仍保留原始資料。詳見[裝置證據與記憶體控制](docs/LARGE_SCAN_MEMORY.zh-TW.md)。

## 歷史、回放與刪除

停止後自動保存預覽與摘要，不必先匯出。首頁「掃描紀錄」可開啟既有掃描：

- **拍攝影像**：照片與橘色相機位置／方向同步，支援跟隨或完整路線檢視；換圖完成前保留上一張，避免輪播閃爍。預覽按姿態旋正，原始 JPEG 不變。
- **播放速度**：0.5、1、2、5、10、15、30 fps；這是已保存關鍵影格的播放速度，不是原始等速影片。
- **優化訓練資料**：在手機重新處理照片、姿態與點雲，完成後另存新版本；此操作不執行 Gaussian 訓練。詳見 [手機端資料優化](docs/ON_DEVICE_TRAINING_QUALITY.zh-TW.md)。
- **空間尺度與驗證**：選點量距、輸入已知長度校正、另選參考距離驗證；可另存公尺 COLMAP ZIP，同步縮放相機與點雲，不附原始深度。參考通過不代表整體精度認證。詳見[閉環修正與公尺尺度](docs/LOOP_CLOSURE_AND_SCALE.zh-TW.md)。
- **多選／全部刪除**：移除選定掃描的完整資料夾與一般／公尺版 ZIP，包含照片、深度、姿態、點雲與模型。舊版掃描若有 `gaussians.ply`，也在整筆刪除範圍內；不影響未選紀錄、系統相簿或已分享出去的副本。

歷史紀錄可預覽與重處理；離開掃描工作階段後，不能從歷史頁直接恢復原本的即時續掃。

## 匯出資料

新掃描與歷史匯出都先產生完整 COLMAP 資料，再打包 ZIP。訓練影像清單以 `sparse/0/images.bin` 為準，`images/` 保留所有原始照片。

```text
scan_…/
├── images/                    # 感測器原始方向 JPEG
├── depth/                     # LiDAR 深度／可信度 sidecar（相機模式無此量測）
├── sparse/0/
│   ├── cameras.bin            # 逐幀內參
│   ├── images.bin             # 選用影像與 world-to-camera 姿態
│   └── points3D.bin           # 初始化點雲
├── points.ply                 # ARKit 世界座標點雲
├── poses.jsonl                # 原始採集姿態
├── poses_refined.jsonl        # 匯出所選影像的處理後姿態
├── capture-meta.json          # 裝置與掃描模式
├── review.ply                 # 歷史預覽點雲
├── review-poses.jsonl          # 預覽／回放姿態
├── scan-summary.json          # 影格數與點數
├── training-selection.json    # 照片選用與補拍提示
├── pose-refinement.json       # 若有執行相機精修，其驗證結果
└── refusion-progress.json     # 若有重融合，其耗時與資源資訊
```

新掃描使用 `capture-meta.json`；舊 `meta.json` 仍可讀取，匯出時自動改名，避免與外部訓練器的格式判斷衝突。兩者同時存在時優先使用新檔，舊檔另存為不衝突的 capture 中繼資料檔。

依啟用功能及成功結果，可能另有平面圖、世界地圖、影像重建及採集效能報告。新版不產生 `gaussians.ply`；舊版掃描既有模型仍隨原資料保留與分享。

COLMAP 相機與 `points3D.bin` 預設一起繞世界 X 軸旋轉 180°；`points.ply`、`review.ply` 與 JSONL 保留 ARKit 世界座標。不要把不同座標系的點雲與姿態直接混用。詳見 [座標系](docs/COORDINATES.zh-TW.md) 與 [歷史訓練匯出](docs/HISTORY_TRAINING_EXPORT.zh-TW.md)。

輸出模型用於提供校準相機與初始化點，沒有完整 SfM 特徵觀測與 tracks；不能只執行 COLMAP BA 就期待補出缺少的觀測。沒有種子點時仍可匯出空點集，但外部訓練器可能需要額外初始化。

## 程式結構

```text
arkit-3dgs-scanner.xcodeproj/               # Xcode 專案
arkit-3dgs-scanner/
├── ContentView.swift          # 首頁與入口
├── Capture/
│   ├── CaptureController.swift
│   ├── CancelFlag.swift       # 背景掃描工作的共用取消旗標
│   ├── FrameWriter.swift
│   ├── DepthSampleFilter.swift
│   ├── RefusionEngine.swift
│   ├── OfflinePoseRefinement.swift
│   ├── TrainingFrameSelector.swift  # 資料選幀，非訓練器
│   ├── ExportManager.swift
│   └── UI/                    # 掃描、驗收與匯出介面
└── History/                   # 紀錄、同步回放、重處理與完整刪除
tools/                         # 資料轉換、分析及回歸測試
docs/                          # 架構、座標、品質與效能說明
```

手機端 `Training/`、msplat C++／Metal 引擎、Swift 橋接與專用建置設定已移除。掃描、預覽與 COLMAP 資料準備不依賴該引擎。

## 開發與驗證

```sh
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner \
  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

`tools/test_*.swift` 涵蓋寫入、幾何一致性、深度快取、大場景、歷史匯出與回放；`tools/test_math.py` 驗證座標轉換。編譯與合成測試不能代替真機的感測器、精度、溫度和長時間記憶體驗證。

可選 Python 工具：

```sh
python3 -m venv .venv
.venv/bin/pip install -r tools/requirements.txt
.venv/bin/python tools/test_math.py
.venv/bin/python tools/validate_dataset.py /path/to/scan
.venv/bin/python tools/arkit2gs.py /path/to/scan -o /path/to/dataset --format both
```

更多說明：[掃描架構](docs/CAPTURE_ARCHITECTURE.zh-TW.md)、[深度品質與即時預覽](docs/LIDAR_QUALITY_AND_PREVIEW.zh-TW.md)、[外部訓練說明](docs/TRAINING.zh-TW.md)。

## 雙語與開發流程

App 預設繁體中文，首頁可切 English 並保存選擇；文件英文優先，每份提供繁中對照。動態訊息、錯誤與無障礙標籤也支援雙語。詳見 [語系說明](docs/LOCALIZATION.zh-TW.md)。

融合後單純運動估計偏高不再出補拍警告，放在收合的品質資訊；有實測細節偏弱才顯示需檢查的影格。這不會去除照片模糊，也不更動原照片／可靠深度。

遵循 [貢獻流程](CONTRIBUTING.zh-TW.md)與 [工作規範](AGENTS.zh-TW.md)：Feature/ 新功能、Bugfix/ 修錯、Enhance/ 改善，區分大小寫。完成驗證後 commit/push、開 PR、必要檢查通過後合併，刪除本次遠端與本機分支，回到 main；不繞過保護。

```sh
python3 tools/check_project.py
bash tools/test_localization.sh
bash tools/test_training_quality.sh
bash tools/test_metric_loop.sh
bash tools/test_fusion_memory.sh
```

## 文件索引

- [掃描架構](docs/CAPTURE_ARCHITECTURE.zh-TW.md)
- [姿態精修與照片對齊驗證](docs/POSE_REFINEMENT.zh-TW.md)
- [閉環修正與公尺尺度](docs/LOOP_CLOSURE_AND_SCALE.zh-TW.md)
- [手機端資料優化](docs/ON_DEVICE_TRAINING_QUALITY.zh-TW.md)
- [LiDAR 多視角共識](docs/LIDAR_SURFACE_CONSENSUS.zh-TW.md)
- [無 LiDAR 重建](docs/CAMERA_ONLY_ACCURACY.zh-TW.md)
- [歷史匯出](docs/HISTORY_TRAINING_EXPORT.zh-TW.md)
- [外部訓練](docs/TRAINING.zh-TW.md)
- [拍攝吞吐量](docs/CAPTURE_THROUGHPUT.zh-TW.md)
- [即時預覽與品質閘門](docs/LIDAR_QUALITY_AND_PREVIEW.zh-TW.md)
- [大場景記憶體](docs/LARGE_SCAN_MEMORY.zh-TW.md)
- [座標慣例](docs/COORDINATES.zh-TW.md)
- [裝置操作](docs/DEVICE_NOTES.zh-TW.md)
