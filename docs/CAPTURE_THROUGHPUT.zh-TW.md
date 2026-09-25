# 拍攝吞吐量與預覽工作預算

[English](CAPTURE_THROUGHPUT.md) | **繁體中文**

## 依據與目標

`scan_20260920_134924_542C66` 有 45 張照片、約 83.24 秒，照片間隔中位數 2.026 秒、P90 2.179 秒；品質判定拒絕 32 / 5,005 幀。834 次即時融合平均約 66.1 ms、最大 409.8 ms，主執行緒幾何套用平均約 0.15 ms。這表示不能只靠放寬品質門檻解決拍攝稀疏。

程式原先在照片寫完後仍等待 `FeatureTracker.add`，才釋放 `pendingWrites` 名額。特徵處理過慢時，照片即使已寫完也持續佔用三個寫入名額。本輪移除這個耦合；舊資料沒有 JPEG／特徵分段計時，尚不能量化它佔兩秒間隔的多少比例。

## 照片與可選特徵工作

`FrameWriter` 仍序列化 JPEG、深度、信心圖及 JSONL 寫入，最多三個待完成照片工作。每次寫入使用 `autoreleasepool` 釋放編碼暫存，回傳排隊／編碼／I/O 耗時。只有成功寫入才增加保存張數。

成功後呼叫 `LatestFrameProcessor.submit` 即返回，不等待特徵匹配。該 actor 最多保留一個執行中工作及一個最新待處理工作，新的提交取代舊的待處理影格，使用 utility 優先序。影像是應用程式自己的 buffer 複本，不保留 `ARFrame`；讀取期間不修改內容。這不是整個 App 最多五張 buffer 的保證，ARKit、預覽、編碼與 pool 另有用量。

停止時先等待所有照片工作，再 `drain` 特徵工作，完成後才讀取 BA 觀測。續掃沿用已排空的工作佇列；離開或重建掃描時關閉舊佇列、丟棄待處理工作，以掃描 generation 防止舊回呼修改新掃描。執行中的舊工作可完成，但只持有舊 tracker。

`FeatureTracker` 只保留最近四幀描述子，因為匹配原本只回看四幀。淘汰前把已有 track 的特徵轉為不含影像 patch 的觀測；舊觀測仍可與新觀測組成至少三幀的 track 供 BA 使用。歷史區最多 200,000 筆，另加最近四幀觀測；超過時淘汰最舊部分並記錄數量。這是 BA 的記憶體／歷史範圍折衷，不會刪除磁碟照片或改掉其原始姿態。高負載時只有部分照片參與特徵匹配，並非所有保存照片都會有 BA 觀測。

## 即時深度取樣

`PreviewSamplingBudget` 將一次候選深度位置限制為 6,000 個；256 × 192 深度圖起始實際步長為 3，而原先步長 2 會遍歷 12,288 個位置。不同更新輪替 x/y 起點，固定步長時可遍歷所有像素；相機移動、過濾或步長改變仍可能造成局部細節缺失，不能保證每個表面都被觀測。

整次擷取、時間一致性檢查與格插入超過 35 ms，下一次增大步長；連續 12 次低於 17.5 ms 才減小一步。時間回饋步長範圍為設定下限至 6；若深度圖特別大，候選數上限可要求更大的實際步長。融合格粗化等操作仍可能出現超時，這不是硬即時截止時間。

原始照片、深度保存解析度、深度一致性門檻、voxel 尺寸與離線重融合取樣不因這個預覽預算而改變。低記憶體時若退回即時預覽，回退結果也會反映較稀的即時取樣。無 LiDAR 的稀疏點路徑不套用深度預算。

## 長時間掃描（600 張以上）

超過約 600 張照片的掃描會感覺卡頓。每張照片的背景工作有上限：FBDA13（405 張）的特徵工作平均每張 10 ms，歷史觀測也有上限（見上文）。會隨照片數增加的，是**每一幀**都要重做的工作：

- **相機標記：** 每存一張照片就多一個 SceneKit 節點，各有自己的角錐幾何與材質。SceneKit 無法合併這些繪製，所以每一幀都要為每張照片多一次繪製呼叫。
  - 在 Mac GPU 上（離屏 `SCNRenderer`，每幀 CPU 時間），各自一個節點時，100 張為 0.35 ms、600 張為 2.38 ms、1,000 張為 4.13 ms。
  - 合併成一組線段後，任何張數都只要 0.017 ms。
  - 現在全部標記是同一個幾何（`CameraMarkerLines`），只在存下照片時重建；軌跡線原本就只有一個節點。
  - iPhone 的 CPU 較慢，還要和 ARKit 分用同一幀，佔 16.7 ms 幀時間的比例會比 Mac 高；這部分尚未在實機量測。
- **錨點節點：** 每張照片與每塊預覽點雲磚都有一個 ARKit 錨點。沒有指定 delegate 時，`ARSCNView` 會替每個錨點加一個空節點，並在每一幀讓它跟著錨點移動。現在畫面不再建立這些節點（`LiveSceneDelegate`），點雲磚本來就有自己的節點。錨點本身沒有變，ARKit 照樣修正它們，停止時也照樣從錨點讀回照片姿態。
- **點雲磚變換：** 先前每一幀都重設每個磚節點的變換。融合用的快照（`latestTileTransforms`）仍然每幀從錨點完整讀取，完全不變；只有錨點真的移動過的磚，才會更新畫面上的節點。

