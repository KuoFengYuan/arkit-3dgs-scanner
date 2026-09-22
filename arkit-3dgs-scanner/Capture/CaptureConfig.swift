//
//  CaptureConfig.swift
//  fable — COLMAP-free 3DGS capture
//

import Foundation
import CoreGraphics

/// 所有可調參數集中於此。門檻值以 iPhone Pro（LiDAR）室內拍攝為基準。
nonisolated struct CaptureConfig: Sendable {

    // MARK: - 無 LiDAR 的保守觀測驗證（需實機校準，非精度保證）
    var cameraOnlyFallbackDepthM: Float = 0.5
    var cameraOnlyMinBaselineM: Float = 0.04
    var cameraOnlyMinVisibleFeatures = 12
    var cameraOnlyMinFeatureCells = 3
    var sparseSampleIntervalS: Double = 0.2
    var sparseMinObservations = 3
    var sparseMinParallaxDeg: Float = 1.5
    var sparsePositionToleranceM: Float = 0.02
    var sparseRelativeTolerance: Float = 0.015
    var sparseTrackMaxGapS: Double = 2
    var sparseMaxCandidates = 20_000

    // MARK: - 停止後的純 RGB 多視角重建（不產生 LiDAR depth sidecar）
    var reconstructFromImages = true
    var rgbMaxImageDimension = 256
    var rgbMaxReferenceFrames = 24
    var rgbPixelStride = 5
    var rgbMinDepthM: Float = 0.25

    // MARK: - 智慧快門（基於位移 / 轉角，而非固定時間）
    /// 相對上一關鍵幀平移超過此距離（公尺）即觸發抓幀
    var keyframeTranslationM: Float = 0.05
    /// 或視角旋轉超過此角度（度）即觸發抓幀
    var keyframeRotationDeg: Float = 3.0
    /// 兩關鍵幀最小時間間隔，避免手震造成原地連拍
    var minKeyframeInterval: TimeInterval = 0.10
    /// Hard limits for rapid turns / fast travel, not ordinary walking. Exposure blur and
    /// measured sharpness remain separate gates; rolling-shutter risk is a warning/weight.
    var keyframeMaxAngularSpeedRadS: Float = 1.6
    var keyframeMaxLinearSpeedMS: Float = 1.6
    /// 背景寫入佇列上限（背壓）：滿載時跳過本幀，下一幀條件仍成立會再觸發
    var maxPendingWrites = 3

    // MARK: - 品質門檻（兩級制：警告 → 提醒但照拍；遮斷 → 暫停抓幀）
    /// 幾何劣化警告門檻（像素）：
    ///   blur ≈ (角速度 + 線速度/景深) × 焦距 × (曝光時間 ＋ 捲簾讀出時間)
    ///
    /// **門檻隨捲簾快門項一併重新校準過。** 加入讀出時間後，同樣的動作在明亮環境
    /// （曝光 1/120s）算出來的值是原本的 2.2 倍 —— 舊的 8/16 是以「只算曝光」校準的，
    /// 沿用會讓正常掃描一直跳紅字（實測回報過）。以 fx≈1450、總抹動時間 18.3ms 重算：
    ///
    ///   0.3 rad/s（17°/s，很慢的平移）→  8px
    ///   0.5 rad/s（29°/s，正常掃描）  → 13px
    ///   0.9 rad/s（52°/s，明顯轉身）  → 24px
    ///   1.0 rad/s（57°/s）            → 27px ← 實機回報那張糊掉的照片就在這一級
    ///
    /// 警告設 10、遮斷設 24（≈0.9 rad/s）。
    ///
    /// 警告值由**實機資料**決定而非推導：一次回報中位數 11.4px 的掃描，
    /// 清晰度閘門丟掉了 69% 的幀，而 HUD 全程沒有警告（當時警告線是 14）。
    /// 也就是說清晰度閘門實際的作用點在 ~11px，警告必須落在它**之前**，
    /// 否則使用者會在毫無提示的情況下流失大部分資料。
    /// 遮斷維持 24：那是「連姿態都不能信」的層級，與清晰度無關。
    var maxBlurPixels: Float = 10.0
    /// 曝光期間的估計模糊遮斷門檻；捲簾讀出風險另作提示及離線權重。
    var blockBlurPixels: Float = 24.0
    /// 關鍵幀的清晰度門檻：本幀清晰度 ÷「近 0.5s 內同場景的最佳清晰度」須達此比例。
    ///
    /// 為什麼需要它 —— blockBlurPixels 是**推估**（角速度 × 曝光時間），只涵蓋動態模糊，
    /// 對「失焦」完全盲目：手機靜止不動、對焦跑掉的畫面，推估值是 0，照樣被存成關鍵幀。
    /// 失焦與 AF 拉焦（重新啟用連續自動對焦後必然會發生）是「有些照片糊掉」的主因，
    /// 只有直接量影像才擋得住。
    ///
    /// 用相對值而非絕對值：清晰度與場景紋理量綁死（白牆對到極清晰也只有雜訊級的值），
    /// 絕對門檻在白牆上會全擋、在書架上會全過。
    /// 值由離線校準決定（tools/test_sharpness.py，粉紅雜訊合成場景 + 已知模糊核）：
    ///   真的該擋的：AF 拉焦（σ 8px）比值 0.03~0.27；單幀手震（σ 4px）0.05
    ///   不該擋的：平移過均勻紋理 1.00；1.5s 內從書架平移到白牆，最低 0.53
    /// 0.4 落在兩群中間 —— 對真模糊有 ~2.5× 餘裕，離自然變化的地板還有 ~1.3× 空間。
    /// （原本設 0.6，校準後發現它只對應 σ≈0.6px 的模糊，等於要求近乎完美清晰，過嚴。）
    var minSharpnessRatio: Float = 0.4
    /// CMOS 捲簾快門讀完整幀所需時間（秒）。這**不是**曝光時間，是逐列讀出的跨度：
    /// 這段時間內相機還在動 → 幀內上下兩端對應不同姿態 = 剪切變形，縮短曝光救不到。
    /// 少了這一項，明亮環境（AE 縮到 1/250s）的快速轉動會被系統性低估 3 倍以上。
    /// iPhone 主鏡 video 模式實測約 8~15ms，取 10ms。
    /// 想校準：拍直立的門框並水平快速平移，量畫面上下兩端的傾斜角 θ，
    /// 則 readout ≈ tan(θ) × 畫面寬 / (角速度 × fx)。
    var rollingShutterReadoutS: Double = 1.0 / 100
    /// 環境照度下限（lux，ARKit lightEstimate；1000 為標準室內）
    var minAmbientLux: CGFloat = 150
    /// 環境照度上限（正對強光 / 戶外直射易過曝）
    var maxAmbientLux: CGFloat = 20_000
    /// 目標距離下限（LiDAR 最近有效距離約 0.25m）
    var minTargetDistanceM: Float = 0.25
    /// 目標距離上限（LiDAR 有效範圍約 5m，遠了深度品質下降）
    var maxTargetDistanceM: Float = 4.0

    // MARK: - 影像 / 深度輸出
    /// JPEG 品質。0.90 在「有雜訊的輸入」上會讓 8×8 區塊的量化誤差變成塊狀色斑，
    /// 看起來比底下的感光元件雜訊還醜 —— 而 ARKit 影像本來就有雜訊（見下）。
    /// 感光雜訊是零均值的、多視角平均會消掉；JPEG 量化誤差是固定在該幀的系統性誤差，
    /// 對光度損失是實打實的偏差。攝影測量慣例是 ≥0.95，故調上來（120 幀約 48MB → 72MB）。
    ///
    /// 顆粒感的**主因不在這裡**：ARKit 的 capturedImage 是 video 幀，完全繞過 iOS 的
    /// 運算攝影堆疊（沒有 Deep Fusion / Smart HDR / 多幀降噪）。相機 App 的照片乾淨是因為
    /// 那是 ~9 幀融合的結果；單張 video 幀在室內 ISO 400~800 下就是這個樣子，
    /// Scaniverse / Polycam 也一樣。訓練前還會 area-average 降到 1600（雜訊再降 ~1.2×），
    /// 且 3DGS 對同一表面吃 10~30 個視角、雜訊以 √N 收斂 —— 最終成品比任一單張都乾淨得多。
    var jpegQuality: Double = 0.95
    var saveDepth = true
    /// 高 ISO 時對存檔影像做輕度降噪的門檻。低於此值不處理。
    ///
    /// **為什麼只在高 ISO 才做** —— 3DGS 對同一表面吃 10~30 個視角，感光雜訊是零均值的，
    /// 光度損失收斂到的就是多視角平均，雜訊本來就會以 √N 消掉。
    /// 也就是說：對訓練而言，逐幀降噪能拿掉的東西「平均」本來就會拿掉，
    /// 但降噪順手削掉的真實細節，平均**救不回來** —— 純以訓練論，降噪是負分。
    /// 它真正值得做的地方有兩個：(a) 匯出的照片是給人看的；
    /// (b) 雜訊會製造假梯度，讓 MRNF 的密集化把高斯浪費在雜訊上（floaters）。
    /// 所以策略是「只在雜訊真的壓過細節時才動手，而且下手要輕」。
    /// ISO 400 以下的 iPhone 主鏡雜訊遠低於 JPEG 量化誤差，動它沒有意義。
    var denoiseISOThreshold: Double = 400
    /// 降噪強度上限（CINoiseReduction 的 inputNoiseLevel；Apple 預設 0.02）。
    /// 由 ISO 在 [threshold, 4×threshold] 之間以 log 內插到此值，超過就封頂。
    /// 設 0 等於關閉降噪。
    var denoiseMaxNoiseLevel: Double = 0.022
    // 相機參數鎖定（曝光/白平衡；對焦維持連續自動）為使用者可切換選項，
    // 見 CaptureController.lockCameraParams（預設開啟）

    // MARK: - 點雲累積（3DGS 初始化 + 即時預覽共用）
    /// voxel 去重格距（公尺）。1cm 在物件距離 0.5–2m 下有 Scaniverse 級的表面密度
    var voxelSizeM: Float = 0.01
    /// 記憶體內點數上限：觸頂時 voxel 自動 ×2 粗化後繼續收（長掃描不會停止累積）
    var maxPoints = 600_000
    /// 匯出點數上限；同時限制手機重融合輸出、平面圖與打包的記憶體尖峰。
    /// 外部 3DGS 訓練可使用這些初始化點；原始深度保留供後續重處理。
    var exportMaxPoints = 250_000
    // 手機平面圖共用 exportMaxPoints 預算，避免另外配置 2M 點及下採樣字典。
    // 原始深度保留；需更高密度時可於桌機重融合覆寫 target。
    /// COLMAP 輸出對齊世界上方向：ARKit 為 +Y up，多數 3DGS 工具假設 -Y up，
    /// 直接匯入會上下顛倒。true = 繞世界 X 軸翻 180° 對齊 COLMAP 慣例（預設，修正顛倒）。
    /// 若你的 viewer 反而變顛倒，設為 false 即輸出 ARKit 原生 +Y up。
    var flipWorldUpForExport = true
    /// 掃描後重融合的深度取樣步長（1 = 全像素，多視角加權平均品質最佳）
    var refuseSampleStride = 1
    /// 重融合 voxel 尺寸：比即時預覽（1cm）略粗，把遠距深度雜訊造成的「厚牆」塌成薄面。
    /// 想要最高細節設 0.01；房間尺度 3DGS 初始化 2cm 已足夠且更乾淨。
    var refuseVoxelSizeM: Float = 0.02
    /// 併入 ARKit 場景重建網格（ARMeshAnchor）的頂點作為補充幾何。
    /// 價值不在「更準」，而在**覆蓋率**：ARKit 的 mesh 融合的是每一幀（60fps）的深度，
    /// 而重融合只用 ~120 個關鍵幀 → mesh 會涵蓋關鍵幀沒拍到的表面（天花板/角落黑塊的主因）。
    /// mesh 頂點只填補沒有實測深度的格子；同格取得 LiDAR 觀測後，以實測資料取代。
    var useSceneMesh = true
    /// Stop-time mesh is optional supplementary geometry; never copy an unbounded scene.
    var processingMeshMaxVertices = 150_000
    /// mesh 頂點的可見性容差（公尺）：投影到某關鍵幀後，與該幀深度圖差距在此範圍內才採用該幀顏色。
    /// 這只是取色上限；幾何仍須通過本幀與鄰幀的更嚴格深度一致性檢查。
    var meshColorDepthTolM: Float = 0.10
    /// 重融合格數的設定上限，獨立於即時預覽。
    /// 手機另受 refuseMemoryBudgetMB 與即時可用記憶體限制；觸頂時粗化並記錄於報告。
    var refuseMaxCells = 4_000_000
    /// iOS 額外限制融合字典工作集；照片更密時仍逐幀讀取，不隨照片總數配置。
    var refuseMemoryBudgetMB = 96
    /// 孤立點移除：占據 voxel 的 26 鄰域中占據數少於此值 → 視為飄浮雜點剔除（0 = 關閉）。
    /// 專清空間中不貼表面的白霧；過大會咬掉細線/薄物，3 為保守值。
    var refuseMinNeighbors = 3
    /// 只接受此信心等級以上的深度（ARConfidenceLevel：0=low, 1=medium, 2=high）。
    ///
    /// 從 2（只收 high）放寬到 1（收 medium）。medium 大多出現在物體邊緣、
    /// 深色表面與較遠處 —— 比較吵，但**不是錯的**，而且飛點過濾
    /// （depthEdgeRejectRatio）與孤立點移除本來就會擋掉真正的壞值。
    /// 實機 log 顯示 26.4% 的格子完全沒有 LiDAR 覆蓋、只靠 mesh 撐著；
    /// 在覆蓋率這麼吃緊的情況下，把可用但較吵的觀測整片丟掉並不划算 ——
    /// 收進來給低權重，讓多視角加權平均自己決定要不要相信它。
    var minDepthConfidence: UInt8 = 1
    /// medium 信心深度的分數倍率（high = 1.0）。
    /// 0.4 使得「一次 high 觀測」勝過「兩次 medium」，high 存在時由它主導；
    /// 只有在完全沒有 high 的格子，medium 才成為唯一來源 —— 那正是要補的洞。
    var mediumConfidenceWeight: Float = 0.4
    /// 深度圖取樣步長（256×192 下 stride 2 → 每次融合約 1.2 萬個候選點）
    var depthSampleStride = 2
    /// 點雲融合的深度有效範圍（LiDAR 超過 5m 雜訊明顯）
    var pointMinDepthM: Float = 0.15
    var pointMaxDepthM: Float = 5.0
    /// 飛點過濾：與相鄰像素深度差超過 depth×此比例 → 視為物體邊緣拖影，剔除
    var depthEdgeRejectRatio: Float = 0.05
    /// 跨影格深度一致性容差：2m 處為 2.5cm。不能靠 voxel 平均去除不同格中的重影。
    var depthAgreementAbsoluteM: Float = 0.015
    var depthAgreementRelative: Float = 0.005
    var depthConsistencyEnabled = true
    /// Offline fusion uses separated viewpoints and a bounded ray-depth consensus.
    /// Live preview retains its cheap single-frame temporal check.
    var depthDiverseReferences = true
    var depthConsensusEnabled = true
    var depthConsensusMaxShiftM: Float = 0.02
    /// 入射角上限（度）。超過就不收這個深度樣本。
    ///
    /// **這是牆面疊影的主要對策。** 掠射時一個深度像素涵蓋牆面上一大片，
    /// 深度沿光線的誤差被 1/cosθ 放大，點會落在真實表面前後好幾公分；
    /// 每一趟掃描各偏一點，就在 voxel 格上排成一片片平行的殼
    /// —— 那就是畫面上的垂直條紋與「掃多次疊在一起」。
    ///
    /// 80° 刻意留得寬：硬拒絕會在只能斜看到的牆面上開洞。
    /// 真正在做事的是 cos²θ 的權重（80° → 3%）—— 之後有正面觀測進來時，
    /// 加權平均會被拉回正確的表面，而不是留著兩層殼。
    /// 想更乾淨可以收到 70~75°，代價是斜面覆蓋率下降。
    var depthMaxIncidenceDeg: Float = 80
    /// 模糊權重曲線 w = (1/(1 + blurPx/half))^power，並以 refPx 那一點錨定尺度
    /// （所以改 power 只改「幀之間的相對輕重」，不整體平移權重大小）。
    ///
    /// **為什麼要能調 power** —— 實機資料顯示這條曲線太平，等於沒有在挑幀。
    /// scan_20260831_133615（2006 幀）：
    ///   estimatedBlurPx  p10 7.2 / p50 11.0 / p90 14.2 / max 15.1
    ///   w=1/(1+b/4)      p10 0.36 / p50 0.27 / p90 0.22 —— 中間 80% 只差 1.6×
    /// 也就是 2006 幀票票等值。若其中有一批位姿偏掉，它們就以幾乎全票的力道
    /// 把點寫進去，加權平均被拉成一條糊帶 —— 那正是 scan_accuracy.py 第 5 項
    /// 量到的「多層／糊開」而非兩層乾淨的殼。
    ///
    /// power 3 會把同一份資料的最好/最差比從 1.6× 拉到 4.2×。
    /// half 與 refPx 的預設值使 power=1 與先前的寫法**完全等價**（逐位元相同），
    /// 所以這組參數的預設不改變任何既有行為。
    var blurWeightHalfPx: Float = 4
    var blurWeightPower: Float = 1
    /// 錨點取 10px：那是 maxBlurPixels（警告線），也接近實機掃描的模糊中位數。
    var blurWeightRefPx: Float = 10

    // MARK: - 即時點雲預覽（AR 疊加，Scaniverse 式）
    /// 每 N 個 ARFrame 融合一次（60fps → 每 0.1s），與智慧快門解耦，點雲連續長出
    var previewFrameInterval = 6
    /// Preview work budget only; stored depth resolution and refusion sampling stay unchanged.
    var previewIntegrationBudgetMS: Double = 35
    var previewMaxCandidates = 6000
    var previewMaxSampleStride = 6
    /// 打包／主執行緒換幾何與融合解耦；每批有點數上限，避免大磚佔滿一個 frame。
    var previewRenderIntervalS: Double = 1.0 / 30
    var previewRenderPointBudget = 24_000
    /// 空間磚尺寸（公尺）：點雲按磚分塊渲染，每磚掛一個 ARAnchor ——
    /// ARKit 漂移修正 / 重定位時磚跟著移動，點雲不會與實體表面錯位（防殘影核心）
    var previewTileSizeM: Float = 1.2
    // 即時點雲與照片共用 CaptureQualityPolicy，避免清晰度／速度門檻分流。

    // MARK: - 平面圖（RoomPlan，與 3DGS 採集共用同一個 ARSession）
    /// 掃描時同步擷取 RoomPlan 平面圖，匯出時一併輸出 usdz / json / svg。
    ///
    /// 共生的前提我們本來就滿足（gravity 對齊、sceneDepth、mesh），所以「多掃一趟」的成本是零。
    /// 但**運算成本不是零** —— RoomPlan 會持續跑牆面偵測與物件分類。
    /// 本專案已經對散熱敏感（thermalState 到 .critical 會自動停拍），
    /// 長時間整屋掃描若發現提早過熱，這是第一個該關掉的開關。
    /// 只在支援 RoomPlan 的機型生效（見 FloorPlanCapture.isSupported）。
    ///
    /// **預設關閉。** 實機在辦公室隔間／貨架／桌面的場景下，RoomPlan 反覆給出
    /// 「2 面牆、樓高 0.80m」與方向亂掉的假牆 —— 它需要場景「是個房間」
    /// （有地板、成面的牆、牆與天花板的交界），而那個前提在這裡不成立。
    /// 平面圖改走 pointCloudFloorPlan：點雲只需要表面被掃到。
    ///
    /// 關掉會一併失去的東西（都是 RoomPlan 餵的，不是 bug）：
    ///   · 掃描時的即時發光線框與 dollhouse 縮圖
    ///   · 牆高不足 / 靠太近 / 光線不足的即時引導
    ///   · floorplan.usdz（帶門窗語意的 3D 幾何）
    ///   · 門窗與家具的語意分類
    /// 場景換成一般住宅／有完整牆面的房間時，把它設回 true 會明顯更好用。
    var captureFloorPlan = false

    /// 由 LiDAR 點雲直接產生平面圖（不經過 RoomPlan）。
    ///
    /// **與 captureFloorPlan 互相獨立，兩者可以同時開。** 它們的失效模式完全不同：
    ///   · RoomPlan 需要場景「是個房間」——有地板、成面的牆、牆與天花板的交界。
    ///     辦公室隔間、貨架、桌面前它會把螢幕邊桌緣硬判成牆，
    ///     而且第一片判錯之後後續的面會跟著它對齊。回報過 2 面牆、樓高 0.80m。
    ///   · 點雲只需要表面被掃到，但分不出門窗與家具語意（那要靠 RoomPlan）。
    ///
    /// 幾乎不花錢：重融合已經算好點雲了，這一步只是再掃一遍那些點
    /// （10 萬點約數十毫秒），而且只在匯出時做，不影響掃描。
    var pointCloudFloorPlan = true

    // MARK: - 局部 BA
    /// 基礎設定預設不執行 BA；CaptureController 在開拍時依使用者設定決定輪數。
    /// 啟用「精細掃描」且使用 LiDAR 時執行 6 輪；關閉或無 LiDAR 時為 0。
    /// 0 同時停用掃描中的特徵抽取／匹配與停止後的求解。
    /// 求解在背景執行，只有通過保留集驗證的結果才套用；未改善則保留 ARKit 姿態。
    var baRounds = 0

    /// 允許 BA 改動位姿。決定權不在這裡，在保留集（BundleAdjuster.kHoldoutGate）——
    /// 每次掃描各自判定，過門檻才套用。baRounds = 0 時本欄無作用。
    var baApplyPoses = true

    // MARK: - 迴環閉合（降低累積漂移，投報率最高的一項）
    /// 走多遠之後開始提示「回起點閉環」（公尺）。
    ///
    /// 為什麼需要提示：ARKit 只有在認出「我來過這裡」時才會做全域修正，
    /// 把累積誤差攤回整條軌跡。走一條開放路徑不回頭的話，誤差一路累積、
    /// 而且**不會有任何警告** —— 姿態看起來一樣正常，錯的是全域尺度與朝向。
    /// 房間尺度的 VIO 漂移約軌跡長度的 0.5~2%，走 10m 就是 5~20cm。
    var loopHintTravelM: Float = 8
    /// 回到起點多近算閉合（公尺）。ARKit 的重定位需要看到相似的視野，
    /// 1.5m 內大致就會觸發；太小會讓提示永遠不消失。
    var loopClosedRadiusM: Float = 1.5

}
