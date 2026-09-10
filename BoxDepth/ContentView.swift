import SwiftUI
import PhotosUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var motion: MotionController
    @Environment(\.scenePhase) private var scenePhase
    @State private var controls = true
    @State private var settings = false
    @State private var photoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var hideTask: Task<Void, Never>?
    @State private var replayTask: Task<Void, Never>?
    @State private var pitch: Float = 0
    @State private var roll: Float = 0
    @State private var dragStart: SIMD2<Float>?
    @State private var replaying = false
    private let ink = Color(red: 0.18, green: 0.23, blue: 0.20)

    var body: some View {
        let photoButtonTitle = model.importing ? "读取中…" : "选择图片"
        ZStack {
            MetalCanvas(model: model, active: scenePhase == .active)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { controls.toggle() }; scheduleHide() }
                .gesture(DragGesture(minimumDistance: 5).onChanged { value in
                    guard motion.demo else { return }
                    stopReplay()
                    if dragStart == nil { dragStart = SIMD2(pitch, roll) }
                    pitch = min(.pi, max(-.pi/3, dragStart!.x - Float(value.translation.height)/180))
                    roll = min(.pi, max(-.pi, dragStart!.y + Float(value.translation.width)/180))
                    updateDemo()
                }.onEnded { _ in dragStart = nil })
            if controls {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("mock iphone duo motion")
                                .font(.system(size: 23, weight: .medium))
                                .lineLimit(2).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
                            Text("随角度变化的光学外屏").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { settings = true; hideTask?.cancel() } label: {
                            Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                        }.accessibilityLabel("设置")
                    }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                    Spacer()
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Circle().fill(motion.calibrated ? Color.green : Color.orange).frame(width: 6, height: 6)
                            Text(motion.demo ? "拖动演示 · 无真实陀螺仪" : motion.isCalibrating ? "正在采集姿态" : motion.calibrated ? "空间已校准" : "等待校准")
                                .font(.caption.weight(.medium))
                        }
                        Text(motion.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        if motion.demo { demoControls }
                        HStack(spacing: 10) {
                            Button { photoPicker = true; hideTask?.cancel() } label: {
                                Label(photoButtonTitle, systemImage: "photo")
                                    .frame(maxWidth: .infinity).frame(height: 46)
                            }.buttonStyle(.plain).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                            Button {
                                stopReplay(); pitch = 0; roll = 0
                                if motion.calibrate() { scheduleHide() }
                            } label: {
                                HStack(spacing: 6) {
                                    if motion.isCalibrating { ProgressView().tint(.white) }
                                    Text(motion.demo ? "复位" : motion.isCalibrating ? "校准中…" : "校准")
                                }.frame(maxWidth: .infinity).frame(height: 46)
                            }.disabled(motion.isCalibrating).buttonStyle(.plain).foregroundStyle(.white).background(ink, in: RoundedRectangle(cornerRadius: 14))
                        }
                        Text("缓慢转动手机 · 轻点画面隐藏工具")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
                }
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 16)
                .transition(.opacity)
            } else if motion.demo {
                VStack { Text("拖动演示 · 非真机验证").font(.caption2).padding(8)
                        .background(.ultraThinMaterial, in: Capsule()); Spacer() }.padding(.top, 8).allowsHitTesting(false)
            }
        }
        .foregroundStyle(ink)
        .preferredColorScheme(.light)
        .statusBarHidden(!controls)
        .persistentSystemOverlays(controls ? .automatic : .hidden)
        .onAppear {
            motion.start()
            #if DEBUG
            if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--demo-pitch"),
               ProcessInfo.processInfo.arguments.count > flag+1,
               let degrees = Float(ProcessInfo.processInfo.arguments[flag+1]), motion.demo {
                pitch = degrees * .pi / 180; updateDemo(); controls = false
            }
            #endif
            scheduleHide()
        }
        .onDisappear { hideTask?.cancel(); stopReplay(); motion.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { hideTask?.cancel(); stopReplay(); motion.stop(); controls = true }
            else if phase == .active { motion.start(); updateDemo() }
        }
        .onChange(of: selectedPhoto) { _, item in
            hideTask?.cancel()
            Task { await model.importPhoto(item); selectedPhoto = nil; scheduleHide() }
        }
        .onChange(of: motion.calibrated) { _, _ in scheduleHide() }
        .photosPicker(isPresented: $photoPicker, selection: $selectedPhoto, matching: .images, photoLibrary: .shared())
        .onChange(of: photoPicker) { _, showing in
            if showing { hideTask?.cancel() } else { scheduleHide() }
        }
        .sheet(isPresented: $settings, onDismiss: scheduleHide) { settingsSheet }
        .alert("无法完成操作", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var demoControls: some View {
        VStack(spacing: 8) {
            HStack {
                ForEach([0,45,90,180], id: \.self) { value in
                    Button("\(value)°") { stopReplay(); pitch = Float(value) * .pi / 180; roll = 0; updateDemo(); scheduleHide() }
                        .font(.caption.monospacedDigit()).frame(maxWidth: .infinity)
                }
                Button(replaying ? "停止" : "回放") { replaying ? stopReplay() : startReplay() }.font(.caption)
            }.buttonStyle(.bordered)
            Text("上滑掀起，下滑放回；左右拖动可侧倾。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("空间") {
                    VStack(alignment: .leading) {
                        Text("视差强度  \(Int(model.preferences.depth * 500))%")
                        Slider(value: $model.preferences.depth, in: 0.02...0.20, step: 0.01)
                    }
                    Text("屏幕正对自己校准，保持观看位置大致不动，再转动手机。模拟角度散射、变暗和柔光，不使用摄像头或人脸跟踪。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("图片") {
                    Picker("适配方式", selection: $model.preferences.fit) {
                        Text("裁切填满").tag(false); Text("完整显示").tag(true)
                    }
                    Button("使用内置测试图") { model.useTestImage() }
                    Text("图片仅保存在本机，最长边不超过 2048 像素。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("重新校准") { settings = false; controls = true; _ = motion.calibrate() }
                    Button("恢复默认设置") { model.resetDefaults() }
                } footer: {
                    Text("返回应用后需重新校准。翻到背面时显示暗面，翻回后恢复。只有真机实际观看才能确认景深错觉。")
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
        }.presentationDetents([.large])
    }

    private func scheduleHide() {
        hideTask?.cancel()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--keep-controls") { return }
        #endif
        guard controls, !motion.isCalibrating, !settings, !photoPicker, !model.importing, motion.calibrated || motion.demo else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, !motion.isCalibrating, !settings, !photoPicker, !model.importing else { return }
            withAnimation(.easeOut(duration: 0.3)) { controls = false }
        }
    }
    private func updateDemo() { if motion.demo { motion.setDemo(pitch: pitch, roll: roll) } }
    private func stopReplay() { replayTask?.cancel(); replayTask = nil; replaying = false }
    private func startReplay() {
        stopReplay(); replaying = true; roll = 0
        replayTask = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(start)/10
                if t >= 1 { break }
                pitch = Float((1-cos(t*2*Double.pi))/2) * .pi; updateDemo()
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled { pitch = 0; updateDemo(); replaying = false }
        }
    }
}
