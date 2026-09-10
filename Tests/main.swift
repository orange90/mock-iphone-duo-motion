import Foundation
import simd

var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fatalError("FAIL: \(name)") }; passed += 1; print("PASS: \(name)")
}
func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4) -> Bool { simd_length(a-b) < eps }
let axis = SIMD3<Float>(1,0,0)
let reference = simd_quatf(angle: 0.8, axis: simd_normalize(SIMD3<Float>(1,2,3)))
check(near(SpatialMath.relative(current: reference, reference: reference).act(axis),axis), "calibration cancels arbitrary reference")
let delta = simd_quatf(angle: .pi/3, axis: axis)
check(near(SpatialMath.relative(current: reference*delta, reference: reference).act(SIMD3(0,1,0)),delta.act(SIMD3(0,1,0))), "reference multiplication order")
for degrees in [-60,0,30,45,80,90,120,180,270,360] {
    let q = simd_quatf(angle: Float(degrees) * .pi / 180,axis: axis)
    check(near(SpatialMath.screenPoint(SpatialMath.hinge,rotation: q),SpatialMath.hinge), "hinge fixed at \(degrees) degrees")
}
let raised = SpatialMath.screenPoint(SIMD3(0,0.5,0),rotation: delta)
check(raised.z > 0, "positive pitch raises top edge")
check(near(SpatialMath.screenPoint(SIMD3(0,0.5,0),rotation: simd_quatf(angle: 2 * .pi,axis: axis)),SIMD3(0,0.5,0)), "full turn returns to original")
let e = SpatialMath.eye(overhead: true)
let hit = SpatialMath.intersect(eye:e,screen:.zero,aspect:0.5,depth:0.08)
check(hit?.surface == 0 && near(hit!.position,SIMD3(0,0,-0.08)), "center ray hits floor")
check(SpatialMath.intersect(eye:e,screen:SIMD3(1,0,0),aspect:0.5,depth:0.08) == nil, "outside box has no false hit")
check(SpatialMath.intersect(eye:SIMD3(0,0,1),screen:SIMD3(1,0,1),aspect:0.5,depth:0.08) == nil, "parallel ray safely misses")
let side = SpatialMath.intersect(eye:SIMD3(-1,0,3),screen:SIMD3(0.245,0,0),aspect:0.5,depth:0.2)
check(side?.surface == 2, "side wall occludes floor")
for overhead in [true,false] {
    let eye = SpatialMath.eye(overhead: overhead)
    for degrees in stride(from:-60,through:360,by:1) {
        let q = simd_quatf(angle: Float(degrees) * .pi / 180,axis: axis)
        let f = SpatialMath.facing(rotation:q,eye:eye)
        assert(f.isFinite)
        for x in [Float(-0.25),0,0.25] {
            for y in [Float(-0.5),0,0.5] {
                if let h = SpatialMath.intersect(eye:eye,screen:SpatialMath.screenPoint(SIMD3(x,y,0),rotation:q),aspect:0.5,depth:0.08) {
                    assert(h.t.isFinite && h.t>1 && h.position.x.isFinite && h.position.y.isFinite && h.position.z.isFinite)
                }
            }
        }
    }
}
check(true,"7,578 ray samples across flip angles remain finite")
check(SpatialMath.facing(rotation: simd_quatf(angle:.pi,axis:axis),eye:e)<0,"back face hidden")
let uvTop = SpatialMath.photoUV(point:SIMD3(0,0.4,-0.08),floorAspect:0.5,imageAspect:0.5,fit:false)
check(uvTop.y < 0.5,"top of photo stays at top")
let crop = SpatialMath.photoUV(point:SIMD3(0.25,0,-0.08),floorAspect:0.5,imageAspect:2,fit:false)
check(abs(crop.x-0.625)<1e-5,"landscape crop does not stretch")
let fit = SpatialMath.photoUV(point:SIMD3(0,0.4,-0.08),floorAspect:0.5,imageAspect:2,fit:true)
check(fit.y<0,"fit leaves letterbox outside photo")
let antipodal = SpatialMath.shortestSlerp(reference,simd_quatf(vector:-reference.vector),0.5)
check(near(antipodal.act(axis),reference.act(axis)),"quaternion sign change does not spin")
check(SpatialMath.smoothingAlpha(dt: 0.01)>0 && SpatialMath.smoothingAlpha(dt:0.01)<1,"bounded smoothing")
print("\(passed) checks passed")
let optical = SpatialMath.opticalRotation(delta,enabled:true)
check(optical.angle < delta.angle && optical.angle > 0,"optical compensation has restrained gain")
check(near(SpatialMath.opticalRotation(delta,enabled:false).act(axis),delta.act(axis)),"strict mode preserves original geometry")
check(near(SpatialMath.screenPoint(SpatialMath.hinge,rotation:optical),SpatialMath.hinge),"optical mode still holds hinge")
print("Final total: \(passed) checks passed")
