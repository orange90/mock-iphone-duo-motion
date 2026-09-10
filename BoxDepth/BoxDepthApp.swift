import SwiftUI

@main struct BoxDepthApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene { WindowGroup { ContentView(model: model, motion: model.motion) } }
}
