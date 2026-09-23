//
//  BundleAdjuster.swift
//  fable — 以 ARKit 位姿為初值的局部 BA（重投影誤差，非幾何對齊）
//
//  ── 為什麼是重投影誤差而不是幾何對齊 ──────────────────────────────
//  先前試過「把每幀深度對齊到融合點雲」（PoseRefiner + voxel 對應），
//  被離線測試否決：沿平面法向偏 3cm 時 0/40000 點有對應 ——
//  在最該修正的方向完全收不到訊號（見 tools/test_pose_refine.swift）。
//
//  重投影誤差沒有這個盲點：表面往鏡頭方向移動，投影位置就是實實在在地位移了。
//  而且它**就是**決定 3DGS 解析度天花板的那個量 ——
//  1cm 位姿誤差 @2m ≈ 7px 重投影誤差，高斯縮得比它小就會被各視角的矛盾懲罰。
//  幾何對齊只是它的代理指標。
//
//  ── 為什麼不需要 Ceres ────────────────────────────────────────
//  因為有 LiDAR，每個特徵的 3D 位置是直接讀出來的、不必三角化。
//  結構固定 ⇒ 各相機的位姿**彼此獨立**，正規方程從 (6N+3M)² 退化成每台相機一個 6×6。
//  6×6 的 Cholesky 手寫就好（PoseRefiner 已驗證），Schur complement 用不到。
//  代價是變成 coordinate descent（交替：修位姿 → 重算 track 3D → 再修位姿）
//  而非聯合解 —— 但 3D 有 LiDAR 錨定、不是自由變數，這個交替是收斂的。
//
//  ── 自我驗證 ─────────────────────────────────────────────────
//  每輪都量修正前後的重投影 RMS，沒下降就回退並停止。
//  但那是 BA 自己最小化的量 —— 見下方 kHoldoutEvery，還需要一個目標函數外的證人。
//
//  ── Joint solve (default) ─────────────────────────────────────
//  Real-scan replays showed the per-frame solve above makes adjacent photos line up worse:
//  each frame re-fits its own feature noise and LiDAR bias. The default now solves all frames
//  together with ARKit's frame-to-frame motion as a prior (block-tridiagonal normal equations)
//  and a range-dependent depth noise model; see Options and docs/POSE_REFINEMENT.md.
//  OfflinePoseRefinement additionally requires PhotometricPoseValidator to accept the result.
//  The per-frame path remains available as Options.legacy.
//

import Foundation
import simd

