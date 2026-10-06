# CleanGal Project Tracker

## Project Overview
CleanGal is a native iOS gallery cleaner app designed to handle large photo libraries smoothly using modern SwiftUI, MVVM architecture, and `@Observable`.

---

## 🏗 Project Architecture & Structure

```text
CleanGal/
├── CleanGal/
│   ├── App/
│   │   └── CleanGalApp.swift            # Main app entry point with PhotoLibraryService injection
│   ├── Extensions/
│   │   └── PHAsset+Extensions.swift     # Identifiable & formatted duration helpers for PHAsset
│   ├── Resources/
│   │   └── Assets.xcassets/             # App icons & image catalog
│   ├── Services/
│   │   ├── DuplicateDetector.swift      # Industry-standard 2-pass duplicate detection service (SHA256 fingerprinting)
│   │   └── PhotoLibraryService.swift    # @Observable photo library manager (fetching, caching, EXIF, deletion)
│   ├── ViewModels/
│   │   └── LibraryViewModel.swift       # @Observable UI view model for selection, grid zooming & navigation
│   └── Views/
│       ├── Albums/
│       │   └── AlbumsView.swift         # Albums tab container featuring Duplicate Images, Duplicate Videos & Recently Deleted
│       ├── Components/
│       │   ├── ShareSheet.swift         # UIActivityViewController wrapper for system sharing
│       │   └── ThumbnailView.swift      # High-performance grid cell thumbnail with video duration badge
│       ├── Detail/
│       │   ├── MediaDetailView.swift    # Fullscreen horizontal paging viewer with native zoom navigation transition
│       │   ├── MediaInfoView.swift      # EXIF metadata inspector & location map sheet
│       │   ├── VideoPlayerView.swift    # AVPlayer container for native video playback
│       │   └── ZoomableImageView.swift  # Double-tap & pinch zoomable image container
│       ├── Library/
│       │   └── LibraryView.swift        # Recency grid view grouped by date with selection & pinch-to-zoom
│       └── ContentView.swift            # Main app container with Library and Albums TabView navigation
├── CleanGal.xcodeproj/                  # Xcode project configuration
└── project.yml                          # Project configuration schema
```

---

## 📋 Features & Status

### Phase 1: Native Library Landing Page (Completed ✅)
- **Recency-ordered Date Grid**: Photos and videos arranged in continuous date sections with recency ordering and automatic scroll-to-bottom.
- **Async & Cached Media Loading**: Built using `PHCachingImageManager` to guarantee non-blocking UI and smooth performance over thousands of gallery items.
- **Dynamic Pinch-to-Zoom Grid**: Interactive grid scaling from 1 to 7 columns via gestures.
- **Selection & Bulk Actions**: Select individual or all assets, share via native `UIActivityViewController`, and move items to iOS "Recently Deleted".
- **Fullscreen Detail Viewer**: Horizontal paging gallery with single-tap control toggling and smooth native zoom transitions (`navigationTransition(.zoom)`).
- **Native Video Player**: Integrated `AVPlayer` with runtime duration overlays on grid thumbnails.
- **Comprehensive EXIF Inspector**: Custom detail view extracting camera make/model, lens, focal length, aperture, shutter speed, ISO, megapixels, resolution, file size, format, date, and interactive MapKit location marker.
- **Photo Permissions Flow**: Fully compliant iOS permission request and denied state UI flows.

### Phase 2: Duplicate Detection (Completed ✅)
- **Duplicate Images Album**: Dedicated album in **Albums** tab showing exact copy photo groups.
- **Duplicate Videos Album**: Dedicated album in **Albums** tab showing exact copy video groups.
- **Industry Standard 2-Pass Engine**: [`DuplicateDetector.swift`](file:///Users/mymac/CleanGal/CleanGal/Services/DuplicateDetector.swift) combining structural dimension/duration bucketing with CryptoKit `SHA256` byte-stream fingerprinting.

---

## 🔮 Planned Primary Features (Upcoming)
1. **Auto-Classification into Albums** *(Screenshots, Videos, Selfies, etc.)*
2. **Similar Photos Identification** *(Different angles / perspectives)*
3. **Large Videos Cleanup Section** *(Sorted descending by size)*
