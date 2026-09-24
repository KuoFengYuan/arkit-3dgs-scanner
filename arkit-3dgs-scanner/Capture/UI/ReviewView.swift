//
//  ReviewView.swift
//  fable — 掃描後的點雲驗收檢視器（單指旋轉 / 雙指縮放平移）
//
//  顯示的是「重融合 + 姿態修正後」的點雲 —— 即實際會寫進 points3D.bin 的內容，
//  所見即所得；同時疊上修正後的相機軌跡供檢查追蹤品質。
//

import SwiftUI
import SceneKit
import simd

struct ReviewPointCloudView: UIViewRepresentable {
    let points: [CloudPoint]
    let trajectory: [simd_float4x4]
    var highlightedPose: simd_float4x4? = nil
    var resetCameraToken = 0
    var followsHighlightedPose = false
    var isPlaying = false
    var followTransitionDuration: TimeInterval = 0.25

    var measurementPoints: [SIMD3<Float>] = []
    var candidatePoint: SIMD3<Float>? = nil
    var measurementZoom = false
    var onPointPicked: ((SIMD3<Float>?) -> Void)? = nil

    final class Coordinator: NSObject {
        var points: [CloudPoint] = []
        var measurementZoom = false
        var onPointPicked: ((SIMD3<Float>?) -> Void)?
        @objc func pick(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView, let onPointPicked else { return }
            let tap = gesture.location(in: view)
            let projected = points.map { p -> SIMD3<Float> in
                let screen = view.projectPoint(SCNVector3(p.x,p.y,p.z))
                return SIMD3(screen.x,screen.y,screen.z)
            }
            let index = SceneMetricScale.pickProjectedIndex(projected, at: SIMD2(Float(tap.x),Float(tap.y)))
            onPointPicked(index.map { SIMD3(points[$0].x,points[$0].y,points[$0].z) })
        }
        var resetCameraToken = 0
        var lastFollowedPose: simd_float4x4?
        var wasFollowing = false
        var wasPlaying = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = Self.buildScene(points: points, trajectory: trajectory)
        view.allowsCameraControl = true          // 內建軌道相機：旋轉/縮放/平移
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .none
        view.backgroundColor = Self.canvas
        view.pointOfView = Self.fittedCamera(for: points, trajectory: trajectory)
        view.defaultCameraController.target = SCNVector3(Self.sceneCenter(points: points, trajectory: trajectory))
        context.coordinator.resetCameraToken = resetCameraToken
        context.coordinator.points = points
        context.coordinator.onPointPicked = onPointPicked
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pick(_:))))
        updateMeasurements(in: view)
        updateHighlight(in: view)
        updateFollowCamera(in: view, coordinator: context.coordinator, animated: false)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.onPointPicked = onPointPicked
        // 更新標記與跟隨視角，不重建點雲；一般 3D 驗收仍保留自由旋轉／縮放。
        updateHighlight(in: uiView)
        if context.coordinator.resetCameraToken != resetCameraToken {
            uiView.defaultCameraController.stopInertia()
            uiView.pointOfView = Self.fittedCamera(for: points, trajectory: trajectory)
            uiView.defaultCameraController.target = SCNVector3(Self.sceneCenter(points: points, trajectory: trajectory))
            context.coordinator.resetCameraToken = resetCameraToken
            context.coordinator.lastFollowedPose = nil
        }
        if onPointPicked != nil, context.coordinator.measurementZoom != measurementZoom {
            uiView.defaultCameraController.stopInertia()
            if measurementZoom, let candidatePoint, let camera = uiView.pointOfView {
                let target = uiView.defaultCameraController.target
                camera.simdPosition += candidatePoint - SIMD3(target.x,target.y,target.z)
                uiView.defaultCameraController.target = SCNVector3(candidatePoint)
            }
            uiView.pointOfView?.camera?.fieldOfView = measurementZoom ? 24 : 60
            context.coordinator.measurementZoom = measurementZoom
        }
        updateMeasurements(in: uiView)
        updateFollowCamera(in: uiView, coordinator: context.coordinator, animated: isPlaying)
    }

    private func updateMeasurements(in view: SCNView) {
        guard let root = view.scene?.rootNode else { return }
        root.childNode(withName: "measurement", recursively: false)?.removeFromParentNode()
        guard !measurementPoints.isEmpty || candidatePoint != nil else { return }
        let group = SCNNode(); group.name = "measurement"
        for point in measurementPoints { group.addChildNode(measurementMarker(point, color: .systemCyan, in: view)) }
        if measurementPoints.count == 2 {
            group.addChildNode(SCNNode(geometry: PointCloudRendering.polyline(measurementPoints.map { SCNVector3($0) }, color: .systemCyan)))
        }
        if let candidatePoint { group.addChildNode(measurementMarker(candidatePoint, color: .systemOrange, in: view)) }
        root.addChildNode(group)
    }

    private func measurementMarker(_ point: SIMD3<Float>, color: UIColor, in view: SCNView) -> SCNNode {
        let node = Self.marker(at: SCNVector3(point), color: color)
        if let camera = view.pointOfView {
            let distance = simd_distance(point,camera.simdWorldPosition)
            let fov = Float(camera.camera?.fieldOfView ?? 60) * .pi / 180
            // Aim for a readable 14-screen-point diameter at the time of selection/zoom.
            let radius = max(0.008, distance * tan(fov/2) * 14 / Float(max(300,view.bounds.height)))
            node.simdScale = SIMD3(repeating: radius / 0.02)
        }
        node.renderingOrder = 100
        node.geometry?.firstMaterial?.readsFromDepthBuffer = false
        node.geometry?.firstMaterial?.writesToDepthBuffer = false
        return node
    }

    private func updateFollowCamera(in view: SCNView, coordinator: Coordinator, animated: Bool) {
        let playbackStarted = isPlaying && !coordinator.wasPlaying
        coordinator.wasPlaying = isPlaying
        guard followsHighlightedPose, let pose = highlightedPose,
              let follow = PlaybackCameraPose.following(pose), let camera = view.pointOfView else {
            coordinator.wasFollowing = false
            coordinator.lastFollowedPose = nil
            view.allowsCameraControl = true
            return
        }
        // 第一人稱與顯示影格鎖定；切換總覽後才啟用軌道相機。
        view.allowsCameraControl = false
        let samePose = coordinator.lastFollowedPose.map { previous in
            (0..<4).allSatisfy { previous[$0] == pose[$0] }
        } ?? false
        guard !samePose || !coordinator.wasFollowing || playbackStarted else { return }
        view.defaultCameraController.stopInertia()
        // 過渡從上一個畫面實際呈現的位置開始，快速跳幀也不堆積動畫。
        let visibleTransform = camera.presentation.simdTransform
        camera.removeAllActions()
        camera.removeAllAnimations()
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        camera.simdTransform = visibleTransform
        SCNTransaction.commit()
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated && coordinator.wasFollowing ? followTransitionDuration : 0
        SCNTransaction.disableActions = !animated || !coordinator.wasFollowing
        camera.simdTransform = follow.transform
        camera.camera?.zNear = 0.02
        SCNTransaction.commit()
        view.defaultCameraController.target = SCNVector3(follow.target)
        coordinator.lastFollowedPose = pose
        coordinator.wasFollowing = true
    }

    private func updateHighlight(in view: SCNView) {
        guard let marker = view.scene?.rootNode.childNode(withName: "selectedCamera", recursively: false) else { return }
        marker.isHidden = highlightedPose == nil || followsHighlightedPose
        if let highlightedPose { marker.simdTransform = highlightedPose }
    }


    /// Matches DS.Palette.canvas so the viewport and the app chrome read as one surface.
    static let canvas = UIColor(red: 0.039, green: 0.043, blue: 0.051, alpha: 1)

    private static func buildScene(points: [CloudPoint], trajectory: [simd_float4x4]) -> SCNScene {
        let scene = SCNScene()

        // 點雲分塊掛載（≤250k 點 → ~16 個 draw call）
        var index = 0
        let chunk = 16_384
        while index < points.count {
            let end = min(index + chunk, points.count)
            let node = SCNNode(geometry: PointCloudRendering.geometry(
                for: Array(points[index..<end]), minScreenRadius: 2.5, maxScreenRadius: 9))
            scene.rootNode.addChildNode(node)
            index = end
        }

        // 修正後相機軌跡 + 起點/終點標記
        if trajectory.count >= 2 {
            let positions = trajectory.map { t in
                SCNVector3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
            scene.rootNode.addChildNode(
                SCNNode(geometry: PointCloudRendering.polyline(positions, color: .systemGreen)))
            scene.rootNode.addChildNode(marker(at: positions.first!, color: .systemGreen))
            scene.rootNode.addChildNode(marker(at: positions.last!, color: .systemRed))
        }
        let cameraMarker = SCNNode()
        cameraMarker.name = "selectedCamera"
        // ARKit 相機往局部 -Z 看。橘色視錐與中心線標示拍攝位置及方向。
        let origin = SCNVector3Zero
        let corners = [SCNVector3(-0.13, -0.09, -0.25), SCNVector3(0.13, -0.09, -0.25),
                       SCNVector3(0.13, 0.09, -0.25), SCNVector3(-0.13, 0.09, -0.25)]
        for corner in corners {
            cameraMarker.addChildNode(SCNNode(geometry: PointCloudRendering.polyline([origin, corner], color: .systemOrange)))
        }
        cameraMarker.addChildNode(SCNNode(geometry: PointCloudRendering.polyline(corners + [corners[0]], color: .systemOrange)))
        cameraMarker.addChildNode(SCNNode(geometry: PointCloudRendering.polyline([origin, SCNVector3(0, 0, -0.45)], color: .systemOrange)))
        cameraMarker.addChildNode(marker(at: origin, color: .systemOrange))
        cameraMarker.isHidden = true
        scene.rootNode.addChildNode(cameraMarker)
        return scene
    }

    private static func marker(at position: SCNVector3, color: UIColor) -> SCNNode {
        let sphere = SCNSphere(radius: 0.02)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        sphere.materials = [mat]
        let node = SCNNode(geometry: sphere)
        node.position = position
        return node
    }

    private static func bounds(points: [CloudPoint], trajectory: [simd_float4x4]) -> (SIMD3<Float>, SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        func include(_ p: SIMD3<Float>) {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return }
            lo = simd_min(lo, p); hi = simd_max(hi, p); found = true
        }
        for i in stride(from: 0, to: points.count, by: max(1, points.count / 5000)) {
            include(SIMD3<Float>(points[i].x, points[i].y, points[i].z))
        }
        for pose in trajectory { include(SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)) }
        return found ? (lo, hi) : (SIMD3<Float>(repeating: -1), SIMD3<Float>(repeating: 1))
    }

    private static func sceneCenter(points: [CloudPoint], trajectory: [simd_float4x4]) -> SIMD3<Float> {
        let (lo, hi) = bounds(points: points, trajectory: trajectory)
        return (lo + hi) * 0.5
    }

    /// 同時框住點雲與路線；只有路線的舊紀錄也能正常檢視。
    private static func fittedCamera(for points: [CloudPoint], trajectory: [simd_float4x4]) -> SCNNode {
        let (lo, hi) = bounds(points: points, trajectory: trajectory)
        let center = (lo + hi) * 0.5
        let radius = max(0.5, simd_length(hi - lo) * 0.5)
        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = Double(max(200, radius * 8))
        let node = SCNNode()
        node.camera = camera
        let offset = simd_normalize(SIMD3<Float>(1, 0.7, 1)) * (radius * 2.4)
        node.simdPosition = center + offset
        node.look(at: SCNVector3(center.x, center.y, center.z))
        return node
    }
}
