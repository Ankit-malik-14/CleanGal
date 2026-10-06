import SwiftUI
import Photos
import MapKit

struct MediaInfoView: View {
    let asset: PHAsset

    @Environment(PhotoLibraryService.self) private var photoService
    @Environment(\.dismiss) private var dismiss

    @State private var mediaInfo: PhotoLibraryService.MediaInfo?

    var body: some View {
        NavigationStack {
            List {
                if let info = mediaInfo {
                    cameraSection(info)
                    imageDetailsSection(info)
                    fileSection(info)
                    dateLocationSection(info)
                } else {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .task {
            mediaInfo = await photoService.loadMediaInfo(for: asset)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func cameraSection(_ info: PhotoLibraryService.MediaInfo) -> some View {
        if info.cameraMake != nil || info.cameraModel != nil || info.lensModel != nil {
            Section("Camera") {
                if let model = info.cameraModel {
                    infoRow("Device", value: model)
                }
                if let make = info.cameraMake {
                    infoRow("Make", value: make)
                }
                if let lens = info.lensModel {
                    infoRow("Lens", value: lens)
                }
                if let focal = info.focalLength {
                    infoRow("Focal Length", value: "\(focal) mm")
                }
                if let aperture = info.aperture {
                    infoRow("Aperture", value: "ƒ/\(aperture)")
                }
                if let shutter = info.shutterSpeed {
                    infoRow("Shutter Speed", value: shutter)
                }
                if let iso = info.iso {
                    infoRow("ISO", value: "\(iso)")
                }
            }
        }
    }

    @ViewBuilder
    private func imageDetailsSection(_ info: PhotoLibraryService.MediaInfo) -> some View {
        Section("Image") {
            infoRow("Resolution", value: "\(info.pixelWidth) × \(info.pixelHeight)")
            infoRow("Megapixels", value: String(format: "%.1f MP", info.megapixels))
            if let colorSpace = info.colorSpace {
                infoRow("Color Space", value: colorSpace)
            }
        }
    }

    @ViewBuilder
    private func fileSection(_ info: PhotoLibraryService.MediaInfo) -> some View {
        Section("File") {
            if let size = info.fileSize {
                infoRow("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if let format = info.fileFormat {
                infoRow("Format", value: formatUTI(format))
            }
        }
    }

    @ViewBuilder
    private func dateLocationSection(_ info: PhotoLibraryService.MediaInfo) -> some View {
        Section("Date & Location") {
            if let date = info.creationDate {
                infoRow("Date", value: date.formatted(.dateTime.year().month().day().hour().minute()))
            }
            if let location = info.location {
                infoRow("Coordinates", value: String(
                    format: "%.4f, %.4f",
                    location.coordinate.latitude,
                    location.coordinate.longitude
                ))

                Map(initialPosition: .region(MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))) {
                    Marker("", coordinate: location.coordinate)
                }
                .frame(height: 200)
                .clipShape(.rect(cornerRadius: 12))
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func formatUTI(_ uti: String) -> String {
        let mapping: [String: String] = [
            "public.heic": "HEIC",
            "public.heif": "HEIF",
            "public.jpeg": "JPEG",
            "public.png": "PNG",
            "com.apple.quicktime-movie": "QuickTime MOV",
            "public.mpeg-4": "MP4",
            "com.compuserve.gif": "GIF",
            "public.tiff": "TIFF",
            "com.adobe.raw-image": "RAW",
        ]
        return mapping[uti] ?? uti
    }
}

// MARK: - Preview

#Preview {
    MediaInfoView(asset: PHAsset())
        .environment(PhotoLibraryService())
}
