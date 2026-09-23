# 相機姿態精修與照片對齊驗證

[English](POSE_REFINEMENT.md) | **繁體中文**

停止掃描後，手機會為匯出的 3DGS 資料集精修 ARKit 相機姿態。只有照片本身確認有改善時才會套用修正；驗證未通過就保留原姿態，所以精修不會讓訓練資料比 ARKit 原始結果更差。

## 流程

1. **ARKit 錨點**：每個關鍵幀放置一個 `ARAnchor`，停止時讀回 ARKit 地圖優化移動後的錨點。一份 569 幀重跑中，這一步修正了中位數 38 mm、最大 108 mm 的姿態，重訪位置的表面偏移由約 45 mm 降至 11 mm。此階段未變更。
2. **特徵階段**：已儲存照片與最近影格及四個路線錨點比對，接著執行帶 ARKit 運動先驗的聯合光束法平差（BA）與已驗證閉環（見下方）。
3. **局部表面階段**（僅開啟實驗性表面重建時）：中間影格對鄰近錨點做深度點到平面對齊，見[表面重建](SURFACE_RECONSTRUCTION.zh-TW.md)。
4. **照片對齊檢查**：決定套用哪個階段，或全部不套用。融合、預覽與 COLMAP 匯出都使用最終姿態。

## 照片對齊檢查

保留的特徵 track 與求解器共用同一套匹配與 LiDAR 深度，因此看不到求解器自己引入的誤差。重跑改版前的流程時，BA 通過了自己的保留集（5.78 → 5.42 px），但相鄰影格的照片反而對得更差。所以 `PhotometricPoseValidator` 直接量測 3DGS 訓練要最佳化的量：重疊影格之間的影像紋理是否一致。

- **影格對**：從「將被取代的姿態」挑選。最多 40 組相鄰對（間隔不到 1 秒）和 40 組寬基線對（相距 0.25–0.8 m、視線方向相近、間隔至少 1.5 秒）。只計算含有被候選結果移動之影格的對；兩張都沒被移動的對在兩組姿態下分數相同，只會稀釋結果。
- **取樣**：取來源影格 4 m 內、高可信度、不在深度邊界上的 LiDAR 像素，只保留紋理最強的 30%。每個樣本投影到目標影格的 960 px 灰階照片，且必須與目標深度相差在 max(3 cm, 1.5%) 以內。兩組姿態使用相同樣本，分數為正規化互相關（NCC）。
- **第一個階段的判定**：
  - 相鄰對 NCC 中位數最多下降 0.002。
  - NCC 下降超過 0.02 的相鄰對不得多於 15%。
  - 寬基線 NCC 中位數至少提高 0.003。
  - 兩類影格對各至少需要 8 組，否則不套用。
- **階段順序**：特徵階段對輸入姿態檢查。局部表面階段接著對已接受的特徵階段檢查，只要求「不造成傷害」（寬基線變化至少 −0.002）。特徵階段被拒絕時，建立在其上的局部階段也一併捨棄。

`pose-refinement.json` 第 5 版新增 `photometric`（各階段的影格對數、前後 NCC 中位數、中位變化、變差的相鄰對數、耗時）與 `appliedStage`。新增狀態 `photometricValidationRejected` 與 `photometricValidationInsufficient`，兩者都保留原相機位置並顯示在地化提示。仍可讀取舊版報告。

## 光束法平差

- **深度雜訊模型**：特徵的 LiDAR 深度殘差除以 σ(d) = 5 mm + 2.2 mm × d²，即 1 m 為 7 mm、2 m 為 14 mm、3 m 為 25 mm、4 m 為 40 mm，Huber 門檻為 2σ。舊版 fx/d 換算等於假設 2 m 處深度只有約 1.5 mm 誤差；重跑量到的 LiDAR 整幀偏移約 1 cm，會被每一幀沿視線吸收進姿態。
- **帶 ARKit 運動先驗的聯合求解**：所有可用影格依拍攝順序一起求解。
  - 間隔 0.5 秒內的相鄰關鍵幀，每一步保持 ARKit 相對運動在 0.3 mm 與 0.01° 以內。
  - 對輸入姿態的微弱拉力（5 cm、1°）固定全域座標。
  - 共 30 次 Gauss–Newton 迭代，每次都由 LiDAR 重新推導特徵點，並以 Levenberg–Marquardt 阻尼求解塊三對角系統；記憶體隨影格數線性成長。每一步修正上限為 5 cm 與 0.02 rad。
  - 特徵少的影格會隨鄰近影格一起移動，不會停在原位。超過 0.5 秒的間隔（例如追蹤中斷後）會切斷先驗鏈。
