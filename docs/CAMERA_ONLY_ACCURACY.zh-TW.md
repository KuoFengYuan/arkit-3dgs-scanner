# ARKit 與無 LiDAR 掃描品質改進

[English](CAMERA_ONLY_ACCURACY.md) | **繁體中文**

## 問題與改動

原先無 LiDAR 路徑在深度缺席時省略平移模糊項，並每秒把整份 rawFeaturePoints 直接當成灰色點寫入 voxel。同一特徵的反覆估計會重複投票，初期不穩定位置也可能留下多個點；旋轉觸發快門則會累積缺少基線的影格。

現在以四層品質檢查改善：

1. `PoseContinuityGate` 檢查每幀姿態；位移超過 max(8 cm, 3 m/s × dt)、旋轉超過 max(15°, 4 rad/s × dt)，或影格間隔超過 0.25 秒便重新等待追蹤連續正常 0.6 秒。這是資料接收防護，不會修改 ARKit 內部姿態。
2. `CameraOnlyGeometry` 使用 ARKit／OpenGL 相機的 -Z 前方投影，拒絕背後、越界、距離無效與非有限特徵。主執行緒最多取樣 512 點；畫面中央至少 6 點時使用深度的近側四分位數。深度不足則按 0.5 m 估算平移模糊，避免將未知距離解讀為零模糊。估計不會顯示為 LiDAR 距離警告。
3. RGB 模式需至少 12 個可見取樣特徵、覆蓋 3×3 網格中的至少 3 格；近距離抓幀位移取 min(5 cm, max(4 cm, 估計深度 × 0.05))，旋轉觸發亦需 4 cm 平移。第一張仍在品質通過後建立基準。最短拍攝間隔為 0.10 秒；LiDAR 近距離可加密至至少 2 cm，兩種模式皆維持品質和寫入背壓。
4. `SparseLandmarkFilter` 每 0.2 秒觀測特徵 ID，至少 3 次、位置變化在 2 cm + 距離 × 1.5% 內、基線至少 4 cm、視差至少 1.5° 才收錄。隔超過 2 秒或位置突變會重新累積候選。追蹤中斷／突跳會變更 epoch，不混用之前的候選。同一 ID 融入一次，採用通過驗證時 ARKit 最新位置，不對不同時刻的估計反覆加權。

稀疏點在背景 actor 中投影並從自有相機影像副本取色，仍交由 ARAnchor 局部空間磚處理後續座標修正。候選上限 20,000 個；已收錄 ID 上限與 `maxPoints` 一致（目前 600,000），達上限後停止接納新 ID 但照片拍攝仍可繼續。過期候選清理限流，避免滿容量時每個新 ID 都掃過完整字典。

## 使用方式與取捨

關閉 LiDAR 後，對準有紋理的表面緩慢側向移動，避免只在原地轉手機。近距離需要更慢的平移，以免模糊超標。HUD 會提醒紋理不足與側向移動；RGB 不顯示依 LiDAR 重複觀測設計的融合熱圖／完成比例。

點數可能比舊版少，尤其白牆、反光表面、純旋轉及短掃描。若停止時沒有通過驗證的點，會提醒側向補拍，已保存照片仍可查看。門檻是初始保守值，集中於 `CaptureConfig`，尚未以真機資料校準。

以上即時稀疏點檢查本身不是獨立 RGB 特徵匹配／三角化，也不會新增 LiDAR 深度或啟用依賴深度的 BA。ARKit 特徵點的系統性誤差仍可能通過檢查；同 ID 僅收錄一次，也代表後續精細位置估計不會逐點取代已收錄資料，只套用空間磚錨點修正。停止後另執行以下獨立影像重建；它仍採固定 ARKit 姿態，無法消除系統性位姿誤差。

## 停止後純 RGB 多視角重建

### 操作與資料流

在開拍前關閉 LiDAR，「影像深度重建」預設開啟，可關閉來比較只用稀疏點的結果。此選項在開始掃描時固定，續掃沿用。停止後先完成錨點姿態校正與模糊複核，再以 `RGBReconstructionEngine` 在背景讀取照片。僅 `.keep` 影格可參與，`.drop` 和 `.demote` 都排除。

每批只保留三張小影像：一個參考視角與兩個來源視角。最多均勻選 24 個參考視角，來源仍可從完整清晰影格序列挑選；相機中心間距至少 4 cm，來源距參考不超過 30 cm，視線夾角約不超過 20°，優先選基線接近 12 cm 的來源。這是保守的姿態鄰近選擇，沒有全域影像檢索；找不到可靠重疊時該視角不產生點。

