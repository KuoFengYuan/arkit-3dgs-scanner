import ARKit

/// 新掃描才能載入世界地圖；續掃沿用 session 的座標系與錨點。
@MainActor
enum CaptureSessionConfiguration {
    static func make(config: CaptureConfig, useLiDAR: Bool = true, initialWorldMap: ARWorldMap? = nil) -> ARWorldTrackingConfiguration {
        let result = ARWorldTrackingConfiguration()
        result.worldAlignment = .gravity
        result.environmentTexturing = .none
        result.isAutoFocusEnabled = true
        result.initialWorldMap = initialWorldMap
        if useLiDAR, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            result.frameSemantics.insert(.sceneDepth)
        }
        if useLiDAR, ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            result.frameSemantics.insert(.smoothedSceneDepth)
        }
        if useLiDAR, config.useSceneMesh, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            result.sceneReconstruction = .mesh
        }
        return result
    }
}
