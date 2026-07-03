import SwiftUI

struct AboutTabView: View {
    @EnvironmentObject var libraryManager: LibraryManager

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 4)

                appInfoSection

                if !libraryManager.folders.isEmpty {
                    libraryStatisticsSection
                }

                footerSection

                Spacer(minLength: 4)
            }
            .padding()
        }
        .scrollDisabled(libraryManager.folders.isEmpty)
        .background(Color.clear)
    }

    // MARK: - App Info Section

    private var appInfoSection: some View {
        VStack(spacing: 12) {
            appIcon
            appDetails
        }
    }

    private var appIcon: some View {
        Group {
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
            } else {
                Image(systemName: "drop.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.accentColor)
            }
        }
    }

    private var appDetails: some View {
        VStack(spacing: 8) {
            Text(About.appTitle)
                .font(.title)
                .fontWeight(.bold)

            Text(AppInfo.version)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(About.appSubtitle)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Library Statistics Section

    private var libraryStatisticsSection: some View {
        VStack(spacing: 12) {
            Text("Library Statistics")
                .font(.headline)

            statisticsRow
        }
    }

    private var statisticsRow: some View {
        HStack(spacing: 30) {
            statisticItem(
                value: "\(libraryManager.folders.count)",
                label: "Folders"
            )

            statisticItem(
                value: "\(libraryManager.totalTrackCount)",
                label: "Tracks"
            )

            statisticItem(
                value: "\(libraryManager.artistCount)",
                label: "Artists"
            )

            statisticItem(
                value: "\(libraryManager.albumCount)",
                label: "Albums"
            )

            statisticItem(
                value: formatTotalDuration(),
                label: "Duration"
            )
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
    }

    private func statisticItem(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        HStack(spacing: 20) {
            FooterLink(
                icon: "folder",
                title: "App Data",
                action: {
                    let appDataURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                        .appendingPathComponent(Bundle.main.bundleIdentifier ?? About.bundleIdentifier)
                    
                    if let url = appDataURL {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                    }
                },
                tooltip: "Show app data directory in Finder"
            )
        }
    }
    
    private struct FooterLink: View {
        let icon: String
        let title: LocalizedStringKey
        var url: URL?
        var action: (() -> Void)?
        let tooltip: LocalizedStringKey
        
        @State private var isHovered = false
        
        var body: some View {
            if let url = url {
                Link(destination: url) {
                    linkContent
                }
                .buttonStyle(.plain)
                .help(tooltip)
            } else if let action = action {
                Button(action: action) {
                    linkContent
                }
                .buttonStyle(.plain)
                .help(tooltip)
            }
        }
        
        private var linkContent: some View {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundColor(isHovered ? .accentColor : .secondary)
            .underline(isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }

    private func formatTotalDuration() -> String {
        let duration = libraryManager.databaseManager.getTotalDuration()
        let totalSeconds = HelperUtils.sanitizedWholeDuration(duration)
        let totalHours = totalSeconds / 3600
        let days = totalHours / 24
        let remainingHours = totalHours % 24

        if days > 0 {
            return "\(days)d \(remainingHours)h"
        } else if totalHours > 0 {
            return "\(totalHours)h"
        } else {
            let minutes = totalSeconds / 60
            return "\(minutes)m"
        }
    }
}

#Preview {
    AboutTabView()
        .environmentObject(LibraryManager())
        .frame(width: 600, height: 500)
}
