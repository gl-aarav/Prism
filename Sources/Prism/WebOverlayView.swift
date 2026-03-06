import SwiftUI
import WebKit

// MARK: - Web Overlay View

struct WebOverlayView: View {
    @ObservedObject var manager: WebOverlayManager
    @State private var hoveredService: WebOverlayService?
    @AppStorage("WebOverlayBackgroundOpacity") private var backgroundOpacity: Double = 0.25
    @AppStorage("WebOverlayTintIntensity") private var tintIntensity: Double = 0.5
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @Environment(\.colorScheme) private var colorScheme

    private var clampedOpacity: Double {
        min(max(backgroundOpacity, 0.05), 1.0)
    }

    private var clampedTint: Double {
        min(max(tintIntensity, 0.0), 1.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Service picker bar
            serviceBar
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Web content — use ZStack to keep all webviews alive, only showing the active one
            ZStack {
                ForEach(manager.enabledServices) { service in
                    OverlayWebViewWrapper(
                        webView: manager.getWebView(for: service),
                        coordinator: manager.coordinator(for: service)
                    )
                    .opacity(manager.currentService == service ? 1 : 0)
                    .allowsHitTesting(manager.currentService == service)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background {
            overlayBackground
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .white.opacity(0.1), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        }
    }

    @ViewBuilder
    private var overlayBackground: some View {
        let colors = appTheme.colors
        let startColor = colors.first ?? .blue
        let endColor = colors.last ?? .green

        let baseDarkStart = 0.08
        let baseDarkEnd = 0.05
        let baseLightStart = 0.12
        let baseLightEnd = 0.08

        let gradient = LinearGradient(
            stops: [
                .init(
                    color: startColor.opacity(
                        (colorScheme == .dark ? baseDarkStart : baseLightStart)
                            * clampedTint * 2),
                    location: 0.0),
                .init(
                    color: endColor.opacity(
                        (colorScheme == .dark ? baseDarkEnd : baseLightEnd)
                            * clampedTint * 2),
                    location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(gradient)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .opacity(
                    colorScheme == .dark
                        ? clampedOpacity + 0.16
                        : clampedOpacity + 0.12
                )
        }
    }

    @ViewBuilder
    private var serviceBar: some View {
        HStack(spacing: 4) {
            ForEach(manager.enabledServices) { service in
                serviceButton(service)
            }

            Spacer()

            // Close button
            Button {
                manager.panel?.orderOut(nil)
                manager.returnFocusToPreviousApp()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                    )
                    .glassEffect(.regular, in: .circle)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func serviceButton(_ service: WebOverlayService) -> some View {
        let isSelected = manager.currentService == service
        let isHovered = hoveredService == service
        let themeColors = appTheme.colors

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                manager.switchService(service)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: service.icon)
                    .font(.system(size: 11, weight: .medium))
                if isSelected {
                    Text(service.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, isSelected ? 12 : 8)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: themeColors.map { $0.opacity(0.15) },
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .glassEffect(.regular, in: .capsule)
                                .opacity(0.7)
                        )
                } else if isHovered {
                    Capsule()
                        .fill(.quaternary.opacity(0.5))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredService = hovering ? service : nil
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

// MARK: - Overlay WebView Wrapper

struct OverlayWebViewWrapper: NSViewRepresentable {
    let webView: WKWebView
    let coordinator: WebOverlayCoordinator?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        if let coordinator = coordinator {
            webView.uiDelegate = coordinator
        }
        container.addSubview(webView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-attach webView if it was moved elsewhere
        if webView.superview !== nsView {
            webView.removeFromSuperview()
            webView.frame = nsView.bounds
            webView.autoresizingMask = [.width, .height]
            nsView.addSubview(webView)
        }
    }
}