長邊縮到 256 px（不放大小圖），同步縮放內參，保持 sensor 原方向；檔案尺寸與內參不符就跳過。每 5 px 取一點，搜尋 0.25–5 m 的逆深度（亦受點雲深度範圍限制）。每對影像按極線跨度取 96–384 個候選，再局部細化，避免分配全幅密集代價體。過大的搜尋跨度直接拒絕。

### 每點的接受條件

1. 參考與來源 5×5 區塊亮度變異至少 0.0009，參考區塊需有兩個方向的紋理；只有條紋／單一邊緣不能約束匹配。
2. 依參考相機正面平面將區塊投影到來源，以零均值正規化互相關（ZNCC）評分。最佳 NCC 至少 0.88；與相隔超過 1.5 px 且深度不同超過 4% 的競爭匹配，代價至少差 0.06。搜尋端點與低視差（小於 1.5°）匹配不接受。
3. 兩個來源各自求得的深度需在 4% 內一致，融合深度投影至來源偏移不超過 0.8 px。
4. 兩個來源都需反向搜尋回參考圖，深度相差不超過 4%、重投影誤差不超過 0.8 px。遮擋、重複紋理和不同幀的不一致幾何因此較容易被排除。
5. 通過後按參考圖取色，以信心及距離加權融合至 voxel。RGB 表面附近一格內不混入稀疏估計，其他區域保留已驗證稀疏點；最終仍受 `exportMaxPoints` 限制。

影像重建結果直接進入 `review.ply`、既有歷史預覽、同步照片路線、COLMAP／PLY 匯出與 3DGS 初始化；不建立假 LiDAR 深度檔，不啟用依賴實測深度的 BA。刪除歷史仍刪除整個掃描資料夾，包含照片、模型及新增報告。

`capture-meta.json` 新增可選 `rgbReconstructionEnabled`（舊檔無此欄位仍可讀）。`rgb-reconstruction.json` 保存方法識別、可用影格數、嘗試／成功參考視角數、讀檔失敗數、接受觀測數、RGB 點數、含稀疏點的預覽總數、參考幀 ID、取樣設定及耗時。狀態包含 `insufficientViews`、`insufficientBaseline`、`noReliableMatches`、`reconstructed`。`decodedImages` 是解碼次數，重複用到同張照片也計入。報告會隨整份掃描一起封裝。

### 限制

這是低解析度、固定姿態、取樣式的手機端 MVS，沒有完整 SfM、全域 RGB BA、表面法線最佳化、逐像素深度圖或網格補洞。大場景在 24 個參考視角之外主要保留稀疏覆蓋。反光、白牆、快速動態、遮擋、強透視與錯誤相機姿態仍可能造成空缺或錯點；門檻通過不等於公分級精度保證。參考平面假設也會降低大斜面／大旋轉的接受率。手機端耗時、熱量和真實幾何精度尚待實機測試。

## 桌機以 LiDAR 為參考重播

### 目的

`tools/replay_camera_only.swift` 用真實 LiDAR 掃描量測相機模式（關閉 LiDAR）的結果。工具重播相機模式流程並忽略已存的深度，再以 LiDAR 資料作為參考。相機模式的姿態只有 ARKit 姿態加關鍵幀錨點回讀；沒有 LiDAR 時 `baRounds` 為 0，因此不執行離線 BA、迴圈閉合與照片對齊檢查。點雲來自固定姿態 MVS。`--candidate` 可接受任意姿態檔，之後的純 RGB 光束法平差（BA）也能用同一套方式評分。

1. **模擬拍攝。** 基準姿態（預設 `review-poses.jsonl`，即 ARKit + 錨點）依時間戳排序。某幀與上一個保留幀相距至少 `cameraOnlyMinBaselineM`（4 cm）且晚至少 0.10 s 才保留。接著移除深度欄位，並以候選姿態執行 `BlurFilter.annotate`，與 App 在 MVS 前的做法相同。`--all-frames` 會略過抽幀。
2. **姿態**在模擬後的影格上與參考比較。報告列出同一世界座標下的原始位置與旋轉差、以相機中心做最佳剛體對齊（Horn 四元數法）後的 ATE、Umeyama Sim(3) 尺度（大於 1 代表候選路徑較大），以及沿參考路徑 1 m 與 5 m 的相對姿態誤差（RPE）。
3. **照片對齊**使用 LiDAR 深度，與相機模式流程無關。`PhotometricPoseValidator` 在同一批有深度的影格上，比較相機模式姿態與參考姿態（以及候選姿態）。
4. **LiDAR 參考點雲。** 以參考姿態對全部影格執行預設融合濾波。容量提高到 2,000,000 點與 512 MB 工作集，避免手機的 250,000 點與 96 MB 上限讓參考點雲變粗。
5. **MVS**（`RGBReconstructionEngine`）在無深度影格上執行兩次：用參考姿態可單獨評估 MVS 品質，用候選姿態則量測端到端結果。兩次使用相同的模糊判定。
   - 準確度：每個 MVS 點到最近 LiDAR 點的距離，上限 10 cm。
   - 完整度：LiDAR 點中，2、5、10 cm 內有 MVS 點的比例。
   - 另外只計算該次實際產生點的參考視角「看得到」的 LiDAR 點。點必須落在深度圖內、相機深度介於 0.25–5 m，且與該幀 LiDAR 深度相差不超過 max(3 cm, 3%)。整體偏低而可見部分偏高，代表參考視角太少；兩者都偏低，代表每個視角產生的點太少。

