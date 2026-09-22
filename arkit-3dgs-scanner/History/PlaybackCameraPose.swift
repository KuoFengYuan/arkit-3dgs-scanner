import simd

/// 第一人稱回放：使用拍攝位置及前向，依重力保持畫面水平。
nonisolated struct PlaybackCameraPose {
    let transform: simd_float4x4
    let target: SIMD3<Float>

    static func following(_ pose: simd_float4x4) -> PlaybackCameraPose? {
        guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { pose[column][$0].isFinite } }) else { return nil }
        let position = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let axis = -SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        guard simd_length_squared(axis) > 0.0001 else { return nil }
        let forward = simd_normalize(axis)
        let worldUp = SIMD3<Float>(0, 1, 0)
        let eye = position
        let target = position + forward
        let backward = -forward
        // 仰拍／俯拍時避免視線與 up 平行，產生無效的 look-at 矩陣。
        let sensorUp = SIMD3<Float>(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z)
        let upHint = abs(simd_dot(backward, worldUp)) > 0.98 ? sensorUp : worldUp
        guard simd_length_squared(simd_cross(upHint, backward)) > 0.0001 else { return nil }
        let right = simd_normalize(simd_cross(upHint, backward))
        let up = simd_cross(backward, right)
        let transform = simd_float4x4(columns: (SIMD4<Float>(right, 0), SIMD4<Float>(up, 0),
                                               SIMD4<Float>(backward, 0), SIMD4<Float>(eye, 1)))
        guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { transform[column][$0].isFinite } }) else { return nil }
        return PlaybackCameraPose(transform: transform, target: target)
    }
}
