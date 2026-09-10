import Foundation
import simd

/// World: X right, Y toward the phone's top, Z above the table. H = 1.
/// Device attitude must map portrait device vectors into the motion reference frame.
enum SpatialMath {
    static let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
    static let hinge = SIMD3<Float>(0, -0.5, 0)

    static func relative(current: simd_quatf, reference: simd_quatf) -> simd_quatf {
        simd_normalize(reference.inverse * current)
    }

    static func screenPoint(_ local: SIMD3<Float>, rotation: simd_quatf) -> SIMD3<Float> {
        hinge + rotation.act(local - hinge)
    }

    /// Optical mode trades exact world registration for a restrained apparent
    /// depth, matching a shallow glass window rather than a rigid hinged slab.
    static func opticalRotation(_ q: simd_quatf, enabled: Bool) -> simd_quatf {
        enabled ? shortestSlerp(identity, q, 0.62) : q
    }

    static func eye(overhead: Bool) -> SIMD3<Float> {
        SIMD3(0, overhead ? 0 : -1, 3)
    }

    static func facing(rotation: simd_quatf, eye: SIMD3<Float>) -> Float {
        let center = screenPoint(.zero, rotation: rotation)
        return simd_dot(rotation.act(SIMD3(0, 0, 1)), simd_normalize(eye - center))
    }

    static func smoothingAlpha(dt: Double) -> Float {
        Float(1 - exp(-min(max(dt, 0), 0.1) / 0.018))
    }

    static func shortestSlerp(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
        let end = simd_dot(a.vector, b.vector) < 0 ? simd_quatf(vector: -b.vector) : b
        return simd_normalize(simd_slerp(a, end, t))
    }

    /// CPU counterpart of the shader's intersection code for deterministic tests.
    struct Hit {
        let position: SIMD3<Float>
        let surface: Int // 0 floor, 1..4 walls
        let t: Float
    }

    static func intersect(eye: SIMD3<Float>, screen: SIMD3<Float>, aspect: Float, depth: Float) -> Hit? {
        let d = screen - eye
        var closest: Hit?
        let planes: [(Int, Float, Int)] = [(2, -depth, 0), (0, -aspect/2, 1),
                                         (0, aspect/2, 2), (1, -0.5, 3), (1, 0.5, 4)]
        for (axis, value, surface) in planes {
            guard abs(d[axis]) > 1e-6 else { continue }
            let t = (value - eye[axis]) / d[axis]
            guard t.isFinite, t > 1.00001 else { continue }
            let p = eye + t * d
            let e: Float = 1e-5
            let inside: Bool
            if surface == 0 {
                inside = abs(p.x) <= aspect/2 + e && abs(p.y) <= 0.5 + e
            } else {
                inside = p.z >= -depth-e && p.z <= e &&
                    (axis == 0 ? abs(p.y) <= 0.5+e : abs(p.x) <= aspect/2+e)
            }
            if inside && t < (closest?.t ?? .infinity) {
                closest = Hit(position: p, surface: surface, t: t)
            }
        }
        return closest
    }

    static func photoUV(point: SIMD3<Float>, floorAspect: Float, imageAspect: Float, fit: Bool) -> SIMD2<Float> {
        var uv = SIMD2<Float>(point.x / floorAspect + 0.5, 0.5 - point.y)
        let ratio = imageAspect / floorAspect
        if fit {
            if ratio > 1 { uv.y = (uv.y - 0.5) * ratio + 0.5 }
            else { uv.x = (uv.x - 0.5) / ratio + 0.5 }
        } else {
            if ratio > 1 { uv.x = (uv.x - 0.5) / ratio + 0.5 }
            else { uv.y = (uv.y - 0.5) * ratio + 0.5 }
        }
        return uv
    }
}
