# LiDAR 重疊厚層：多視角深度共識

## 問題與修改

舊重融合只從時間相鄰的影格取最多四個參考；連拍間隔很短時，這些觀測的位置也很接近。原本只要支持數大於矛盾數就保留來源深度，容差內的偏差會繼續進入不同 voxel，留下厚層。

本次改動位於 `DepthSampleFilter.swift`、`RefusionEngine.swift` 與 `CaptureConfig.swift`，手機停止掃描及歷史「優化訓練資料」都使用相同實作：

- 優先挑選相距 6–40 cm、方向相近、時間至少差 0.25 秒的參考位置，偏好約 15 cm 基線，參考之間也盡量相隔 6 cm。最多四幀；不足才補時間相鄰觀測。
- 有兩張以上參考時，至少需要兩張支持，而且支持數必須大於自由空間矛盾數。只有一張可用參考的短掃描仍容許單張支持。不可見、被前景遮擋與低可信度不當作支持。
- 對通過檢核的深度，沿來源相機射線取多視角修正量的中位數，含來源零修正票；每個候選修正最多 2 cm。保留 RGB 像素對應，不作全域平面吸附。
- 修正後重新投影，支持數不可下降、矛盾數不可上升，否則保留原位置。深度邊界、低可信度與超出容差的表面不參與平均。
- mesh 補洞也必須滿足相同最低支持數，避免重新補回沒有多視角支持的厚層；mesh 自身不作射線位移。
- 共識排序重用小型暫存陣列，避免每個深度像素配置陣列。仍逐幀串流，LRU 深度快取上限 8 幀／2 MiB，輸出點數與 grid 記憶體保護保留。快取數字不代表整個 App 的 RSS；當前幀、四個參考及 grid 也需要記憶體。
- `refusion-progress.json` 版本 3 記錄 `diverseReferences`、`rayConsensus`；新增欄位為 optional，可讀舊報告。

`depthDiverseReferences`、`depthConsensusEnabled` 預設開啟；`depthConsensusMaxShiftM` 預設 0.02 m。即時預覽仍採既有單幀時序檢核，較完整的多視角處理發生在停止後，不增加掃描中每幀工作。

## 569 幀實際資料驗證

資料：`scan_20260921_113412_9F8040`。不重新估計相機位置，兩組使用相同已保存姿態、原始深度與手機工作集上限。資料未保存 ARKit mesh，因此本次重跑不含 mesh；mesh 防回填由合成測試驗證。

直接比較使用者原有 `review.ply` 與新輸出：

| 指標 | 原有結果 | 新融合 |
|---|---:|---:|
| 點數 | 240,214 | 190,974 |
| 局部表面 P10–P90 厚度的中位數 | 8.94 cm | 7.01 cm |
| 局部厚度的第 90 百分位 | 13.00 cm | 11.66 cm |

2,421 個可比局部區域中，93.7% 變薄；中位厚度減少約 21.6%。另有 2 個原本合格區域因新結果點數不足，無法計算。局部表面位置中位偏移量約 0.34 cm。

另外以舊演算法、同樣不含 mesh 的重跑作控制組：237,755 → 190,974 點，2,448 個可比區域厚度中位數 8.88 → 6.85 cm，減少約 22.9%。兩組 grid 都曾從 2 cm 粗化至 4 cm；改善不是單純改大 voxel 的結果。

方法：固定亂數種子，從基準點雲選最多 3,000 個中心，半徑 20 cm，PCA 排除線狀／非平面型區域；在**相同中心與基準法向**測量兩組點的 P10–P90 帶寬。不是把每個表面當成牆，也沒有假設牆面完全無誤差。厚度會包含真實家具、遮擋與兩層結構，不能視為絕對尺寸精度。

原始 10 cm 三維佔用格約 84.6% 在新結果仍有點，這是體積格重疊率，**不是表面涵蓋率**；變薄本身也會減少佔用格。不能僅憑點數減少或這個比例保證沒有缺口。

原資料相機精修報告的保留觀測誤差 5.76 → 5.95 px，未通過改善門檻，本次沒有強制套用。多視角深度共識只能改善有觀測支持的局部厚層，不能修復所有長距離姿態漂移或保證 3DGS 無殘影。

## 時間代價

在同一台 Mac、Release 編譯、569 幀、手機記憶體預算模式下，包含準備訓練輸出的工具執行時間，舊方法約 11.33 秒、新方法約 12.02 秒（單次對照約增加 6%）。一致性檢查本身約 2.07 → 3.00 秒；因此這次是品質改善，不能宣稱融合加速。兩次均無重跑相機 BA。這不是 iPhone 效能數字，實機耗時與溫度仍待驗證。

## 驗證與重現

- `tools/test_lidar_consistency.swift`：51 項，含平面收斂、2 cm 位移界線、RGB 射線保持、旋轉相機、遮擋、低可信度、參考選擇、mesh 防回填與記憶體壓力。
- `tools/test_large_scan_memory.swift`：24 項，含 1,000 張 256×192 深度影格、固定快取、輸出上限與取消。參考選取改為空間分散後，不再要求快取命中多於載入；仍驗證重用與每幀最多四次參考載入。
- `tools/test_history_training_export.swift`：14 項，完整 COLMAP 匯出與歷史資料相容。
- iPhone 與 Simulator Debug 建置通過；尚未在實機重新量測效能。

重跑工具只建立新資料夾；媒體採硬連結，跨磁碟時改複製。既有照片與深度視為不可變來源。

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  fable/Capture/{Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,ExportManager,TrainingFrameSelector}.swift \
  fable/History/ScanLibrary.swift tools/refuse_dataset.swift -o /tmp/refuse_dataset
/tmp/refuse_dataset SOURCE NEW_OUTPUT
/tmp/refuse_dataset SOURCE LEGACY_OUTPUT --legacy-depth
python tools/compare_surface_thickness.py LEGACY_OUTPUT/review.ply NEW_OUTPUT/review.ply REPORT_DIR
```

Python 比較工具需要 numpy、scipy、matplotlib。桌面工具僅用於重現與對照；手機中的融合本身不需要桌面端或網路。