參考姿態透過 `replay_pose_refinement` 取得，即 App 的 LiDAR BA 與照片對齊檢查；建置指令見[姿態精修](POSE_REFINEMENT.zh-TW.md)。

```sh
/tmp/replay_pose_refinement refine SCAN /tmp/ref.jsonl --no-surface
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,TrainingFrameSelector,PhotometricPoseValidator,RGBStereoMatcher,RGBReconstructionEngine}.swift \
  tools/camera_only_metrics.swift tools/replay_camera_only.swift -o /tmp/replay_camera_only
/tmp/replay_camera_only SCAN WORK_DIR --reference /tmp/ref.jsonl \
  [--baseline FILE] [--candidate FILE] [--all-frames] [--no-mvs] [--reference-voxel M]
```

工具只讀取掃描資料夾，不會修改。`WORK_DIR` 不能已存在，也必須位於掃描資料夾之外。輸出包含 `camera-only-replay.json`（報告版本 1，含耗時）、`reference.ply`、`mvs-reference-poses.ply`、`mvs-candidate-poses.ply` 與 `refusion-progress.json`。工作資料夾會暫時以硬連結指向掃描的照片與深度，結束時移除。`--no-mvs` 略過參考點雲與 MVS。`--reference-voxel` 是診斷用選項，只改變參考點雲的融合 voxel。

### 兩次 iPhone 17 Pro 掃描的量測結果

以下使用預設設定。參考姿態由 `replay_pose_refinement refine --no-surface` 產生，兩次掃描都通過其照片對齊檢查。相機模式姿態為 `review-poses.jsonl`（ARKit + 錨點；兩次掃描在此檔都沒有套用 BA 修正）。所有數值都是與 LiDAR 參考的差異，不是相對於真值的誤差。MVS 各列先列參考姿態、再列相機模式姿態，以「vs」分隔（每次只有一個數值時用「/」）。照片 NCC 為前 → 後的中位數，括號內是逐對變化的中位數。

| | 7F2187（近距離、快速移動） | 9F8040（房間尺度） |
| --- | --- | --- |
| 已存 → 模擬相機模式 → 可用於 MVS 的影格 | 399 → 277（46 s）→ 194（模糊複核排除 83） | 569 → 372（113 s）→ 261（降級 111） |
| 原始位置差 中位數／P95／最大 | 1.0／3.0／3.7 cm | 1.8／2.9／3.8 cm |
| 原始旋轉差 中位數／P95／最大 | 0.34／0.72／0.81° | 0.31／0.65／1.38° |
| 對齊後 ATE RMSE／中位數；對齊後旋轉中位數 | 1.3／0.8 cm；0.40° | 1.4／1.1 cm；0.38° |
| Sim(3) 尺度（相機模式／參考） | 1.0002 | 1.0027 |
| RPE 1 m：平移中位數／P90；旋轉中位數 | 1.2／2.4 cm（1.25／2.40%）；0.38° | 1.4／2.2 cm（1.41／2.19%）；0.37° |
| RPE 5 m：平移中位數／P90；旋轉中位數 | 1.8／3.3 cm（0.35／0.66%）；0.42° | 2.7／4.5 cm（0.54／0.89%）；0.49° |
| 照片 NCC，相機模式 → 參考姿態：相鄰；寬基線 | 0.964 → 0.978（+0.006）；0.848 → 0.895（+0.023） | 0.988 → 0.990（+0.003）；0.885 → 0.923（+0.021） |
| 這批影格的照片檢查結果 | 通過 | 未通過（80 對中 15 對樣本流失過多；上限 12 對） |
| LiDAR 參考點雲；點間距中位數 | 162,014 點；1.32 cm | 620,246 點；1.36 cm |
| MVS 點數；24 個參考視角中實際產生點者 | 1,129／995；23／22 | 218／216；21／22 |
| MVS 準確度 中位數／P90 | 1.25／4.44 cm vs 2.56／7.49 cm | 2.48／7.20 cm vs 3.10／≥10 cm（上限） |
| MVS 點在 2 cm 內；超過 10 cm | 70.3%、2.4% vs 40.8%、4.8% | 44.0%、4.6% vs 35.6%、11.6% |
| 完整度 2／5／10 cm，全部 LiDAR 點 | 1.7／11.6／26.8% vs 0.8／7.6／24.3% | 0.05／0.7／3.4% vs 0.04／0.6／2.9% |
| 完整度 2／5／10 cm，僅可見點 | 1.9／12.2／28.2% vs 0.9／8.2／26.0% | 0.05／0.7／3.4% vs 0.04／0.6／3.0% |
| 實際產生點的參考視角看得到的 LiDAR 點比例 | 91.5%／90.2% | 94.3%／95.1% |
| Mac 重播耗時（8 核心）：總計；融合；照片；每次 MVS | 約 7 s；2.4 s；1.7 s；0.9 s | 約 12 s；5.9 s；1.8 s；0.6 s |

