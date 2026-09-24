# LiDAR 重疊厚層：多視角深度共識

[English](LIDAR_SURFACE_CONSENSUS.md) | **繁體中文**

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

## 遠距深度的距離優先

多視角共識只會拿來源相機附近的視角互相比對。房間較大時，這些參考視角是從相近距離看同一面遠處表面，隨距離產生的誤差方向一致，會一起通過檢核。以桌機重跑兩份 iPhone 17 Pro 掃描：用 3 m 內實測深度擬合平面，再依距離比對每一幀的像素。約 2.5–3 m 以外，每幀的中位偏移達 1–5 cm（牆面量得較遠、地板或天花板量得較近），大於 2 cm voxel。逐 voxel 權重無法合併落在不同 voxel 的樣本：拿掉權重上限、加強距離權重、入射角改為 70° 或改用實驗性 TSDF，中位厚度的變化都在 5% 以內。

因此離線融合依相機座標深度，以 `fusionNearRangeM`（預設 3 m）分開處理實測深度：

- 近距範圍內的深度照原方式融合；沒有更遠深度的掃描，輸出點雲逐 bit 相同。
- 更遠的深度通過相同共識檢核後，寫入獨立的 key 空間，voxel 為融合 voxel 的 `fusionFarVoxelScale` 倍（預設 4 cm）。雜訊較大的遠距資料不再能吃滿格數預算，迫使近距表面一起粗化。
- 設定實驗選項 `surfaceCoverageProtection = true`（預設關閉）時，距離取代改在抽樣、TSDF 備援及可見性檢核之後執行。只有最終保留的近距實測表面，方向相容、且真正涵蓋遠距點投影的區域，才會在 `fusionFarExclusionM`（最多 15 cm）內取代遠距點。缺口、邊界、方向不同與獲得獨立觀測支持的平行表面仍保留。見[覆蓋保護](SCAN_FUSION_DIAGNOSTICS.zh-TW.md#覆蓋保護)。
- ARKit mesh 補洞、即時預覽與深度一致性門檻不變。實驗性 TSDF 只整合近距樣本；遠距補洞經既有 voxel 備援進入輸出。
- `refusion-progress.json` 第 7 版引入、第 10 版持續記錄 `nearRangeM`、`farExclusionM`、`farVoxelSizeM`、`farCells`、`farExcludedNearSurface` 與 `farExportedPoints`，仍可讀舊報告。設 `fusionNearRangeM = 0` 可回到單一距離融合。

下列表格是第 10 版覆蓋保護之前、原球形排除實作的歷史結果，不是目前演算法的測量。

| 桌機重跑（手機記憶體限制） | 原融合 | 距離優先 |
| --- | ---: | ---: |
| 9F8040（569 幀）：grid voxel／格數峰值 | 4 cm（已粗化）／785,576 | 2 cm／718,650 |
| 9F8040：局部 P10–P90 厚度中位數 | 7.71 cm | 3.67 cm |
| 9F8040：局部厚度第 90 百分位 | 12.24 cm | 9.46 cm |
| 7F2187（399 幀，近距）：厚度中位數 | 5.26 cm | 5.30 cm |

兩者都在原點雲的相同區域中心與法向量量測，方法同上；前一個表格取的是更舊預覽點雲的區域中心，所以那裡的 7.01 cm 不能直接和這裡的 7.71 cm 比較。9F8040 的 2,700 個可比較區域中 72% 變薄、9 個失去支持；原本被佔用的 10 cm 格有 81.8% 仍有點，俯視覆蓋保留 97.4%。消失的俯視範圍都在牆邊，那裡原本只有距近距牆面 4–12 cm 的遠距深度。139,745 個遠距格中，125,159 個因貼近近距表面而捨棄。因為 grid 不再粗化，輸出達 250,000 點上限，原本為 190,974 點。達上限時依字典順序抽樣，每次行程順序不同；兩次執行為 3.63–3.67 cm、保留 81.5–81.8%。近距掃描的變化在量測雜訊範圍內。

只從遠處看到的表面仍帶有遠距誤差；原球形排除可能刪掉近距覆蓋邊緣的遠距補洞，第 10 版提供可選的最終表面覆蓋檢查。實際重播局部厚度增加，尚待平面選區驗證，因此預設仍維持原排除方式。姿態錯誤的近距視角同樣會優先於遠距資料，這一步不會修正姿態。厚度包含家具與真實多層結構，不是絕對尺寸精度。

## 歷史時間代價（多視角共識）

在同一台 Mac、Release 編譯、569 幀、手機記憶體預算模式下，包含準備訓練輸出的工具執行時間，舊方法約 11.33 秒、新方法約 12.02 秒（單次對照約增加 6%）。一致性檢查本身約 2.07 → 3.00 秒；因此這次是品質改善，不能宣稱融合加速。兩次均無重跑相機 BA。這不是 iPhone 效能數字，實機耗時與溫度仍待驗證。

## 驗證與重現

- `tools/test_lidar_consistency.swift`：51 項，含平面收斂、2 cm 位移界線、RGB 射線保持、旋轉相機、遮擋、低可信度、參考選擇、mesh 防回填與記憶體壓力。
- `tools/test_large_scan_memory.swift`：24 項，含 1,000 張 256×192 深度影格、固定快取、輸出上限與取消。參考選取改為空間分散後，不再要求快取命中多於載入；仍驗證重用與每幀最多四次參考載入。
- `tools/test_history_training_export.swift`：14 項，完整 COLMAP 匯出與歷史資料相容。
- `tools/test_range_priority.swift`：13 項，含遠距 key 空間分離、粗化、近距表面排除、僅遠距表面補洞、v7 報告欄位、桌機匯出路徑，以及沒有遠距深度時逐 bit 相同。由 `tools/test_fusion_memory.sh` 與其他融合測試一起執行。
- `tools/test_surface_coverage.swift`：27 項，含預設關閉、精簡法向、缺口／邊界、跨階段細線保護、輸出預算與取消。
- 歷史 iPhone 與 Simulator Debug 建置通過；更新版實機效能仍待重新量測。

重跑工具只建立新資料夾；媒體採硬連結，跨磁碟時改複製。既有照片與深度視為不可變來源。`--legacy-depth` 重現舊的時間相鄰檢核與單一距離融合；`--no-range-priority` 保留目前的共識，只關閉距離分流。

```sh
swiftc arkit-3dgs-scanner/Capture/Localization.swift -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,ExportManager,TrainingFrameSelector}.swift \
  arkit-3dgs-scanner/History/ScanLibrary.swift tools/refuse_dataset.swift -o /tmp/refuse_dataset
/tmp/refuse_dataset SOURCE NEW_OUTPUT
/tmp/refuse_dataset SOURCE SINGLE_RANGE_OUTPUT --no-range-priority
/tmp/refuse_dataset SOURCE LEGACY_OUTPUT --legacy-depth
python tools/compare_surface_thickness.py LEGACY_OUTPUT/review.ply NEW_OUTPUT/review.ply REPORT_DIR
```

Python 比較工具需要 numpy、scipy、matplotlib。桌面工具僅用於重現與對照；手機中的融合本身不需要桌面端或網路。
