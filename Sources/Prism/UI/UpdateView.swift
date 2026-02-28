import SwiftUI

// MARK: - Compact App Icon for Update View

private struct UpdateAppIcon: View {
    let theme: AppTheme
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        let cornerRadius = size * 0.24

        ZStack {
            // Dark inset border (like macOS icon bezel)
            RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous)
                .fill(Color.black.opacity(0.6))
                .frame(width: size + 8, height: size + 8)

            // Main squircle with theme gradient
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: theme.colors),
                        center: .center,
                        startRadius: 0,
                        endRadius: size
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: theme.colors.first?.opacity(0.5) ?? .clear, radius: 20, y: 8)

            // Prism triangle
            Canvas { context, canvasSize in
                let w = canvasSize.width
                var triangle = Path()
                triangle.move(to: CGPoint(x: w * 0.5, y: w * 0.17))
                triangle.addLine(to: CGPoint(x: w * 0.195, y: w * 0.756))
                triangle.addLine(to: CGPoint(x: w * 0.805, y: w * 0.756))
                triangle.closeSubpath()

                // Fill
                context.fill(
                    triangle,
                    with: .color(isDark ? .black.opacity(0.3) : .white.opacity(0.2))
                )

                // Stroke
                context.stroke(
                    triangle,
                    with: .color(isDark ? .black : .white),
                    style: StrokeStyle(lineWidth: w * 0.04, lineCap: .round, lineJoin: .round)
                )

                // Center shine line
                var shine = Path()
                shine.move(to: CGPoint(x: w * 0.5, y: w * 0.17))
                shine.addLine(to: CGPoint(x: w * 0.5, y: w * 0.756))
                context.stroke(
                    shine,
                    with: .color(isDark ? .black.opacity(0.5) : .white.opacity(0.4)),
                    style: StrokeStyle(lineWidth: w * 0.01, lineCap: .round)
                )
            }
            .frame(width: size, height: size)

            // Gloss highlight on top
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.15), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Floating Particle

private struct FloatingParticle: View {
    let themeColors: [Color]
    let index: Int
    @State private var offset: CGSize = .zero
    @State private var opacity: Double = 0

    var body: some View {
        let particleSize = CGFloat(2 + index % 3)

        Circle()
            .fill(themeColors[index % themeColors.count].opacity(0.5))
            .frame(width: particleSize, height: particleSize)
            .blur(radius: CGFloat(index % 2))
            .offset(offset)
            .opacity(opacity)
            .onAppear {
                let baseX = CGFloat.random(in: -200...200)
                let baseY = CGFloat.random(in: -200...200)
                offset = CGSize(width: baseX, height: baseY)

                withAnimation(
                    .easeInOut(duration: Double.random(in: 1.5...3.0)).delay(Double(index) * 0.08)
                ) {
                    opacity = Double.random(in: 0.3...0.8)
                }
                withAnimation(
                    .easeInOut(duration: Double.random(in: 4...8))
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.1)
                ) {
                    offset = CGSize(
                        width: baseX + CGFloat.random(in: -30...30),
                        height: baseY + CGFloat.random(in: -30...30)
                    )
                }
            }
    }
}

// MARK: - Update View

struct UpdateView: View {
    @ObservedObject var updateManager = UpdateManager.shared
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @Environment(\.colorScheme) private var colorScheme

    @State private var iconScale: CGFloat = 0.5
    @State private var iconOpacity: Double = 0
    @State private var contentOpacity: Double = 0
    @State private var backgroundPulse: CGFloat = 0.8

