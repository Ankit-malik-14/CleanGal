import SwiftUI

@main
struct CleanGalApp: App {
    @State private var photoService = PhotoLibraryService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(photoService)
        }
    }
}
