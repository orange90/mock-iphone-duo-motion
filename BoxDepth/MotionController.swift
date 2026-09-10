import CoreMotion
import Combine
import simd

final class MotionController: ObservableObject {
    @Published private(set) var message = "屏幕正对自己，静止片刻后校准。"
    @Published private(set) var calibrated = false
    @Published private(set) var demo = false
    @Published private(set) var isCalibrating = false
    private var calibrationTask: Task<Void, Never>?
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.name = "BoxDepth.motion"; q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive; return q
    }()
    private let lock = NSLock()
    private var filtered = SpatialMath.identity
    private var reference: simd_quatf?
    private var samples: [CalibrationSample] = []
    private var lastTime: TimeInterval = 0
    private var demoRotation = SpatialMath.identity
    private var generation = 0
    private var useDemo = false

    private var hasMotionHardware: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return manager.isDeviceMotionAvailable
        #endif
    }

    func start() {
        guard !manager.isDeviceMotionActive else { return }
        lock.lock()
        generation += 1
        let run = generation
        lastTime = 0; samples.removeAll(); reference = nil; filtered = SpatialMath.identity
        lock.unlock()
        calibrationTask?.cancel(); isCalibrating = false
        calibrated = false
        let available = hasMotionHardware
        demo = !available
        lock.lock(); useDemo = !available; lock.unlock()
        if !available {
            message = "拖动演示 · 未使用真实陀螺仪"
            return
        }
        message = "屏幕正对自己，点击校准后稍稳住即可。"
        manager.deviceMotionUpdateInterval = 1.0 / 100
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, error in
            guard let self else { return }
            guard let motion else {
                if error != nil {
                    DispatchQueue.main.async { self.message = "运动数据不可用，请检查权限后重新打开应用。" }
                }
                return
            }
            self.lock.lock(); defer { self.lock.unlock() }
            guard run == self.generation else { return }
            let q = motion.attitude.quaternion
            let raw = simd_normalize(simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w)))
            guard raw.vector.x.isFinite, raw.vector.y.isFinite, raw.vector.z.isFinite, raw.vector.w.isFinite else { return }
            let dt = motion.timestamp - self.lastTime
            self.filtered = self.lastTime == 0 ? raw : SpatialMath.shortestSlerp(self.filtered, raw, SpatialMath.smoothingAlpha(dt: dt))
            self.lastTime = motion.timestamp
            let r = motion.rotationRate, a = motion.userAcceleration
            self.samples.append(CalibrationSample(rotation: self.filtered, timestamp: motion.timestamp,
                rotationRate: sqrt(r.x*r.x+r.y*r.y+r.z*r.z),
                acceleration: sqrt(a.x*a.x+a.y*a.y+a.z*a.z), gravityZ: motion.gravity.z))
            self.samples.removeAll { motion.timestamp - $0.timestamp > 1.0 }

        }
    }

    @discardableResult func calibrate(requireFlat: Bool = false) -> Bool {
        if demo {
            setDemo(pitch: 0, roll: 0); message = "拖动演示 · 未使用真实陀螺仪"; return true
        }
        guard !isCalibrating else { return false }
        calibrated = false; isCalibrating = true
        message = "正在校准…请稍稳住手机，无需再次点击。"
        let requestedAt = ProcessInfo.processInfo.systemUptime
        calibrationTask = Task { @MainActor [weak self] in
            for attempt in 0..<40 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                // Ignore the physical button-tap impulse, then evaluate a
                // rolling window. One noisy sample no longer clears history.
                let pose = self.captureCalibration(after: requestedAt + 0.18, now: now, requireFlat: requireFlat)
                if pose != nil {
                    self.isCalibrating = false; self.calibrated = true
                    self.message = requireFlat ? "已校准 · 以下边缘为支点缓慢掀起手机。" : "已校准 · 缓慢左右转动，观察清晰度与表面柔光。"
                    self.calibrationTask = nil
                    return
                }
                if attempt == 10 {
                    self.message = requireFlat ? "请屏幕朝上放平，正在自动等待稳定…" : "正在等待姿态稳定，轻微手抖没关系…"
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.isCalibrating = false; self.calibrationTask = nil
            self.message = requireFlat ? "尚未校准：请放平手机，再点一次校准。" : "尚未校准：请停止转动，再点一次校准。"
        }
        return true
    }

    private func captureCalibration(after: TimeInterval, now: TimeInterval, requireFlat: Bool) -> simd_quatf? {
        lock.lock(); defer { lock.unlock() }
        let candidates = samples.filter { $0.timestamp >= after }
        let pose = CalibrationWindow.reference(from: candidates, now: now, requireFlat: requireFlat)
        if let pose { reference = pose }
        return pose
    }

    func snapshot() -> (rotation: simd_quatf, timestamp: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if useDemo { return (demoRotation, ProcessInfo.processInfo.systemUptime) }
        guard let reference else { return (SpatialMath.identity, lastTime) }
        return (SpatialMath.relative(current: filtered, reference: reference), lastTime)
    }

    func setDemo(pitch: Float, roll: Float) {
        lock.lock(); defer { lock.unlock() }
        demoRotation = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)) *
            simd_quatf(angle: roll, axis: SIMD3(0, 1, 0))
    }

    func stop() {
        calibrationTask?.cancel(); calibrationTask = nil; isCalibrating = false
        manager.stopDeviceMotionUpdates()
        lock.lock(); generation += 1; reference = nil; samples.removeAll(); lock.unlock()
        calibrated = false
        message = "返回后请重新面向屏幕并校准。"
    }
}

/// A timestamp window, independent of the sensor's actual delivery frequency.
struct CalibrationSample {
    let rotation: simd_quatf
    let timestamp: TimeInterval
    let rotationRate: Double
    let acceleration: Double
    let gravityZ: Double
}

enum CalibrationWindow {
    static func reference(from samples: [CalibrationSample], now: TimeInterval,
                          requireFlat: Bool) -> simd_quatf? {
        let recent = samples.filter { $0.timestamp <= now && now - $0.timestamp <= 0.38 }
        guard let first = recent.first, let last = recent.last, recent.count >= 8,
              last.timestamp-first.timestamp >= 0.25, now-last.timestamp < 0.15 else { return nil }
        guard recent.allSatisfy({ sample in
            let q = sample.rotation.vector
            return q.x.isFinite && q.y.isFinite && q.z.isFinite && q.w.isFinite &&
                sample.rotationRate.isFinite && sample.acceleration.isFinite && sample.gravityZ.isFinite &&
                sample.rotationRate < 1.2 && sample.acceleration < 0.5 &&
                (!requireFlat || sample.gravityZ < -0.97)
        }) else { return nil }
        let count = Double(recent.count)
        let rateRMS = sqrt(recent.reduce(0) { $0 + $1.rotationRate*$1.rotationRate } / count)
        let accelerationRMS = sqrt(recent.reduce(0) { $0 + $1.acceleration*$1.acceleration } / count)
        guard rateRMS < 0.35, accelerationRMS < 0.12 else { return nil }
        var mean = first.rotation
        for (i, sample) in recent.dropFirst().enumerated() {
            mean = SpatialMath.shortestSlerp(mean, sample.rotation, 1 / Float(i+2))
        }
        // Tolerate handheld tremor while rejecting an actual turning gesture.
        let minimumDot = cos(Float.pi / 180) // 2-degree quaternion distance
        guard recent.allSatisfy({ abs(simd_dot(mean.vector,$0.rotation.vector)) >= minimumDot }) else { return nil }
        return mean
    }
}