    var body: some View {
        ZStack {
            // Deep dark background with theme-tinted gradient
            backgroundLayer

            // Floating particles
            ForEach(0..<18, id: \.self) { i in
                FloatingParticle(themeColors: themeColors, index: i)
            }

            // Main content
            VStack(spacing: 0) {
                Spacer()

                // App icon
                UpdateAppIcon(theme: appTheme, size: 140)
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)

                Spacer().frame(height: 20)

                // Version badge or status
                versionBadge
                    .opacity(contentOpacity)

                Spacer().frame(height: 16)

                // Status text
                statusText
                    .opacity(contentOpacity)

                // Release notes (compact, only when update available)
                if updateManager.updateAvailable && !updateManager.releaseNotes.isEmpty {
                    releaseNotesSection
                        .opacity(contentOpacity)
                        .padding(.top, 12)
                }

                // Download progress
                if updateManager.isDownloading {
                    downloadProgressBar
                        .opacity(contentOpacity)
                        .padding(.top, 16)
                }

                // Chrome extension update (independent of app update)
                if updateManager.chromeUpdateAvailable {
                    chromeExtensionSection
                        .opacity(contentOpacity)
                        .padding(.top, 12)
                }

                Spacer()

                // Action buttons
                actionButtons
                    .opacity(contentOpacity)

                Spacer().frame(height: 28)
            }
            .padding(.horizontal, 36)
        }
        .frame(width: 500, height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.1)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.6).delay(0.35)) {
                contentOpacity = 1.0
            }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                backgroundPulse = 1.1
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            // Base dark color
            Color(red: 0.08, green: 0.08, blue: 0.14)

            // Theme-colored radial glow behind icon
            RadialGradient(
                colors: [
                    themeColors.first?.opacity(0.18) ?? .clear,
                    themeColors.last?.opacity(0.06) ?? .clear,
                    .clear,
                ],
                center: .init(x: 0.5, y: 0.35),
                startRadius: 20,
                endRadius: 300
            )
            .scaleEffect(backgroundPulse)

            // Subtle diagonal accent streak
            LinearGradient(
                colors: [
                    .clear,
                    themeColors.first?.opacity(0.04) ?? .clear,
                    themeColors.last?.opacity(0.08) ?? .clear,
                    .clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Vignette
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.3)],
                center: .center,
                startRadius: 100,
                endRadius: 350
            )

            // Top border highlight
            VStack {
                LinearGradient(
                    colors: [themeColors.first?.opacity(0.2) ?? .clear, .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 1)
                Spacer()
            }
        }
    }

    // MARK: - Version Badge

    @ViewBuilder
    private var versionBadge: some View {
        if updateManager.isChecking {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.7))
        } else if updateManager.updateAvailable {
            HStack(spacing: 8) {
                Text(updateManager.latestVersion)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))

                if updateManager.isPreRelease {
                    Text("PRE")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [.orange, .red],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
        } else {
            Text(updateManager.currentVersion)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
        }
    }

    // MARK: - Status Text

    @ViewBuilder
    private var statusText: some View {
        if updateManager.isChecking {
            Text("Checking for updates\u{2026}")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        } else if updateManager.updateAvailable {
            if updateManager.downloadedFileURL != nil {
                Text("Ready to install")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.green.opacity(0.9))
            } else if updateManager.isDownloading {
                Text("Downloading Prism v\(updateManager.latestVersion)\u{2026}")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text("A new version of Prism is available")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        } else if updateManager.errorMessage != nil {
            Text(updateManager.errorMessage!)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.red.opacity(0.8))
                .multilineTextAlignment(.center)
        } else {
            Text("Prism is up to date")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - Release Notes

    @ViewBuilder
    private var releaseNotesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                Text("What's New")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(themeColors.first ?? .white)

            ScrollView {
                Text(updateManager.releaseNotes)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 70)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
        }
    }

    // MARK: - Download Progress

    @ViewBuilder
    private var downloadProgressBar: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: themeColors,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: geo.size.width * max(updateManager.downloadProgress, 0.02),
                            height: 6
                        )
                        .animation(.easeInOut(duration: 0.3), value: updateManager.downloadProgress)
                        .shadow(color: themeColors.first?.opacity(0.6) ?? .clear, radius: 6, y: 1)
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(Int(updateManager.downloadProgress * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(themeColors.first ?? .white)
                Spacer()
                Button {
                    updateManager.cancelDownload()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Chrome Extension

    @ViewBuilder
    private var chromeExtensionSection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(themeColors.first ?? .white)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Chrome Extension")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                        if !updateManager.latestChromeVersion.isEmpty {
                            Text("v\(updateManager.latestChromeVersion)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }

                    if updateManager.chromeExtensionPath.isEmpty {
                        Text("Set folder in Settings")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.7))
                    } else if updateManager.chromeExtensionUpdated {
                        Text("Updated \u{2014} reload in chrome://extensions")
                            .font(.system(size: 9))
                            .foregroundStyle(.green.opacity(0.8))
                    } else if updateManager.isDownloadingChrome {
                        Text("\(Int(updateManager.chromeDownloadProgress * 100))%")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(themeColors.first ?? .white)
                    }
                }

                Spacer()

                if updateManager.chromeExtensionUpdated {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 14))
                } else if updateManager.isDownloadingChrome {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.5))
                } else {
                    Button {
                        updateManager.downloadChromeExtension()
                    } label: {
                        Text("Update")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(Color.white.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(updateManager.chromeExtensionPath.isEmpty)
                }
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    )
            }

            if let err = updateManager.chromeErrorMessage {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.7))
            }
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        if updateManager.isChecking {
            EmptyView()
        } else if updateManager.updateAvailable {
            if updateManager.downloadedFileURL != nil {
                twoButtonRow(
                    secondaryLabel: "Remind Later...",
                    primaryLabel: "Install & Restart",
                    primaryAction: { updateManager.installAndRestart() }
                )
            } else if updateManager.isDownloading {
                EmptyView()
            } else {
                twoButtonRow(
                    secondaryLabel: "Remind Later...",
                    primaryLabel: "Download Update",
                    primaryAction: { updateManager.downloadUpdate() }
                )
            }
        } else if updateManager.errorMessage != nil {
            singleButton(label: "Try Again", filled: true) {
                Task { await updateManager.checkForUpdates() }
            }
        } else {
            singleButton(label: "Check Again", filled: false) {
                Task { await updateManager.checkForUpdates() }
            }
        }
    }

    @ViewBuilder
    private func twoButtonRow(
        secondaryLabel: String, primaryLabel: String, primaryAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                updateManager.dismiss()
                NSApp.windows.first(where: { $0.title == "Software Update" })?.close()
            } label: {
                Text(secondaryLabel)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    }
            }
            .buttonStyle(.plain)

            Button(action: primaryAction) {
                Text(primaryLabel)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: themeColors,
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .shadow(
                                color: themeColors.first?.opacity(0.4) ?? .clear, radius: 12, y: 4)
                    }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func singleButton(label: String, filled: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: filled ? .semibold : .medium, design: .rounded))
                .foregroundStyle(.white.opacity(filled ? 1.0 : 0.7))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background {
                    if filled {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: themeColors,
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Theme

    private var themeColors: [Color] {
        let c = appTheme.colors
        return c.isEmpty ? [.blue, .cyan, .green] : c
    }
}