這些修改都不影響保存或融合的內容：照片、深度、姿態、ARKit 修正與點雲資料都相同。

## 診斷檔案

停止後、進入重融合前保存 `capture-performance.json`，掃描資料打包時一起匯出：

| 欄位 | 意義 |
| --- | --- |
| `photoCandidates` | 通過品質與視角／時間條件的相機影格次數，含背壓重試，不等於獨立照片數 |
| `writerBackpressureFrames` | 合格但寫入名額已滿的影格次數 |
| `imageCopyFailures`, `savedPhotos`, `maximumPendingWrites` | 複製失敗、成功保存、同時待完成寫入峰值 |
| `writeQueueTotalMS`, `writeQueueMaxMS` | 從建立寫入任務到 writer 開始處理的等待時間 |
| `jpegTotalMS`, `jpegMaxMS` | 影像準備、可選降噪與 JPEG 編碼時間 |
| `fileWriteTotalMS`, `fileWriteMaxMS` | JPEG／深度／信心檔案及姿態紀錄寫入時間 |
| `savedIntervalTotalS`, `savedIntervalMaxS` | 成功照片按拍攝 timestamp 排序後的間隔總和／最大值；包含續掃中間停頓 |
| `configuredMinimumIntervalS`, `poseRefinementEnabled` | 本次最低快門間隔與姿態精修設定 |
| `featureWork` | 提交、完成、被新幀取代數，最大保留工作數，以及匹配工作總／最大耗時 |
| `retainedFeatureFrames`, `archivedFeatureObservations`, `discardedFeatureObservations` | 描述子幀數、歷史觀測數、超容量淘汰數 |
| `renderPacing`、`arFramePacing`（第 2 版） | 掃描期間，渲染執行緒的即時畫面幀，以及送到主執行緒的 ARKit 幀。各有 `frames`、`stalls`（間隔超過 50 ms）、`maximumIntervalMS`，以及 `framesByHundredPhotos`／`stallsByHundredPhotos`（索引 0 = 第 0–99 張，1 = 第 100–199 張…），可看出卡頓是否隨照片數增加 |
| `frameHandlingTotalMS`、`frameHandlingMaxMS`（第 2 版） | 掃描期間主執行緒處理每個 ARKit 幀的時間 |
| `seriousThermalS`（第 2 版） | 掃描期間溫度狀態為 serious 或 critical（iOS 會降速）的時間 |
| `anchorsAtStop`（第 2 版） | 停止時 session 內的 ARKit 錨點數（每張照片一個，加上預覽點雲磚） |

`preview-performance.json` 第 2 版增加 `extractionTotalMS`、`consistencyTotalMS`、`gridInsertTotalMS`、`maximumSampleStride`、`overBudgetFrames`。它們量測 CPU 工作，不是螢幕顯示 FPS。舊掃描沒有新欄位，也不會自動補算。

## 驗證與實機比較

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/CaptureWorkScheduling.swift tools/test_capture_work_scheduling.swift \
  -o /tmp/fable-scheduling-test
/tmp/fable-scheduling-test

swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{FeatureTracker,BundleAdjuster,PoseRefiner}.swift \
  tools/{test_stubs_core,test_feature_retention}.swift -o /tmp/fable-feature-retention-test
/tmp/fable-feature-retention-test

swiftc arkit-3dgs-scanner/Capture/Localization.swift arkit-3dgs-scanner/Capture/TrainingFrameSelector.swift -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Models,BlurFilter,FrameWriter,ExportManager}.swift \
  tools/test_capture_pipeline.swift -o /tmp/fable-capture-pipeline-test
/tmp/fable-capture-pipeline-test
```

排程測試刻意卡住第一個特徵工作，確認後續 99 次提交仍返回、只保留最新待處理工作、停止會排空、續掃與關閉互不污染；另驗證每次候選上限、起點輪替及時間回饋遲滯。特徵記憶體測試以十二張合成紋理影像驗證描述子淘汰後，舊 track、像素座標與深度仍可供 BA 使用，並檢查歷史上限與重設。寫入測試驗證有限分段計時及既有成功／失敗／重試行為。

排程測試另外確認：卡頓會算進正確的照片區間、暫停不算卡頓，以及相機標記合併成一組線段、尖端指向各自的拍攝方向（共 23 項）。先前通過 17 項排程／取樣、5 項特徵保留、5 項寫入／匯出及 39 項既有 LiDAR 一致性檢查；既有特徵索引回歸也通過，包含 28,000 次與暴力搜尋比對。iPhone 與 Simulator 未簽章 Debug 建置成功。既有 `RefusionEngine` 的 `UnsafeMutableBufferPointer` Sendable 警告仍存在。

真機需使用相同裝置、光線、路徑與建置模式，比較拍攝間隔中位數／P90、寫入背壓、特徵替換比例、融合平均／最大耗時與超預算比例。再比較同一實體平面的厚度和已知尺寸誤差；照片更密或候選點更多都不能單獨證明精度提高。此輪尚無更新後真機數據。
