import SwiftUI

struct ContentView: View {
    @Environment(PhotoLibraryService.self) private var photoService

    var body: some View {
        TabView {
            Tab("Library", systemImage: "photo.on.rectangle.angled") {
                LibraryView()
            }

            Tab("Albums", systemImage: "rectangle.stack") {
                AlbumsView()
            }
        }
        .alert("Couldn't Delete", isPresented: deleteErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoService.deleteErrorMessage ?? "")
        }
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { photoService.deleteErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    photoService.deleteErrorMessage = nil
                }
            }
        )
    }
}

#Preview {
    ContentView()
        .environment(PhotoLibraryService())
}