nonisolated enum BundleAdjuster {

    /// Huber 損失的轉折點（像素）。超過此殘差的觀測降權，擋掉誤匹配 ——
    /// 引導式搜尋已經過濾掉大部分，但磁磚/格紋這類自相似區域仍會漏一些。
    static let kHuberPx: Float = 2.0
    /// 單幀至少要這麼多觀測才求解（6 個未知數，實務上要遠多於此才穩）
    static let kMinObsPerFrame = 30
    /// 離群觀測的硬上限（像素）：超過就完全不採用。
    /// ARKit 位姿的殘差量級是十幾 px，超過 40px 幾乎確定是誤匹配。
    static let kMaxResidualPx: Float = 40
    /// 深度殘差自己的 Huber 轉折點（像素等效）。
    ///
    /// **不能與重投影共用 kHuberPx。** 深度殘差的雜訊來源是 LiDAR
    /// （σ≈1cm @2m ⇒ 約 7px 等效），而特徵定位雜訊只有 ~0.5px ——
    /// 用 2px 的門檻會把「3cm 的真實深度不一致」判成離群、權重壓到 9%，
    /// 於是深度項幾乎沒有作用（離線測試量到：沿光軸 3cm 的誤差只修回 30%）。
    /// 12px ≈ 1.7cm @2m ≈ 1.7σ，落在合理的 robust 門檻上。
    static let kDepthHuberPx: Float = 12

    /// 深度殘差的權重倍率（0 = 只用重投影）。
    ///
    /// 1.0 是實測掃出來的：1 / 3 / 8 / 20 對「沿光軸平移」的修正力幾乎相同
    /// （1.30 / 1.22 / 1.26 / 1.29 cm），但加大權重會讓一般情況變差
    /// （含雜訊案例 0.63 → 0.87cm）—— 因為深度雜訊(LiDAR σ≈1cm)被放大進來了。
    /// 也就是說那個方向的弱是**結構性的**、不是權重不夠，加權重只有壞處。
    ///
    /// **為什麼一定要有這一項** —— 純重投影對「沿光軸方向的平移」是弱觀測的：
    /// 把一個點沿著它的視線移動，投影位置幾乎不變。這是單目 SfM 的經典退化，
    /// 一般靠場景深度多樣性（近點遠點位移不同）勉強約束。
    /// 但我們有 LiDAR —— 直接比對「track 的 3D 位置投影到本幀的預測深度」與
    /// 「該像素實測的深度」，那個方向就被硬約束住了。
    ///
    /// 權重取 fx/d，讓 1 公尺的深度誤差換算成與重投影同尺度的像素數
    /// （d=2m、fx=1450 時 1cm 深度誤差 ≈ 7.25 px，正好與橫向誤差同量級）——
    /// 兩種殘差因此可以直接相加，不必另外調係數。
    static let kDepthWeight: Float = 1.0
    // kDepthHuberPx / the fx/d weighting above apply to Options.legacy; the default divides depth
    // errors by Options.depthSigma(d) instead.

    /// 交叉驗證：每 N 條 track 抽 1 條**完全不參與求解**，只用來當目標函數外的證人。
    ///
    /// **為什麼非有不可。** 上面那些自我驗證量的都是 BA 自己在最小化的量 ——
    /// 它下降是必然的，下降本身不代表位姿變好，也可能只是把觀測雜訊吸進位姿裡。
    /// 實機的修正量（中位數 1.0cm）與觀測雜訊（重投影中位數 7.7px ≈ 1.1cm、
    /// 深度殘差 3.1cm）同量級，這正是最該懷疑過擬合的情形，
    /// 而我先前每一輪的判斷都只看了求解內的數字，等於一直在問被告他自己有沒有罪。
    ///
    /// 保留集的殘差不在目標函數裡：
    ///   下降 ⇒ 位姿真的變好（雜訊不會跨 track 相關，只有真實位姿誤差會）
    ///   持平/上升 ⇒ 在擬合雜訊，BA 沒有淨效益 → baRounds 設 0
    ///
    /// 以 **track**（不是單一觀測）為單位保留：track 的 3D 位置是各幀反投影的平均，
    /// 只留一個觀測的話該點仍被求解用到，等於資訊洩漏、保留集會假性變好。
    ///
    /// 這是量測用的鷹架 —— 判定出來之後，要嘛整個 BA 拿掉、要嘛把保留集拿掉用回 100%
    /// 觀測。留著 20% 不用是暫時的代價（每幀仍有 ~84 個觀測解 6 個未知數，遠超需求）。
    static let kHoldoutEvery = 5

    /// 保留集要進步多少，BA 的位姿才會被套用（負值＝進步）。
    ///
    /// **這是每次掃描各自判定的，不是一個我猜的全域預設值。** 兩份實機 log 給出相反
    /// 的結論，而它們並不矛盾 —— 差別是工作距離。1cm 位姿誤差造成的重投影誤差
    /// @0.5m 是 29px，@2m 只有 7px：
    ///
    ///   · 近距離（小物件、牆角）：位姿誤差 ≫ 觀測雜訊 → BA 有充足訊號（實測 -21%）
    ///   · 房間尺度 2~3m：與深度取樣雜訊同量級 → BA 只是把雜訊擬合得更好
    ///
    /// 這是幾何決定的、不是可調參數。而保留集每次掃描都算得出來，就讓它自己決定；
    /// 我挑任何一個固定預設值，都會在另一半的情況下挑錯。
    ///
    /// 3% 的來源：離線測試「位姿已是真值、只有雜訊」那一案量到 +11%（往壞的方向），
    /// 而「真有位姿誤差」那一案是 -96%。兩者相距極遠，門檻設在哪都不敏感 ——
    /// 取 3% 是為了擋住量測本身的抖動，不是為了切在兩群之間。
    static let kHoldoutGate: Double = -0.03

    struct Options: Sendable {
        /// Feature depth residuals use sigma(d) = base + perSquareMeter × d², in meters.
        /// Replays measured frame-level LiDAR offsets near 1 cm up close and several cm beyond
        /// 3 m. The legacy fx/d scaling treated depth as ~1.5 mm accurate at 2 m, so every frame
        /// absorbed its own depth bias along the view ray and adjacent photos lined up worse.
        var legacyDepthWeighting = false
        var depthSigmaBaseM: Float = 0.005
        var depthSigmaPerSquareMeter: Float = 0.0022
        /// Huber threshold for normalized depth residuals (in sigmas).
        var depthHuber: Float = 2
        /// Joint solve over all frames with ARKit's relative motion between consecutive keyframes
        /// as a prior. ARKit is locally accurate (adjacent-photo NCC ~0.98-0.99), so refinement
        /// should move neighbouring frames together instead of re-fitting each frame alone.
        /// Real-scan replays peaked at 0.3 mm / 0.01° per step (looser 1-2 mm / 0.05-0.1° and
        /// tighter 0.1 mm / 0.003° both aligned wide-baseline photos less well).
        var jointSolve = true
        var priorTranslationM: Float = 0.0003
        var priorRotationRad: Float = 0.01 * .pi / 180
        /// Optional allowance growing with the step: sigma += fraction × |translation or angle|.
        var priorMotionFraction: Float = 0
        var priorMaxGapS: Double = 0.5
        /// Gauss-Newton iterations of the joint solve. Structure is re-derived from LiDAR each
        /// iteration, so low-frequency drift needs more than the per-frame solver's six rounds.
        var jointIterations = 30
        /// Weak pull toward the input poses; also fixes the global gauge of the joint system.
        var anchorTranslationM: Float = 0.05
        var anchorRotationRad: Float = 1 * .pi / 180
        /// Re-estimate each track point from reprojection plus the depth prior instead of the plain
        /// mean of LiDAR back-projections. Off: with the realistic (weaker) depth prior, optimised
        /// points can follow scale-like pose errors (a synthetic along-ray shift worsened under a
        /// looser motion prior), LiDAR-mean points keep structure metric, and real replays showed
        /// no gain.
        var optimizeTracks = false
        /// Held-out feature tracks must improve by this fraction (negative = better); nil skips it
        /// for diagnostics only.
        var holdoutGate: Double? = BundleAdjuster.kHoldoutGate
        /// Offline track building (OfflinePoseRefinement): descriptor frames matched besides fixed
        /// route anchors, the anchor count, and full-resolution sub-pixel feature positions.
        var recentMatchFrames = 4          // FeatureParams.matchAgainstRecent
        var anchorFrames = 4
        var subpixelFeatures = false
        init() {}

        /// Earlier per-frame solver with fx/d depth weighting, kept for A/B replays and its tests.
        static var legacy: Options {
            var options = Options()
            options.legacyDepthWeighting = true
            options.jointSolve = false
            options.optimizeTracks = false
            return options
        }

        @inline(__always)
        func depthSigma(_ depth: Float) -> Float { depthSigmaBaseM + depthSigmaPerSquareMeter * depth * depth }

        /// Scale converting a depth error in meters into residual units, and its Huber threshold.
        @inline(__always)
        func depthScale(observed: Float, predicted: Float, fx: Float) -> (scale: Float, huber: Float) {
            legacyDepthWeighting ? ((fx / predicted) * kDepthWeight, kDepthHuberPx) : (1 / depthSigma(observed), depthHuber)
        }
    }

    /// 觀測深度的中位數 —— 像素 ↔ 公分的換算尺度。用中位數而非平均，
    /// 因為深度分佈長尾（遠處的牆會把平均拉走）。
    static func medianDepth(_ obs: [FeatureObservation]) -> Float {
        guard !obs.isEmpty else { return 2 }
        var d = obs.map(\.depth)
        d.sort()
        return d[d.count / 2]
    }

    /// 執行局部 BA。回傳修正後的位姿與每輪的重投影 RMS（像素）。
    ///
    /// - records: 關鍵幀（transform 為初值，來自 ARKit＋錨點修正）
    /// - observations: 掃描時同步建立的跨幀對應（見 FeatureTracker）
    static func refine(records: [FrameRecord], observations: [FeatureObservation],
                       rounds: Int, options: Options = Options(),
                       isCancelled: () -> Bool = { false }) -> PoseRefineResult {
        var result = PoseRefineResult()
        guard rounds > 0, !observations.isEmpty, !isCancelled() else {
            result.rejectionReason = isCancelled() ? "cancelled" : "noObservations"
            return result
        }

        // 逐幀索引：id → (內參, 當前 c2w, 該幀的觀測)
        var order: [Int] = []
        var poses: [Int: simd_float4x4] = [:]
        var intr: [Int: CameraIntrinsics] = [:]
        var obsByFrame: [Int: [FeatureObservation]] = [:]
        var times: [Int: Double] = [:]
        for r in records where r.blurVerdict != .drop && r.transform.count == 16 && r.transform.allSatisfy(\.isFinite) {
            poses[r.id] = RefusionEngine.float4x4(rowMajor: r.transform)
            intr[r.id] = r.intrinsics
            times[r.id] = r.timestamp
            order.append(r.id)
        }
        // Every usable frame, in capture order: the joint solve moves frames with few features
        // together with their neighbours instead of leaving them at the old pose.
        let chain = order.sorted { (times[$0] ?? 0, $0) < (times[$1] ?? 0, $1) }
        let initialPoses = poses
        // 保留集：以 track 為單位切出來，完全不進求解（見 kHoldoutEvery）
        var heldByFrame: [Int: [FeatureObservation]] = [:]
        var heldTracks = Set<Int>()
        for o in observations where poses[o.frameID] != nil {
            if o.trackID % kHoldoutEvery == kHoldoutEvery - 1 {
                heldByFrame[o.frameID, default: []].append(o)
                heldTracks.insert(o.trackID)
            } else {
                obsByFrame[o.frameID, default: []].append(o)
            }
        }
        // 只留觀測足夠的幀（用求解集判定 —— 解不動的幀不該進迴圈）
        let framesBefore = order.count
        order = order.filter { (obsByFrame[$0]?.count ?? 0) >= kMinObsPerFrame }
        guard order.count >= 3 else {
            result.rejectionReason = "insufficientTrackSupport"
            // 不要靜默返回 —— 「完全沒有輸出」看起來像功能沒做，而不是條件不足
            print("BA: 略過 —— \(framesBefore) 幀中只有 \(order.count) 幀的觀測數達 "
                  + "\(kMinObsPerFrame)（共 \(observations.count) 個觀測）。"
                  + "特徵匹配產出率不足，原因見上方「匹配」分解")
            return result
        }

        /// 保留集的重投影殘差。只看重投影、不含深度項 —— 深度殘差被 LiDAR 雜訊主導，
        /// 混進來會蓋掉我們要偵測的那個訊號（位姿有沒有真的變好）。
        func heldOutReproj(_ p: [Int: simd_float4x4]) -> (rms: Float, median: Float)? {
            guard heldTracks.count >= 20 else { return nil }   // 太少 → 中位數沒有意義
            let pts = trackPointsFor(p, order: order, intr: intr, obsByFrame: heldByFrame)
            let r = residuals(order: order, poses: p, intr: intr,
                              obsByFrame: heldByFrame, points: pts)
            return r.reproj.isFinite ? (r.reproj, r.medianReproj) : nil
        }

        /// 跑迭代迴圈。**抽成函式是為了讓「量測解」與「上線解」走完全同一條路徑** ——
        /// 兩份實作一定會分岔，而這個檔案已經有四個概念錯誤的前例，
        /// 而且那些錯誤的症狀全是「沒效果」而不是「壞掉」。
        func runRounds(fit: [Int: [FeatureObservation]], from start: [Int: simd_float4x4])
            -> (poses: [Int: simd_float4x4], residuals: [Float], rounds: Int) {
            if options.jointSolve {
                return jointRounds(chain: chain, initial: initialPoses, start: start, times: times, intr: intr,
                                   fit: fit, rounds: max(rounds, options.jointIterations), options: options,
                                   isCancelled: isCancelled)
            }
            func points(_ p: [Int: simd_float4x4]) -> [Int: SIMD3<Float>] {
                options.optimizeTracks
                    ? optimizedTrackPoints(p, frames: order, intr: intr, obsByFrame: fit, options: options)
                    : trackPointsFor(p, order: order, intr: intr, obsByFrame: fit)
            }
            var poses = start
            var best = start
            var res: [Float] = []
            var applied = 0
            for _ in 0..<rounds {
                if isCancelled() { break }
                let pts = points(poses)
                let rBefore = residuals(order: order, poses: poses, intr: intr,
                                        obsByFrame: fit, points: pts, options: options)
                if res.isEmpty { res.append(rBefore.total) }

                // 逐幀獨立求解（結構固定 ⇒ 相機之間解耦）
                var deltas: [Int: simd_float4x4] = [:]
                for id in order {
                    if isCancelled() { break }
                    guard let c2w = poses[id], let K = intr[id], let obs = fit[id] else { continue }
                    if let d = solveFrame(c2w: c2w, K: K, obs: obs, points: pts, options: options) {
                        deltas[id] = d
                    }
                }
                guard !deltas.isEmpty else { break }

                // 全域剛體自由度：所有相機一起平移不改變任何重投影殘差 ——
                // 不扣掉平均修正量的話整組位姿會慢慢漂走，
                // 而點雲/ARWorldMap/上一次掃描的座標系就對不上了。
                PoseRefiner.removeGlobalDrift(&deltas)

                var candidate = poses
                for (id, d) in deltas { if let c = candidate[id] { candidate[id] = d * c } }
                let rAfter = residuals(order: order, poses: candidate, intr: intr,
                                       obsByFrame: fit, points: points(candidate), options: options)
                // 自我驗證用 **robust 成本**（＝求解實際最小化的量），不用原始 RMS。
                // 原始 RMS 被少數誤匹配主導：一輪可能把 inlier 改善很多、RMS 卻沒降，
                // 於是被誤判為「沒變好」而提早停止（實機 BA 卡在 8% 改善的成因）。
                guard rAfter.robust < rBefore.robust else { break }

                poses = candidate
                best = candidate
                res.append(rAfter.total)
                applied += 1
            }
            return (best, res, applied)
        }

        // ── 第一階段：只用 80% 求解，量保留集。這是閘門，不是最終解 ──
        let heldBefore = heldOutReproj(poses)      // 以 ARKit 原始位姿量
        let gate = runRounds(fit: obsByFrame, from: poses)
        result.roundsApplied = gate.rounds
        result.residualsPx = gate.residuals
        guard gate.rounds > 0 else { result.rejectionReason = "noImprovement"; return result }
        if let hb = heldBefore, let ha = heldOutReproj(gate.poses) {
            result.holdoutMedianPx = (hb.median, ha.median)
        }

        // ── 閘門：保留集有進步才交出位姿 ──
        //
        // **為什麼是每次掃描各自判定，而不是一個全域預設值。** 兩份實機 log 給出
        // 相反的結論，而它們並不矛盾 —— 差別是工作距離：
        //   1cm 位姿誤差造成的重投影誤差 @0.5m 是 29px、@2m 只有 7px。
        // 近距離掃描（小物件、牆角）位姿誤差遠大於觀測雜訊 → BA 有充足訊號（實測 -21%）；
        // 房間尺度 2~3m 則與深度取樣雜訊同量級 → BA 只是把雜訊擬合得更好。
        // 這是幾何決定的，不是可以調的參數；而保留集每次掃描都算得出來，
        // 就讓它自己決定。我猜一個預設值只會在另一半的情況下猜錯。
        let pass = options.holdoutGate.map { (result.holdoutDelta ?? 0) < $0 } ?? true
        if pass && !isCancelled() {
            // Apply the exact solution evaluated on untouched tracks. Re-fitting on the held-out
            // tracks would produce a different, unvalidated solution and invalidate this gate.
            result.poses = gate.poses
        } else {
            result.rejectionReason = isCancelled() ? "cancelled" :
                (result.holdoutMedianPx == nil ? "insufficientHoldoutTracks" : "holdoutDidNotImprove")
        }

        if let a = result.residualsPx.first, let b = result.residualsPx.last {
            // 位姿解讀只能用**重投影項**：深度項被 LiDAR 雜訊主導，
            // 把它算進去會把量測雜訊當成位姿誤差
            let rEnd = residuals(order: order, poses: gate.poses, intr: intr,
                                 obsByFrame: obsByFrame,
                                 points: trackPointsFor(gate.poses, order: order,
                                                        intr: intr, obsByFrame: obsByFrame),
                                 options: options)
            // **像素 → 公分要用這次掃描的實際工作距離。**
            //
            // 先前硬寫 d=2m。那在房間尺度還算合理，但這個專案也會拿來掃小物件 ——
            // 實機出現過外接盒只有 0.42×0.78m 的掃描，硬寫 2m 讓每個 cm 數字
            // 膨脹約 4 倍（重投影 5.54px 報成 0.76cm，實際約 0.19cm）。
            // 我已經被誤導的診斷數字坑過三次，而每一次都是因為「換算用了假設值」。
            let dMed = medianDepth(observations)
            let toCm = { (px: Float) in Double(px) * Double(dMed) / 1450 * 100 }
            print(String(format: "BA: %d 幀 / %d 觀測 / %d tracks × %d 輪 → "
                         + "總 RMS %.2f → %.2f px（改善 %.0f%%），工作距離中位數 %.2f m",
                         order.count, observations.count,
                         Set(observations.map(\.trackID)).count, result.roundsApplied,
                         a, b, (1 - b / a) * 100, dMed))
            // 中位數才是「典型」誤差：RMS 只擋 40px 硬上限，少數 30px 的誤匹配就能主導它。
            // 位姿解讀要看中位數；RMS 與中位數的差距則代表誤匹配的比重。
            print(String(format: "  重投影 RMS %.2f px / 中位數 %.2f px"
                         + "（以中位深度換算 %.2f cm；僅為投影殘差尺度，非絕對精度）",
                         rEnd.reproj, rEnd.medianReproj, toCm(rEnd.medianReproj)))
            print(String(format: "  深度殘差 %.2f px（≈ %.2f cm，屬 LiDAR 量測雜訊，非位姿誤差）"
                         + "，佔目標函數平方成本 %.0f%%",
                         rEnd.depth, toCm(rEnd.depth),
                         Double(rEnd.depth * rEnd.depth)
                             / Double(rEnd.total * rEnd.total) * 100))
            // 目標函數外的證人。上面每一個數字都是 BA 自己在最小化的量，下降是必然的；
            // 只有這一行能分辨「位姿真的變好」與「把雜訊吸進位姿」——
            // 而它同時就是「這次掃描的位姿要不要換成 BA 解」的閘門。
            if let d = result.holdoutDelta, let h = result.holdoutMedianPx {
                print(String(format: "  保留集（%d 條 track 未參與求解）重投影中位數 "
                             + "%.2f → %.2f px（%+.0f%%）：%@",
                             heldTracks.count, h.before, h.after, d * 100,
                             pass ? "保留集改善 → 套用已驗證的解"
                                  : "未達 \(Int(-kHoldoutGate * 100))% 門檻 ⇒ "
                                    + "在擬合觀測雜訊，本次不套用 BA 位姿"))
            } else {
                print("  ⚠️ 保留集不足（\(heldTracks.count) 條 track）無法判定 → 本次不套用 BA 位姿")
            }
        }
        return result
    }

    // MARK: - 單幀求解

    /// 對一幀解出位姿的小修正量。
    ///
    /// 參數化：c2w_new = ΔT · c2w_old，ΔT 以「繞相機中心的小角度旋轉 ＋ 平移」表示
    /// —— 與 PoseRefiner 一致，避免旋轉/平移在世界原點嚴重耦合。
    ///
    /// 相機座標下 Pc(x) = Pc + [Pc]×ω − t（x = (ω, t) 為世界座標的修正量，
    /// 經 R_w2c 轉到相機座標後的等效量），投影 Jacobian：
    ///
    ///     u = cx + X·fx/d,  v = cy − Y·fy/d,  d = −Z
    ///     ∂u/∂(X,Y,Z) = (−fx/Z,  0,      X·fx/Z²)
    ///     ∂v/∂(X,Y,Z) = ( 0,     fy/Z,  −Y·fy/Z²)
    static func solveFrame(c2w: simd_float4x4, K: CameraIntrinsics,
                           obs: [FeatureObservation],
                           points: [Int: SIMD3<Float>], options: Options = Options()) -> simd_float4x4? {
        let w2c = c2w.inverse
        let camPos = SIMD3<Float>(c2w.columns.3.x, c2w.columns.3.y, c2w.columns.3.z)
        let fx = Float(K.fx), fy = Float(K.fy), cx = Float(K.cx), cy = Float(K.cy)
        // 世界修正量 → 相機座標的旋轉部分
        let Rwc = simd_float3x3(SIMD3(w2c.columns.0.x, w2c.columns.0.y, w2c.columns.0.z),
                                SIMD3(w2c.columns.1.x, w2c.columns.1.y, w2c.columns.1.z),
                                SIMD3(w2c.columns.2.x, w2c.columns.2.y, w2c.columns.2.z))

        var ata = [Float](repeating: 0, count: 36)
        var atb = [Float](repeating: 0, count: 6)
        var used = 0

        for o in obs {
            guard let X = points[o.trackID] else { continue }
            let pc4 = w2c * SIMD4<Float>(X, 1)
            let Z = pc4.z
            guard Z < -1e-4 else { continue }
            let up = cx + pc4.x * fx / (-Z)
            let vp = cy - pc4.y * fy / (-Z)
            let ru = o.u - up, rv = o.v - vp
            let mag = (ru * ru + rv * rv).squareRoot()
            if mag > kMaxResidualPx { continue }                  // 硬離群
            // Huber：轉折點外降權（√w 施加在 Jacobian 與殘差上）
            let wgt = mag <= kHuberPx ? Float(1) : (kHuberPx / mag)
            let sw = wgt.squareRoot()

            // 投影 Jacobian（2×3，對相機座標）
            let iz = 1 / Z
            let ju = SIMD3<Float>(-fx * iz, 0, pc4.x * fx * iz * iz)
            let jv = SIMD3<Float>(0, fy * iz, -pc4.y * fy * iz * iz)

            // ── ∂Pc/∂x 的推導（兩個容易錯的地方都在這裡）──────────────────
            //
            // ΔT 是套在**相機**上：c2w_new = ΔT · c2w_old
            //   ⇒ w2c_new = c2w_old⁻¹ · ΔT⁻¹
            //   ⇒ Pc_new = Rwc·(ΔT⁻¹ X) + twc ≈ Pc_old − Rwc·(ω×r + t)
            //
            // 注意是 ΔT**⁻¹** 作用在世界點上 —— 相機往 +t 移動等於世界點往 −t 移動。
            // 我第一版把它寫成「世界點 X + ω×r + t」，於是整組 Jacobian 符號相反，
            // 求解方向剛好朝著錯的方向走（離線測試量到解出 +0.0092 而正解是 −0.0092）。
            //
            // 另一個坑：∂(ω×r)/∂ω_k = e_k × r，那是 −[r]× 的**第 k 欄**，不是第 k 列。
            //   e_x × r = ( 0,  −r.z,  r.y)
            //   e_y × r = ( r.z,  0,  −r.x)
            //   e_z × r = (−r.y,  r.x,  0 )
            let r = X - camPos
            let dOmega = [Rwc * SIMD3<Float>(0, r.z, -r.y),      // −(e_x × r)
                          Rwc * SIMD3<Float>(-r.z, 0, r.x),      // −(e_y × r)
                          Rwc * SIMD3<Float>(r.y, -r.x, 0)]      // −(e_z × r)
            let dT = [Rwc * SIMD3<Float>(-1, 0, 0),
                      Rwc * SIMD3<Float>(0, -1, 0),
                      Rwc * SIMD3<Float>(0, 0, -1)]

            var rowU = [Float](repeating: 0, count: 6)
            var rowV = [Float](repeating: 0, count: 6)
            for i in 0..<3 {
                rowU[i] = simd_dot(ju, dOmega[i]) * sw
                rowV[i] = simd_dot(jv, dOmega[i]) * sw
                rowU[i + 3] = simd_dot(ju, dT[i]) * sw
                rowV[i + 3] = simd_dot(jv, dT[i]) * sw
            }
            let bu = ru * sw, bv = rv * sw
            for i in 0..<6 {
                atb[i] += rowU[i] * bu + rowV[i] * bv
                for j in i..<6 {
                    ata[i * 6 + j] += rowU[i] * rowU[j] + rowV[i] * rowV[j]
                }
            }

            // 深度殘差：預測深度(−Z) vs 實測深度。約束重投影看不到的「沿光軸平移」。
            // 權重 fx/d 把公尺換算成同尺度的像素，故可與上面兩列直接相加。
            if kDepthWeight > 0 {
                let d = -Z
                let (scale, huber) = options.depthScale(observed: o.depth, predicted: d, fx: fx)
                let rd = (d - o.depth) * scale
                // ∂(−Z)/∂x = −(∂Pc/∂x 的 z 分量)
                let dwt = min(Float(1), huber / max(huber, abs(rd))).squareRoot()
                var rowD = [Float](repeating: 0, count: 6)
                for i in 0..<3 {
                    rowD[i] = -dOmega[i].z * scale * dwt
                    rowD[i + 3] = -dT[i].z * scale * dwt
                }
                let bd = -rd * dwt        // 殘差定義為 (量測 − 預測)，與上面的 ru/rv 一致
                for i in 0..<6 {
                    atb[i] += rowD[i] * bd
                    for j in i..<6 { ata[i * 6 + j] += rowD[i] * rowD[j] }
                }
            }
            used += 1
        }
        guard used >= kMinObsPerFrame else { return nil }
        for i in 0..<6 { for j in 0..<i { ata[i * 6 + j] = ata[j * 6 + i] } }
        let trace = (0..<6).reduce(Float(0)) { $0 + ata[$1 * 6 + $1] }
        for i in 0..<6 { ata[i * 6 + i] += max(1e-9, trace / 6 * 1e-4) }   // Levenberg

        guard let x = PoseRefiner.choleskySolve6(ata, atb) else { return nil }
        var omega = SIMD3<Float>(x[0], x[1], x[2])
        var trans = SIMD3<Float>(x[3], x[4], x[5])
        let rn = simd_length(omega)
        if rn > PoseRefiner.kMaxRotRad { omega *= PoseRefiner.kMaxRotRad / rn }
        let tn = simd_length(trans)
        if tn > PoseRefiner.kMaxTransM { trans *= PoseRefiner.kMaxTransM / tn }
        omega *= PoseRefiner.kDamping
        trans *= PoseRefiner.kDamping
        return PoseRefiner.deltaTransform(omega: omega, trans: trans, about: camPos)
    }

    // MARK: - 工具

    /// 該觀測在**相機座標**下的位置（位姿無關）。
    /// 與 RefusionEngine 的反投影同一組公式：(xc, -yc, -depth)，ARKit GL 慣例。
    @inline(__always)
    static func cameraLocal(of o: FeatureObservation, K: CameraIntrinsics) -> SIMD3<Float> {
        let xc = (o.u - Float(K.cx)) / Float(K.fx) * o.depth
        let yc = (o.v - Float(K.cy)) / Float(K.fy) * o.depth
        return SIMD3<Float>(xc, -yc, -o.depth)
    }

    static func trackPointsFor(_ poses: [Int: simd_float4x4], order: [Int],
                               intr: [Int: CameraIntrinsics],
                               obsByFrame: [Int: [FeatureObservation]]) -> [Int: SIMD3<Float>] {
        var sum: [Int: SIMD3<Float>] = [:]
        var cnt: [Int: Int] = [:]
        for id in order {
            guard let c2w = poses[id], let K = intr[id], let obs = obsByFrame[id] else { continue }
            for o in obs {
                let w = c2w * SIMD4<Float>(cameraLocal(of: o, K: K), 1)
                sum[o.trackID, default: .zero] += SIMD3(w.x, w.y, w.z)
                cnt[o.trackID, default: 0] += 1
            }
        }
        var out: [Int: SIMD3<Float>] = [:]
        for (t, s) in sum { out[t] = s / Float(cnt[t] ?? 1) }
        return out
    }

    /// 目標函數的 RMS（像素）。含深度項 —— 否則自我驗證看不到深度約束帶來的改善，
    /// 會把有效的一輪判定為「沒變好」而停下。
    /// 這個值同時就是「3DGS 解析度天花板」的直接量測。
    static func reprojectionRMS(order: [Int], poses: [Int: simd_float4x4],
                                intr: [Int: CameraIntrinsics],
                                obsByFrame: [Int: [FeatureObservation]],
                                points: [Int: SIMD3<Float>]) -> Float {
        let r = residuals(order: order, poses: poses, intr: intr,
                          obsByFrame: obsByFrame, points: points)
        return r.total
    }

    /// 分開回報重投影與深度殘差。
    ///
    /// **必須分開看。** 深度殘差的雜訊來源是 LiDAR（σ≈1cm @2m ⇒ 約 7px 等效），
    /// 混進總 RMS 之後再換算成「等效位姿誤差」會把量測雜訊算成位姿誤差 ——
    /// 實機出現過「總 RMS 14.8px ⇒ 聲稱位姿誤差 2.0cm」，但同一份 log 的
    /// 漂移修正只有 0.4cm，兩者矛盾。只有重投影項才適合做位姿解讀。
    static func residuals(order: [Int], poses: [Int: simd_float4x4],
                          intr: [Int: CameraIntrinsics],
                          obsByFrame: [Int: [FeatureObservation]],
                          points: [Int: SIMD3<Float>], options: Options = Options())
        -> (total: Float, reproj: Float, depth: Float, medianReproj: Float, robust: Double) {
        var sum: Double = 0, sumR: Double = 0, sumD: Double = 0
        var n = 0
        var reprojMags: [Float] = []
        // robust：與求解實際最小化的量一致（Huber 加權平方和）。
        // 自我驗證必須用它，不能用原始 RMS —— 兩者不一致時，
        // 一輪明明改善了 inlier 卻因為少數離群值讓 RMS 沒降而被判失敗、提早停止。
        var robust: Double = 0
        for id in order {
            guard let c2w = poses[id], let K = intr[id], let obs = obsByFrame[id] else { continue }
            let w2c = c2w.inverse
            let fx = Float(K.fx)
            for o in obs {
                guard let X = points[o.trackID] else { continue }
                let pc = w2c * SIMD4<Float>(X, 1)
                guard pc.z < -1e-4 else { continue }
                let d = -pc.z
                let up = Float(K.cx) + pc.x * fx / d
                let vp = Float(K.cy) - pc.y * Float(K.fy) / d
                let du = Double(o.u - up), dv = Double(o.v - vp)
                let r2 = du * du + dv * dv
                if r2 > Double(kMaxResidualPx * kMaxResidualPx) { continue }
                var m2 = r2
                var d2: Double = 0
                var depthHuber = kDepthHuberPx
                if kDepthWeight > 0 {
                    let (scale, huber) = options.depthScale(observed: o.depth, predicted: d, fx: fx)
                    let rd = Double((d - o.depth) * scale)
                    d2 = rd * rd
                    m2 += d2
                    depthHuber = huber
                }
                sum += m2; sumR += r2; sumD += d2
                let mag = Float(r2.squareRoot())
                reprojMags.append(mag)
                // Huber：|r| ≤ δ 用平方、超過改用線性（與 solveFrame 的加權一致）
                robust += mag <= kHuberPx
                    ? Double(mag * mag)
                    : Double(kHuberPx * (2 * mag - kHuberPx))
                if kDepthWeight > 0 {
                    let dm = Float(d2.squareRoot())
                    robust += dm <= depthHuber
                        ? Double(dm * dm)
                        : Double(depthHuber * (2 * dm - depthHuber))
                }
                n += 1
            }
        }
        guard n > 0 else { return (.infinity, .infinity, .infinity, .infinity, .infinity) }
        let k = Double(n)
        reprojMags.sort()
        return (Float((sum / k).squareRoot()),
                Float((sumR / k).squareRoot()),
                Float((sumD / k).squareRoot()),
                reprojMags[reprojMags.count / 2],
                robust / k)
    }

    // MARK: - Joint solve with ARKit relative-motion priors

    @inline(__always)
    static func rotation(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                      SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                      SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }

    @inline(__always)
    static func center(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }

    static func rotationVector(_ r: simd_float3x3) -> SIMD3<Float> {
        var q = simd_quatf(r)
        if q.real < 0 { q = simd_quatf(ix: -q.imag.x, iy: -q.imag.y, iz: -q.imag.z, r: -q.real) }
        let s = simd_length(q.imag)
        guard s > 1e-9, s.isFinite else { return .zero }
        return q.imag / s * (2 * atan2(s, q.real))
    }

    /// World rotation vector and camera-centre shift of `pose` relative to `initial`. Increments
    /// applied with `PoseRefiner.deltaTransform(about: current centre)` add to it to first order.
    static func correction(_ pose: simd_float4x4, from initial: simd_float4x4) -> [Double] {
        let w = rotationVector(rotation(pose) * rotation(initial).transpose)
        let t = center(pose) - center(initial)
        return [w.x, w.y, w.z, t.x, t.y, t.z].map(Double.init)
    }

    /// Relative motion between consecutive frames k -> j is kept when both receive the same world
    /// correction. First-order residual: [w_j - w_k ; t_j - t_k + v x w_k], v = initial c_j - c_k.
    struct MotionPrior {
        let k: Int, j: Int
        let lever: SIMD3<Double>
        let weight: [Double]
    }

    static func motionPriors(chain: [Int], initial: [Int: simd_float4x4], times: [Int: Double],
                             options: Options) -> [MotionPrior] {
        var priors: [MotionPrior] = []
        for (a, b) in zip(chain.indices, chain.indices.dropFirst()) {
            guard let pa = initial[chain[a]], let pb = initial[chain[b]] else { continue }
            let gap = (times[chain[b]] ?? 0) - (times[chain[a]] ?? 0)
            guard gap >= 0, gap <= options.priorMaxGapS else { continue }
            let v = center(pb) - center(pa)
            let angle = simd_length(rotationVector(rotation(pb) * rotation(pa).transpose))
            let sr = Double(options.priorRotationRad + options.priorMotionFraction * angle)
            let st = Double(options.priorTranslationM + options.priorMotionFraction * simd_length(v))
            let wr = 1 / (sr * sr), wt = 1 / (st * st)
            priors.append(MotionPrior(k: a, j: b, lever: SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)),
                                      weight: [wr, wr, wr, wt, wt, wt]))
        }
        return priors
    }

    static func priorResidual(_ prior: MotionPrior, _ ek: [Double], _ ej: [Double]) -> [Double] {
        let w = SIMD3(ek[0], ek[1], ek[2]), v = prior.lever
        let lever = simd_cross(v, w)
        return [ej[0] - ek[0], ej[1] - ek[1], ej[2] - ek[2],
                ej[3] - ek[3] + lever.x, ej[4] - ek[4] + lever.y, ej[5] - ek[5] + lever.z]
    }

    /// d(residual)/d(increment of k): [[-I, 0], [[v]x, -I]]; the increment of j enters with I.
    static func priorJacobianK(_ v: SIMD3<Double>) -> [Double] {
        var a = [Double](repeating: 0, count: 36)
        for i in 0..<6 { a[i * 6 + i] = -1 }
        // [v]x in rows 3...5, columns 0...2
        a[3 * 6 + 1] = -v.z; a[3 * 6 + 2] = v.y
        a[4 * 6 + 0] = v.z;  a[4 * 6 + 2] = -v.x
        a[5 * 6 + 0] = -v.y; a[5 * 6 + 1] = v.x
        return a
    }

    /// Normal-equation contribution of one frame's feature observations, without solving it.
    static func linearize(c2w: simd_float4x4, K: CameraIntrinsics, obs: [FeatureObservation],
                          points: [Int: SIMD3<Float>], options: Options) -> (h: [Double], b: [Double]) {
        var h = [Double](repeating: 0, count: 36), b = [Double](repeating: 0, count: 6)
        let w2c = c2w.inverse, camPos = center(c2w)
        let fx = Float(K.fx), fy = Float(K.fy), cx = Float(K.cx), cy = Float(K.cy)
        let Rwc = rotation(w2c)
        var row = [Double](repeating: 0, count: 6)
        func add(_ residual: Float) {
            for i in 0..<6 {
                b[i] += row[i] * Double(residual)
                for j in i..<6 { h[i * 6 + j] += row[i] * row[j] }
            }
        }
        for o in obs {
            guard let X = points[o.trackID] else { continue }
            let pc = w2c * SIMD4<Float>(X, 1), Z = pc.z
            guard Z < -1e-4 else { continue }
            let ru = o.u - (cx + pc.x * fx / (-Z)), rv = o.v - (cy - pc.y * fy / (-Z))
            let mag = (ru * ru + rv * rv).squareRoot()
            if mag > kMaxResidualPx { continue }
            let sw = (mag <= kHuberPx ? 1 : kHuberPx / mag).squareRoot()
            let iz = 1 / Z
            let ju = SIMD3<Float>(-fx * iz, 0, pc.x * fx * iz * iz)
            let jv = SIMD3<Float>(0, fy * iz, -pc.y * fy * iz * iz)
            let r = X - camPos
            let dOmega = [Rwc * SIMD3<Float>(0, r.z, -r.y), Rwc * SIMD3<Float>(-r.z, 0, r.x), Rwc * SIMD3<Float>(r.y, -r.x, 0)]
            let dT = [Rwc * SIMD3<Float>(-1, 0, 0), Rwc * SIMD3<Float>(0, -1, 0), Rwc * SIMD3<Float>(0, 0, -1)]
            for i in 0..<3 { row[i] = Double(simd_dot(ju, dOmega[i]) * sw); row[i + 3] = Double(simd_dot(ju, dT[i]) * sw) }
            add(ru * sw)
            for i in 0..<3 { row[i] = Double(simd_dot(jv, dOmega[i]) * sw); row[i + 3] = Double(simd_dot(jv, dT[i]) * sw) }
            add(rv * sw)
            if kDepthWeight > 0 {
                let d = -Z
                let (scale, huber) = options.depthScale(observed: o.depth, predicted: d, fx: fx)
                let rd = (d - o.depth) * scale
                let dw = min(Float(1), huber / max(huber, abs(rd))).squareRoot()
                for i in 0..<3 { row[i] = Double(-dOmega[i].z * scale * dw); row[i + 3] = Double(-dT[i].z * scale * dw) }
                add(-rd * dw)
            }
        }
        for i in 0..<6 { for j in 0..<i { h[i * 6 + j] = h[j * 6 + i] } }
        return (h, b)
    }

    /// Robust observation cost as a sum (same Huber form as `residuals`).
    static func observationCost(frames: [Int], poses: [Int: simd_float4x4], intr: [Int: CameraIntrinsics],
                                obsByFrame: [Int: [FeatureObservation]], points: [Int: SIMD3<Float>],
                                options: Options) -> Double {
        var cost = 0.0
        for id in frames {
            guard let c2w = poses[id], let K = intr[id], let obs = obsByFrame[id] else { continue }
            let w2c = c2w.inverse, fx = Float(K.fx)
            for o in obs {
                guard let X = points[o.trackID] else { continue }
                let pc = w2c * SIMD4<Float>(X, 1)
                guard pc.z < -1e-4 else { continue }
                let d = -pc.z
                let du = o.u - (Float(K.cx) + pc.x * fx / d), dv = o.v - (Float(K.cy) - pc.y * Float(K.fy) / d)
                let mag = (du * du + dv * dv).squareRoot()
                if mag > kMaxResidualPx { continue }
                cost += mag <= kHuberPx ? Double(mag * mag) : Double(kHuberPx * (2 * mag - kHuberPx))
                if kDepthWeight > 0 {
                    let (scale, huber) = options.depthScale(observed: o.depth, predicted: d, fx: fx)
                    let dm = abs((d - o.depth) * scale)
                    cost += dm <= huber ? Double(dm * dm) : Double(huber * (2 * dm - huber))
                }
            }
        }
        return cost
    }

    /// Track points minimising reprojection plus the depth prior, from the mean back-projection.
    static func optimizedTrackPoints(_ poses: [Int: simd_float4x4], frames: [Int], intr: [Int: CameraIntrinsics],
                                     obsByFrame: [Int: [FeatureObservation]], options: Options) -> [Int: SIMD3<Float>] {
        var points = trackPointsFor(poses, order: frames, intr: intr, obsByFrame: obsByFrame)
        struct View { let w2c: simd_float4x4; let R: simd_float3x3; let K: CameraIntrinsics; let o: FeatureObservation }
        var views: [Int: [View]] = [:]
        for id in frames {
            guard let c2w = poses[id], let K = intr[id], let obs = obsByFrame[id] else { continue }
            let w2c = c2w.inverse, R = rotation(w2c)
            for o in obs { views[o.trackID, default: []].append(View(w2c: w2c, R: R, K: K, o: o)) }
        }
        for (track, list) in views where list.count >= 2 {
            guard var X = points[track] else { continue }
            for _ in 0..<3 {
                var h = simd_double3x3(0), g = SIMD3<Double>.zero
                for view in list {
                    let pc = view.w2c * SIMD4<Float>(X, 1), Z = pc.z
                    guard Z < -1e-4 else { continue }
                    let fx = Float(view.K.fx), fy = Float(view.K.fy), iz = 1 / Z
                    let ru = view.o.u - (Float(view.K.cx) + pc.x * fx / (-Z))
                    let rv = view.o.v - (Float(view.K.cy) - pc.y * fy / (-Z))
                    let mag = (ru * ru + rv * rv).squareRoot()
                    if mag > kMaxResidualPx { continue }
                    let w = Double(mag <= kHuberPx ? 1 : kHuberPx / mag)
                    // d(u, v)/dX = d(u, v)/dPc × R_w2c
                    let gu = view.R.transpose * SIMD3<Float>(-fx * iz, 0, pc.x * fx * iz * iz)
                    let gv = view.R.transpose * SIMD3<Float>(0, fy * iz, -pc.y * fy * iz * iz)
                    let du = SIMD3<Double>(Double(gu.x), Double(gu.y), Double(gu.z))
                    let dv = SIMD3<Double>(Double(gv.x), Double(gv.y), Double(gv.z))
                    h += w * (simd_double3x3(rows: [du * du.x, du * du.y, du * du.z]) + simd_double3x3(rows: [dv * dv.x, dv * dv.y, dv * dv.z]))
                    g += w * (du * Double(ru) + dv * Double(rv))
                    if kDepthWeight > 0 {
                        let d = -Z
                        let (scale, huber) = options.depthScale(observed: view.o.depth, predicted: d, fx: fx)
                        let rd = (d - view.o.depth) * scale
                        let wd = Double(min(Float(1), huber / max(huber, abs(rd))))
                        let gdF = -(view.R.transpose * SIMD3<Float>(0, 0, 1)) * scale
                        let gd = SIMD3<Double>(Double(gdF.x), Double(gdF.y), Double(gdF.z))
                        h += wd * simd_double3x3(rows: [gd * gd.x, gd * gd.y, gd * gd.z])
                        g += wd * gd * Double(-rd)
                    }
                }
                guard abs(h.determinant) > 1e-18 else { break }
                var step = h.inverse * g
                let length = simd_length(step)
                guard length.isFinite else { break }
                if length > 0.05 { step *= 0.05 / length }
                X += SIMD3<Float>(Float(step.x), Float(step.y), Float(step.z))
                if length < 1e-5 { break }
            }
            points[track] = X
        }
        return points
    }

    static func cholesky6(_ a: [Double]) -> [Double]? {
        var l = [Double](repeating: 0, count: 36)
        for i in 0..<6 {
            for j in 0...i {
                var s = a[i * 6 + j]
                for k in 0..<j { s -= l[i * 6 + k] * l[j * 6 + k] }
                if i == j {
                    guard s > 1e-12, s.isFinite else { return nil }
                    l[i * 6 + i] = s.squareRoot()
                } else { l[i * 6 + j] = s / l[j * 6 + j] }
            }
        }
        return l
    }

    static func choleskySolve(_ l: [Double], _ b: [Double]) -> [Double] {
        var y = [Double](repeating: 0, count: 6)
        for i in 0..<6 { var s = b[i]; for k in 0..<i { s -= l[i * 6 + k] * y[k] }; y[i] = s / l[i * 6 + i] }
        var x = [Double](repeating: 0, count: 6)
        for i in stride(from: 5, through: 0, by: -1) {
            var s = y[i]; for k in (i + 1)..<6 { s -= l[k * 6 + i] * x[k] }; x[i] = s / l[i * 6 + i]
        }
        return x
    }

    /// Symmetric block-tridiagonal solve (block Thomas / LDLᵀ). upper[k] couples k and k+1.
    static func solveBlockTridiagonal(diagonal: [[Double]], upper: [[Double]?], rhs: [[Double]]) -> [[Double]]? {
        let n = diagonal.count
        guard n > 0 else { return [] }
        var z = [[Double]](repeating: [], count: n)          // B'_k^-1 d'_k
        var coupling = [[Double]?](repeating: nil, count: n)  // B'_k^-1 C_k, stored column-major by 6 RHS
        var nextDiagonal = diagonal[0], nextRHS = rhs[0]
        for k in 0..<n {
            guard let l = cholesky6(nextDiagonal) else { return nil }
            z[k] = choleskySolve(l, nextRHS)
            guard k + 1 < n else { break }
            nextDiagonal = diagonal[k + 1]; nextRHS = rhs[k + 1]
            guard let c = upper[k] else { continue }
            var columns = [Double](repeating: 0, count: 36)       // columns of B'^-1 C
            for col in 0..<6 {
                let x = choleskySolve(l, (0..<6).map { c[$0 * 6 + col] })
                for row in 0..<6 { columns[row * 6 + col] = x[row] }
            }
            coupling[k] = columns
            // B'_{k+1} = B_{k+1} - Cᵀ B'^-1 C ; d'_{k+1} = d_{k+1} - Cᵀ z_k
            for i in 0..<6 {
                for j in 0..<6 {
                    var sum = 0.0
                    for m in 0..<6 { sum += c[m * 6 + i] * columns[m * 6 + j] }
                    nextDiagonal[i * 6 + j] -= sum
                }
                var sum = 0.0
                for m in 0..<6 { sum += c[m * 6 + i] * z[k][m] }
                nextRHS[i] -= sum
            }
        }
        var x = [[Double]](repeating: [Double](repeating: 0, count: 6), count: n)
        x[n - 1] = z[n - 1]
        for k in stride(from: n - 2, through: 0, by: -1) {
            x[k] = z[k]
            if let w = coupling[k] {
                for i in 0..<6 { var sum = 0.0; for j in 0..<6 { sum += w[i * 6 + j] * x[k + 1][j] }; x[k][i] -= sum }
            }
        }
        return x
    }

    static func jointRounds(chain: [Int], initial: [Int: simd_float4x4], start: [Int: simd_float4x4],
                            times: [Int: Double], intr: [Int: CameraIntrinsics],
                            fit: [Int: [FeatureObservation]], rounds: Int, options: Options,
                            isCancelled: () -> Bool) -> (poses: [Int: simd_float4x4], residuals: [Float], rounds: Int) {
        let priors = motionPriors(chain: chain, initial: initial, times: times, options: options)
        let ar = Double(options.anchorRotationRad), at = Double(options.anchorTranslationM)
        let anchor = [1 / (ar * ar), 1 / (ar * ar), 1 / (ar * ar), 1 / (at * at), 1 / (at * at), 1 / (at * at)]
        func points(_ p: [Int: simd_float4x4]) -> [Int: SIMD3<Float>] {
            options.optimizeTracks
                ? optimizedTrackPoints(p, frames: chain, intr: intr, obsByFrame: fit, options: options)
                : trackPointsFor(p, order: chain, intr: intr, obsByFrame: fit)
        }
        func corrections(_ p: [Int: simd_float4x4]) -> [[Double]] {
            chain.map { id in correction(p[id]!, from: initial[id]!) }
        }
        func priorCost(_ e: [[Double]]) -> Double {
            var cost = 0.0
            for ek in e { for i in 0..<6 { cost += anchor[i] * ek[i] * ek[i] } }
            for prior in priors {
                let r = priorResidual(prior, e[prior.k], e[prior.j])
                for i in 0..<6 { cost += prior.weight[i] * r[i] * r[i] }
            }
            return cost
        }
        var poses = start, res: [Float] = [], applied = 0
        var lambda = 1e-3
        for _ in 0..<rounds {
            if isCancelled() { break }
            let pts = points(poses)
            let e = corrections(poses)
            let before = observationCost(frames: chain, poses: poses, intr: intr, obsByFrame: fit, points: pts,
                                         options: options) + priorCost(e)
            if res.isEmpty {
                res.append(residuals(order: chain, poses: poses, intr: intr, obsByFrame: fit, points: pts, options: options).total)
            }
            var diagonal: [[Double]] = [], rhs: [[Double]] = []
            for (k, id) in chain.enumerated() {
                var (h, b) = (fit[id]?.isEmpty ?? true)
                    ? ([Double](repeating: 0, count: 36), [Double](repeating: 0, count: 6))
                    : linearize(c2w: poses[id]!, K: intr[id]!, obs: fit[id]!, points: pts, options: options)
                for i in 0..<6 { h[i * 6 + i] += anchor[i]; b[i] -= anchor[i] * e[k][i] }
                diagonal.append(h); rhs.append(b)
            }
            var upper = [[Double]?](repeating: nil, count: chain.count)
            for prior in priors {
                let r = priorResidual(prior, e[prior.k], e[prior.j])
                let a = priorJacobianK(prior.lever), w = prior.weight
                // H_kk += AᵀWA, H_jj += W, H_kj += AᵀW ; b_k -= AᵀWr, b_j -= Wr
                for i in 0..<6 {
                    for j in 0..<6 {
                        var sum = 0.0
                        for m in 0..<6 { sum += a[m * 6 + i] * w[m] * a[m * 6 + j] }
                        diagonal[prior.k][i * 6 + j] += sum
                    }
                    diagonal[prior.j][i * 6 + i] += w[i]
                    var bk = 0.0
                    for m in 0..<6 { bk += a[m * 6 + i] * w[m] * r[m] }
                    rhs[prior.k][i] -= bk
                    rhs[prior.j][i] -= w[i] * r[i]
                }
                var coupling = [Double](repeating: 0, count: 36)
                for i in 0..<6 { for j in 0..<6 { coupling[i * 6 + j] = a[j * 6 + i] * w[j] } }
                upper[prior.k] = coupling
            }
            var accepted = false
            for _ in 0..<4 {
                var damped = diagonal
                for k in damped.indices { for i in 0..<6 { damped[k][i * 6 + i] *= 1 + lambda } }
                guard let steps = solveBlockTridiagonal(diagonal: damped, upper: upper, rhs: rhs) else { lambda *= 10; continue }
                var candidate = poses
                for (k, id) in chain.enumerated() {
                    var omega = SIMD3<Float>(Float(steps[k][0]), Float(steps[k][1]), Float(steps[k][2]))
                    var trans = SIMD3<Float>(Float(steps[k][3]), Float(steps[k][4]), Float(steps[k][5]))
                    guard omega.x.isFinite, omega.y.isFinite, omega.z.isFinite,
                          trans.x.isFinite, trans.y.isFinite, trans.z.isFinite else { continue }
                    let rn = simd_length(omega), tn = simd_length(trans)
                    if rn > PoseRefiner.kMaxRotRad { omega *= PoseRefiner.kMaxRotRad / rn }
                    if tn > PoseRefiner.kMaxTransM { trans *= PoseRefiner.kMaxTransM / tn }
                    candidate[id] = PoseRefiner.deltaTransform(omega: omega, trans: trans, about: center(poses[id]!)) * poses[id]!
                }
                let candidatePoints = points(candidate)
                let after = observationCost(frames: chain, poses: candidate, intr: intr, obsByFrame: fit,
                                            points: candidatePoints, options: options) + priorCost(corrections(candidate))
                if after < before {
                    poses = candidate; applied += 1; accepted = true
                    lambda = max(1e-6, lambda / 10)
                    res.append(residuals(order: chain, poses: poses, intr: intr, obsByFrame: fit,
                                         points: candidatePoints, options: options).total)
                    break
                }
                lambda *= 10
            }
            if !accepted { break }
        }
        return (poses, res, applied)
    }
}
