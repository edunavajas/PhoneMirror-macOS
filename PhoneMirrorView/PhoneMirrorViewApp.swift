import SwiftUI

@main
struct PhoneMirrorViewApp: App {
    init() {
        MirrorService.type = "_phonemirror._tcp"
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
