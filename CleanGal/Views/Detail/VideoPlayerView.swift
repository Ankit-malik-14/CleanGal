import SwiftUI
import AVKit
import Photos

struct VideoPlayerView: View {
    let asset: PHAsset
    let isActive: Bool
    @Binding var showControls: Bool

    @Environment(PhotoLibraryService.self) private var photoService
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black

            if let player {
                VideoPlayer(player: player)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls.toggle()
                        }
                    }
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .task(id: asset.localIdentifier) {
            if let playerItem = await photoService.loadPlayerItem(for: asset) {
                let avPlayer = AVPlayer(playerItem: playerItem)
                player = avPlayer
                if isActive {
                    avPlayer.play()
                }
            }
        }
        .onChange(of: isActive) { _, newValue in
            if newValue {
                player?.play()
            } else {
                player?.pause()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