**姿態。** 相機模式姿態與 LiDAR 參考的差異中位數為 1–2 cm，最大約 4 cm，旋轉中位數約 0.3°。每移動 1 m 的差異為 1.2–1.4 cm；5 m 內只有 1.8–2.7 cm，因此在這兩條 16–20 m 的路徑上，差異沒有隨距離穩定累積。兩次掃描改用參考姿態後照片對齊都變好，主要是寬基線影像對。9F8040 的中位數雖有改善，驗證器的樣本保留規則仍判定這批子集「未通過」；完整 569 幀的精修則通過該檢查。

**點雲。** 較大的差距在 MVS 密度：近距離約 1,000 點、房間尺度約 200 點，5 cm 內完整度最多只約 LiDAR 表面的 12%。實際產生點的參考視角看得到九成以上的表面，所以限制在於每個參考視角產生的點太少，而不是參考視角不夠。使用參考姿態時，MVS 點更貼近 LiDAR 表面（中位數 1.25 vs 2.56 cm、2.48 vs 3.10 cm），近距離時通過的匹配也較多（1,129 vs 995 點）。由此可見，姿態差異會降低準確度，近距離時也降低密度。準確度差距有一部分來自參考點雲本身就是用參考姿態建立的。

**`--all-frames`（7F2187）。** 改用全部 399 個已存影格（可用 280 個）而非模擬的 277 個，姿態差異幾乎不變（RPE 1 m 為 1.3 cm、ATE RMSE 1.3 cm）。使用參考姿態的 MVS 點數增加：1,601 點（原為 1,129），5 cm 完整度 14.8%（原為 11.6%）。使用相機模式姿態時仍為 1,003 點與 7.4%（原為 995 點與 7.6%）。準確度中位數大致不變（1.26 與 2.44 cm）。

**參考點間距。** 預設 2 cm 融合 voxel 讓 LiDAR 點間距中位數為 1.3 cm，與準確度數值相差不遠。改用 `--reference-voxel 0.01` 時，間距為 0.73 cm（7F2187，714,180 點）與 0.81 cm（9F8040，已達 2,000,000 點上限），準確度中位數降為 0.87 vs 2.25 cm（7F2187）與 2.21 vs 3.04 cm（9F8040），完整度變化不到 2 個百分點。因此 1 cm 等級的準確度差異，有一部分取決於參考點雲的密度，而不只是 MVS。

### 限制

- 這些掃描的 ARKit 追蹤是在開啟 LiDAR 下進行。Apple 未說明視覺慣性里程計是否使用 LiDAR，因此沒有 LiDAR 或關閉 LiDAR 的手機，漂移可能比這些姿態更大。
- 參考來自 App 的 LiDAR 流程（BA + 照片對齊檢查，再做深度融合），不是真值。
  - 參考 BA 以同一組 ARKit 姿態為初值並向其正則化，它觀測不到的誤差可能也不會出現在差異中。
  - 使用參考姿態的 MVS 是與同一組姿態建立的點雲比較，因此較占優勢。
