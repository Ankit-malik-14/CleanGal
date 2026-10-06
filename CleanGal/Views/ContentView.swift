import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Library", systemImage: "photo.on.rectangle.angled") {
                LibraryView()
            }

            Tab("Albums", systemImage: "rectangle.stack") {
                AlbumsView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(PhotoLibraryService())
}
