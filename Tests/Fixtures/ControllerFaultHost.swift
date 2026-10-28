#if !targetEnvironment(simulator)
#error("Controller fault QA hosts must never be built for physical devices")
#endif
import SwiftUI

@main
struct ControllerFaultHost: App {
    var body: some Scene {
        WindowGroup { Text("Isolated controller QA") }
    }
}
