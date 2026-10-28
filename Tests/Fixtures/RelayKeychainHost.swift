import SwiftUI

// Isolated test host only. No credentials, network, WCSession or production
// controller is loaded. Keychain tests need an application identity, which
// an unhosted xctest process does not have on the iOS simulator.
@main
struct RelayKeychainHost: App {
    var body: some Scene {
        WindowGroup { Text("Isolated Keychain QA") }
    }
}
