import Photos
import SwiftUI

@Observable
@MainActor
final class LibraryViewModel {

    // MARK: - Selection State

    var isSelecting = false
    var selectedIdentifiers: Set<String> = []

    // MARK: - Grid State

    var columnCount = 3

    // MARK: - Navigation State

    var navigationPath = NavigationPath()

    // MARK: - Selection Actions

    func toggleSelection(_ identifier: String) {
        if selectedIdentifiers.contains(identifier) {
            selectedIdentifiers.remove(identifier)
        } else {
            selectedIdentifiers.insert(identifier)
        }
    }

    func selectAll(from sections: [PhotoLibraryService.DateSection]) {
        selectedIdentifiers = Set(sections.flatMap(\.assets).map(\.localIdentifier))
    }

    func clearSelection() {
        selectedIdentifiers.removeAll()
        isSelecting = false
    }

    func startSelecting() {
        isSelecting = true
    }

    // MARK: - Grid Zoom

    func handlePinchZoom(_ magnification: CGFloat) {
        withAnimation(.snappy(duration: 0.2)) {
            if magnification > 1.3 && columnCount > 1 {
                columnCount -= 1
            } else if magnification < 0.7 && columnCount < 7 {
                columnCount += 1
            }
        }
    }

    // MARK: - Grid Layout

    var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 1.5), count: columnCount)
    }

    var selectedCount: Int {
        selectedIdentifiers.count
    }

    func isSelected(_ identifier: String) -> Bool {
        selectedIdentifiers.contains(identifier)
    }
}