- **結構**：特徵點仍為 LiDAR 反投影的平均值，保持公制尺度。可用 `optimizeTracks` 改由重投影重新估計特徵點，但預設關閉：較鬆的先驗下它會吸收合成的沿視線位移（1.59 → 2.27 cm）；最終先驗下為 0.60 cm，LiDAR 平均值則為 0.55 cm；在實機掃描上也沒有帶來改善。
- **保留集門檻**：保留 track 門檻（−3%）與 15 cm / 5° 修正上限仍在照片對齊檢查之前生效。
- `BundleAdjuster.Options.legacy` 保留原本的逐幀求解器，供對照比較。

## 重跑證據

以下為桌機重跑兩份 iPhone 17 Pro 掃描，使用 App 預設設定（含局部表面階段）。NCC 變化為相對掃描已存姿態的中位數；沒有地面真值。

| | 7F2187（399 幀，近距） | 9F8040（569 幀，房間） |
| --- | --- | --- |
| 改版前流程：相鄰／寬基線 NCC 變化 | −0.0194（40 對中 20 對變差）／+0.0118 | −0.0315（40 對中 27 對變差）／−0.0030 |
| 改版前流程：照片對齊檢查 | 拒絕 | 拒絕 |
| 新流程：相鄰／寬基線 NCC 變化 | +0.0073（40 對中 4 對變差）／+0.0206 | +0.0021（40 對中 0 對變差）／+0.0231 |
| 新特徵階段保留 track | 5.78 → 4.36 px | 5.98 → 5.20 px |
| 局部表面階段對特徵階段 | 拒絕：相鄰 −0.067（20 對全部變差） | 拒絕：相鄰 −0.043（40 對中 29 對變差） |
| Mac 重跑耗時，改版前 → 新 | 7.8 → 10.6 秒 | 15.8 → 19.2 秒 |

- **參數掃描**（30 次迭代，僅特徵階段）：
  - 先驗為 1 mm / 0.05°（另加每步 1%）、0.5 mm / 0.02°、0.3 mm / 0.01°、0.1 mm / 0.003° 時，寬基線增益分別為 +0.016 / +0.019 / +0.021 / +0.014（7F2187），以及 +0.015 / +0.019 / +0.023 / +0.019（9F8040）。
  - 第一組先驗下，6 次迭代只有 +0.012 / +0.014。採用的先驗下，60 次迭代沒有比 30 次更好。
- **與預設輸出直接比較的選項**：全解析度次像素特徵位置（Förstner 精修，合成角點最大誤差 0.18 px）、改與 8 張最近影格及 8 個錨點比對，以及最佳化特徵點，寬基線 NCC 變化都小於 ±0.003；加長 track 還多花 50–60% 時間。三者維持關閉（`subpixelFeatures`、`recentMatchFrames`／`anchorFrames`、`optimizeTracks`）。

## 工具與測試

```sh
bash tools/test_pose_refinement.sh   # BA（19 項）、特徵索引／次像素（7 項）、照片對齊（8 項）
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  arkit-3dgs-scanner/Capture/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,TrainingFrameSelector,OfflinePoseRefinement,LocalSurfaceRefiner,LoopClosureRefiner,FeatureTracker,BundleAdjuster,PoseRefiner,PhotometricPoseValidator}.swift \
  tools/replay_pose_refinement.swift -o /tmp/replay_pose_refinement
/tmp/replay_pose_refinement refine SCAN OUT.jsonl [--no-surface] [--poses FILE]
/tmp/replay_pose_refinement compare SCAN INPUT.jsonl CANDIDATE.jsonl
```

重跑工具只讀取掃描資料，不會修改。環境變數 `BA_LEGACY`、`BA_JOINT`、`BA_TRACKS`、`BA_SUBPIXEL`、`BA_RECENT`、`BA_ANCHORS`、`BA_ITER`、`BA_PRIOR_T`、`BA_PRIOR_R_DEG`、`BA_PRIOR_FRACTION` 與 `BA_HOLDOUT=0` 可重現上述比較。

- BA 測試以 `.legacy` 保留原本的逐幀案例。
- 新增類似 ARKit 的平滑漂移案例：0.80 cm / 0.43° → 0.22 cm / 0.00°，相鄰運動誤差由 1.4 mm 降至 0.5 mm（逐幀求解器為 2.9 mm）。另有沿視線位移案例。
- 也涵蓋正確姿態、錯誤匹配、只有雜訊的保留集、塊三對角求解的稠密驗證，以及修正量往返換算。
- 每幀獨立 3 cm 跳動與 ARKit 的局部準確性相矛盾，依設計只會部分修正（2.94 → 2.46 cm）。

## 限制

- 證據僅來自兩份掃描。關鍵幀之間的 NCC 量測的是光度一致性，不是絕對精度。
- 沒有建模內參、鏡頭畸變與捲簾快門。
- 檢查需要有紋理且互相重疊的視角；過短或缺乏紋理的掃描會保留 ARKit 姿態。
- 尚未在 iPhone 量測增加的迭代與檢查所需的時間與記憶體。
- 兩次重跑中局部表面階段都被拒絕。之後可以改為只用於融合幾何，但它已不會在未通過檢查時改動訓練用姿態。
