import JaagaLayout
import JaagaProtocol
import SwiftUI

/// The window: sidebar, toolbar, one of the three views, and the inspector.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            VStack(spacing: 0) {
                ToolbarBar()
                HStack(spacing: 0) {
                    main
                    InspectorView()
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: Theme.minimumWindowSize.width, minHeight: Theme.minimumWindowSize.height)
        .background(Theme.windowBackground)
        .foregroundStyle(Theme.ink)
        .font(Theme.text(13))
        .overlay(alignment: .bottom) {
            if let message = model.errorMessage {
                ErrorBar(message: message)
            }
        }
        .overlay {
            switch model.connection {
            case .connecting:
                ConnectingOverlay()
            case .failed(let detail):
                ConnectionFailedOverlay(detail: detail)
            case .ready:
                if model.isQuickLookPresented, let report = model.quickLookReport {
                    QuickLookPanel(report: report)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.isQuickLookPresented)
    }

    private var main: some View {
        ScrollView(.vertical) {
            Group {
                switch model.view {
                case .spaceMap: SpaceMapView()
                case .suspects: SuspectsView()
                case .watched: WatchedView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Back, the breadcrumb, the last-scan time, Rescan and search.
private struct ToolbarBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            navigationButtons

            if model.view == .spaceMap {
                breadcrumb
            } else {
                Text(model.view == .suspects ? "Usual suspects" : "Watched folders")
                    .font(Theme.text(13, weight: .semibold))
                    .padding(.leading, 4)
            }

            Spacer(minLength: 8)
            status
            PillButton(title: "Rescan", systemImage: "arrow.clockwise") {
                Task { await model.reload(refresh: true) }
            }
            .disabled(model.isBusy)
            search
        }
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .frame(height: Theme.toolbarHeight)
    }

    private var navigationButtons: some View {
        HStack(spacing: 0) {
            Button { Task { await model.goBack() } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(model.canGoBack ? Theme.ink : Color.hex(0xC7C7CC))
                    .frame(width: 30, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back")

            Button {} label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.hex(0xC7C7CC))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(true)
        }
        .padding(.horizontal, 2)
        .frame(height: 32)
        .background(Theme.control, in: .capsule)
        .overlay { Capsule().strokeBorder(Theme.controlBorder, lineWidth: 1) }
    }

    private var breadcrumb: some View {
        ViewThatFits(in: .horizontal) {
            crumbs(model.breadcrumb)
            // Too narrow for the whole trail: keep the first and the last few, which is where the
            // useful jumps are, and mark the gap so the elision is visible rather than silent.
            crumbs(elided(model.breadcrumb, keepingLast: 3))
            crumbs(elided(model.breadcrumb, keepingLast: 2))
            crumbs(Array(model.breadcrumb.suffix(1)))
        }
    }

    private func elided(_ entries: [Entry], keepingLast count: Int) -> [Entry] {
        guard entries.count > count + 1 else { return entries }
        return [entries[0]] + entries.suffix(count)
    }

    private func crumbs(_ entries: [Entry]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(entries.enumerated()), id: \.element.path) { index, entry in
                let isLast = index == entries.count - 1
                // A gap opens whenever the trail was elided; the chevron alone would imply adjacency.
                let skipped = index > 0
                    && model.breadcrumb.count > entries.count
                    && entry.path != parentPath(of: entries[index])

                Button { Task { await model.goToBreadcrumb(entry) } } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.color(for: entry.category))
                            .frame(width: 8, height: 8)
                        Text(entry.name)
                            .font(Theme.text(13, weight: isLast ? .semibold : .regular))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(isLast ? Theme.control : .clear, in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(entry.path)

                if !isLast {
                    Image(systemName: skipped ? "ellipsis" : "chevron.right")
                        .font(.system(size: skipped ? 9 : 10, weight: .bold))
                        .foregroundStyle(Color.hex(0xAEAEB2))
                }
            }
        }
        .fixedSize()
    }

    private func parentPath(of entry: Entry) -> String {
        (entry.path as NSString).deletingLastPathComponent
    }

    /// While a scan runs this says what it is up to; otherwise how fresh the numbers are.
    private var status: some View {
        Group {
            if let progress = model.scanProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(
                        "Measuring \(Present.itemCount(progress.itemsScanned)) · "
                            + Present.size(progress.bytesScanned)
                    )
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.secondaryInk)
                    .monospacedDigit()
                }
            } else if let scanned = model.lastScanAt {
                Text("Scanned \(Present.elapsed(since: scanned))")
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .frame(minWidth: 0)
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
            TextField(
                "Search folders",
                text: Binding(get: { model.searchText }, set: { model.searchText = $0 })
            )
            .textFieldStyle(.plain)
            .font(Theme.text(13))
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryInk)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 220, height: 32)
        .background(Theme.control, in: .capsule)
        .overlay { Capsule().strokeBorder(Theme.controlBorder, lineWidth: 1) }
    }
}

private struct ConnectingOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Starting the Jaaga daemon…")
                .font(Theme.text(13, weight: .semibold))
            Text("It measures your folders in the background so this window only has to draw them.")
                .font(Theme.text(12))
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
    }
}

private struct ConnectionFailedOverlay: View {
    @Environment(AppModel.self) private var model
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.alertAccent)
            Text("Jaaga could not start its daemon")
                .font(Theme.text(15, weight: .bold))
            ScrollView {
                Text(detail)
                    .font(Theme.monospacedSmall)
                    .foregroundStyle(Theme.secondaryInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 520, maxHeight: 180)
            .padding(12)
            .background(Theme.tilePanel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("The README's “Running it” section covers both the LaunchAgent and the development fallback.")
                .font(Theme.text(12))
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            PillButton(title: "Try again", systemImage: "arrow.clockwise", isProminent: true) {
                Task { await model.connect() }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
    }
}

private struct ErrorBar: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.alertAccent)
            Text(message)
                .font(Theme.text(12))
                .foregroundStyle(Theme.alertTitleInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { model.dismissError() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.alertBodyInk)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 620)
        .background(Theme.alertBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.alertBorder.opacity(0.5), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
