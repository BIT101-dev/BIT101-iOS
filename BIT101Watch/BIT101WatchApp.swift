import SwiftUI

@main
struct BIT101WatchApp: App {
    @StateObject private var model = WatchScheduleStatusModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchScheduleRootView(model: model)
                .task {
                    model.activate()
                }
                .onChange(of: scenePhase) { _, phase in
                    model.handleScenePhase(phase)
                }
        }
    }
}