- 即時的 ARKit 稀疏特徵點不會存檔，所以只評分 MVS 點。App 的預覽點雲在 RGB 表面以外還保留已驗證的稀疏點。
- 抽幀只是近似 RGB 快門（`SmartShutter` 的 `cameraOnly`）：沒有依深度調整的 4–5 cm 平移門檻、3° 旋轉觸發，也沒有特徵與姿態連續性檢查，而且只能從 LiDAR 快門已存的影格中挑選。模糊複核依據的 `estimatedBlurPx` 是用 LiDAR 深度計算的；即時相機模式則使用特徵深度或 0.5 m。
- 準確度採點對點距離，其中包含參考點間距（見上文）；完整度也取決於參考點密度。
- 候選點雲在其自身世界座標中評分，不做對齊；姿態則同時提供原始與對齊後的比較。若候選姿態的規範（gauge）整體移動，例如未固定的純 RGB BA，原始數值與 MVS 分數都會把這個位移算進去。
- 結果只涵蓋同一台裝置的兩次掃描。9F8040 只有約 200 個 MVS 點，統計相當粗略。

## 驗證

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,Utils,SmartShutter,DepthSampleFilter,RefusionEngine,SurfaceTSDF,CameraOnlyGeometry,SparseLandmarkFilter}.swift \
  tools/test_camera_only_accuracy.swift -o /tmp/fable-camera-only-test
/tmp/fable-camera-only-test
```

RGB 重建回歸指令：

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,RGBStereoMatcher,RGBReconstructionEngine}.swift \
  tools/test_rgb_reconstruction.swift -o /tmp/fable-rgb-test
/tmp/fable-rgb-test
```

LiDAR 參考重播的指標回歸：

```sh
bash tools/test_camera_only_replay.sh   # 重播指標 32 項，並建置重播工具
```

重播指標檢查涵蓋下列合成案例：
- 相同、剛體移動（30° 與 150°）、放大 2% 與每公尺漂移 1 cm 的軌跡。
- Jacobi 特徵值求解，以及雜湊網格搜尋與暴力搜尋的比對。
- 偏移 1 cm 的平面（準確度、半平面在 2／5／10 cm 的完整度、遮罩）、遠處離群點與點間距。
- 可見遮罩：可見、被遮擋、容差、超出影像、低信心與過近。
- 快門抽幀。

目前 RGB 重建 29 項、品質／快門 26 項與既有融合 18 項檢查通過。iPhone 與 iOS Simulator 未簽章 Debug 建置通過；建置仍有既有融合程式 UnsafeMutableBufferPointer 的 Sendable 警告。

RGB 測試直接渲染已知 1.5 m 的紋理平面，再給不同相機位移／轉角及亮度，驗證深度誤差與拒絕案例。包含斜面、純旋轉、白牆、單方向／雙方向重複紋理、第三視角遮擋與不一致、JPEG 壓縮與縮圖、磁碟影像方向、voxel 合併、稀疏覆蓋補充、計算預算、缺檔、內參尺寸不符、畸形姿態、模糊影格、重複影格及舊 metadata 相容性。

合成平面測試要求中位深度誤差 < 1.5 cm、P95 < 4 cm，斜面中位平面殘差 < 2.5 cm；這是理想、已知姿態場景的回歸門檻，不能推論真機精度。

26 項合成回歸檢查涵蓋投影座標／可見性、特徵分布、近側距離與平移模糊、重複 ID、無基線／足夠基線、漂移與過期觀測、epoch 隔離、容量、近距離快門、LiDAR 旋轉行為、姿態突跳及恢復。這些檢查驗證接收／拒絕行為，不是現場幾何精度測量。

真機比較時固定光線、相機設定及路徑，使用有紋理的平面與已知尺寸物件；分別測試側向掃描、原地旋轉、白牆、背景切換／重新定位。記錄接受幀數、點數、已知尺寸誤差與表面厚度，避免把更多點視為更準。尚未完成此輪真機 A/B 與 UI 操作驗證。

## API 依據

Apple 將 [rawFeaturePoints](https://developer.apple.com/documentation/arkit/arframe/rawfeaturepoints) 定義為追蹤使用的中間分析結果，且不保證跨影格的點數與排列穩定。[ARPointCloud.identifiers](https://developer.apple.com/documentation/arkit/arpointcloud/identifiers) 提供點的唯一識別碼；本實作依 ID 關聯觀測，不依陣列位置，對消失、更新與追蹤中斷採保守處理。

已知相機姿態可作為多視角重建的輸入，見 [COLMAP 官方 FAQ](https://colmap.github.io/faq.html#reconstruct-sparse-dense-model-from-known-camera-poses)。本實作是獨立的手機端保守區塊匹配器，未整合 COLMAP／PatchMatch。
