import simd

@main
struct PlaybackCameraTests {
    static func main() {
        func xyz(_ value: SIMD4<Float>) -> SIMD3<Float> { SIMD3<Float>(value.x, value.y, value.z) }
        func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance(a, b) < 0.0001 }
        let original = PlaybackCameraPose.following(matrix_identity_float4x4)!
        let viewDirection = -xyz(original.transform.columns.2)
        precondition(simd_dot(viewDirection, simd_normalize(original.target - xyz(original.transform.columns.3))) > 0.9999)
        precondition(simd_dot(viewDirection, -xyz(original.transform.columns.3)) > 0)
        print("PASS: 跟隨相機朝向拍攝前方，目前拍攝位置位於視野前方")

        var translated = matrix_identity_float4x4
        let offset = SIMD3<Float>(10, -3, 7)
        translated.columns.3 = SIMD4<Float>(offset, 1)
        let moved = PlaybackCameraPose.following(translated)!
        precondition(near(xyz(moved.transform.columns.3) - xyz(original.transform.columns.3), offset))
        precondition(near(moved.target - original.target, offset))
        print("PASS: 跨影格／校正後位移同步作用於跟隨相機及目標")

        let rotation = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)))
        let turned = PlaybackCameraPose.following(rotation)!
        precondition(near(xyz(turned.transform.columns.3), xyz(rotation * original.transform.columns.3)))
        precondition(near(turned.target, xyz(rotation * SIMD4<Float>(original.target, 1))))
        print("PASS: 拍攝方向轉彎時跟隨相機與目標同步旋轉")

        for angle: Float in [-Float.pi / 2, Float.pi / 2, Float.pi * 0.499] {
            let pose = simd_float4x4(simd_quatf(angle: angle, axis: SIMD3<Float>(1, 0, 0)))
            let camera = PlaybackCameraPose.following(pose)!
            let x = xyz(camera.transform.columns.0), y = xyz(camera.transform.columns.1), z = xyz(camera.transform.columns.2)
            precondition(abs(simd_dot(x, y)) < 0.0001 && abs(simd_dot(y, z)) < 0.0001)
            precondition(abs(simd_determinant(simd_float3x3(columns: (x, y, z))) - 1) < 0.0001)
        }
        print("PASS: 垂直仰拍／俯拍保持有限正交相機姿態，不產生無效視角")

        var bad = matrix_identity_float4x4; bad.columns.3.x = .nan
        precondition(PlaybackCameraPose.following(bad) == nil)
        bad = matrix_identity_float4x4; bad.columns.2 = .zero
        precondition(PlaybackCameraPose.following(bad) == nil)
        print("PASS: 非有限及退化拍攝姿態不會驅動視角")
    }
}
