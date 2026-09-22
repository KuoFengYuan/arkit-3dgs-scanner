# ARKit 與無 LiDAR 掃描品質改進

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

`meta.json` 新增可選 `rgbReconstructionEnabled`（舊檔無此欄位仍可讀）。`rgb-reconstruction.json` 保存方法識別、可用影格數、嘗試／成功參考視角數、讀檔失敗數、接受觀測數、RGB 點數、含稀疏點的預覽總數、參考幀 ID、取樣設定及耗時。狀態包含 `insufficientViews`、`insufficientBaseline`、`noReliableMatches`、`reconstructed`。`decodedImages` 是解碼次數，重複用到同張照片也計入。報告會隨整份掃描一起封裝。

### 限制

這是低解析度、固定姿態、取樣式的手機端 MVS，沒有完整 SfM、全域 RGB BA、表面法線最佳化、逐像素深度圖或網格補洞。大場景在 24 個參考視角之外主要保留稀疏覆蓋。反光、白牆、快速動態、遮擋、強透視與錯誤相機姿態仍可能造成空缺或錯點；門檻通過不等於公分級精度保證。參考平面假設也會降低大斜面／大旋轉的接受率。手機端耗時、熱量和真實幾何精度尚待實機測試。

## 驗證

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  fable/Capture/Models.swift fable/Capture/BlurFilter.swift \
  fable/Capture/CaptureConfig.swift fable/Capture/Utils.swift \
  fable/Capture/SmartShutter.swift fable/Capture/DepthSampleFilter.swift \
  fable/Capture/CameraOnlyGeometry.swift fable/Capture/SparseLandmarkFilter.swift \
  tools/test_camera_only_accuracy.swift -o /tmp/fable-camera-only-test
/tmp/fable-camera-only-test
```

RGB 重建回歸指令：

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  fable/Capture/{Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,RGBStereoMatcher,RGBReconstructionEngine}.swift \
  tools/test_rgb_reconstruction.swift -o /tmp/fable-rgb-test
/tmp/fable-rgb-test
```

目前 RGB 重建 29 項、品質／快門 26 項與既有融合 18 項檢查通過。iPhone 與 iOS Simulator 未簽章 Debug 建置通過；建置仍有既有融合程式 UnsafeMutableBufferPointer 的 Sendable 警告。

RGB 測試直接渲染已知 1.5 m 的紋理平面，再給不同相機位移／轉角及亮度，驗證深度誤差與拒絕案例。包含斜面、純旋轉、白牆、單方向／雙方向重複紋理、第三視角遮擋與不一致、JPEG 壓縮與縮圖、磁碟影像方向、voxel 合併、稀疏覆蓋補充、計算預算、缺檔、內參尺寸不符、畸形姿態、模糊影格、重複影格及舊 metadata 相容性。

合成平面測試要求中位深度誤差 < 1.5 cm、P95 < 4 cm，斜面中位平面殘差 < 2.5 cm；這是理想、已知姿態場景的回歸門檻，不能推論真機精度。

26 項合成回歸檢查涵蓋投影座標／可見性、特徵分布、近側距離與平移模糊、重複 ID、無基線／足夠基線、漂移與過期觀測、epoch 隔離、容量、近距離快門、LiDAR 旋轉行為、姿態突跳及恢復。這些檢查驗證接收／拒絕行為，不是現場幾何精度測量。

真機比較時固定光線、相機設定及路徑，使用有紋理的平面與已知尺寸物件；分別測試側向掃描、原地旋轉、白牆、背景切換／重新定位。記錄接受幀數、點數、已知尺寸誤差與表面厚度，避免把更多點視為更準。尚未完成此輪真機 A/B 與 UI 操作驗證。

## API 依據

Apple 將 [rawFeaturePoints](https://developer.apple.com/documentation/arkit/arframe/rawfeaturepoints) 定義為追蹤使用的中間分析結果，且不保證跨影格的點數與排列穩定。[ARPointCloud.identifiers](https://developer.apple.com/documentation/arkit/arpointcloud/identifiers) 提供點的唯一識別碼；本實作依 ID 關聯觀測，不依陣列位置，對消失、更新與追蹤中斷採保守處理。

已知相機姿態可作為多視角重建的輸入，見 [COLMAP 官方 FAQ](https://colmap.github.io/faq.html#reconstruct-sparse-dense-model-from-known-camera-poses)。本實作是獨立的手機端保守區塊匹配器，未整合 COLMAP／PatchMatch。
