import SwiftUI
import WebKit
import SafariServices

/// Main browser view with WebView and minimal chrome
struct BrowserContentView: View {
    @EnvironmentObject private var controller: BrowserController
    @State private var urlText: String = ""
    @State private var showingURLBar: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // URL Bar (can be hidden for automation)
            if showingURLBar {
                urlBar
            }

            // WebView
            WebViewRepresentable(webView: controller.webView)
                .edgesIgnoringSafeArea(.bottom)

            // Status bar
            statusBar
        }
        .onAppear {
            urlText = controller.currentURL?.absoluteString ?? ""
        }
        .onChange(of: controller.currentURL) { _, newURL in
            urlText = newURL?.absoluteString ?? ""
        }
        // OAuth Popup Sheet (WKWebView-based)
        .sheet(isPresented: $controller.showPopup) {
            PopupWebViewSheet()
                .environmentObject(controller)
        }
        // Safari Login Sheet (for SSO that doesn't work in WKWebView)
        .fullScreenCover(isPresented: $controller.showSafariLogin) {
            if let url = controller.safariLoginURL {
                SafariLoginView(url: url) {
                    controller.safariLoginDidComplete()
                }
            }
        }
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            // Navigation buttons
            Button(action: { controller.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!controller.canGoBack)

            Button(action: { controller.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(!controller.canGoForward)

            Button(action: { controller.reload() }) {
                Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
            }

            // URL field
            TextField("Enter URL", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onSubmit {
                    navigateToURL()
                }

            // Go button
            Button("Go") {
                navigateToURL()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    private var statusBar: some View {
        HStack {
            if controller.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(controller.pageTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Server status indicator
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
            Text("Server: 9222")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }

    private func navigateToURL() {
        var urlString = urlText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Add https if no scheme
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "https://" + urlString
        }

        Task {
            try? await controller.goto(urlString)
        }
    }
}

// MARK: - WebView Representable

struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView.translatesAutoresizingMaskIntoConstraints = false
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No updates needed
    }
}

// MARK: - OAuth Popup Sheet

struct PopupWebViewSheet: View {
    @EnvironmentObject private var controller: BrowserController
    @State private var popupTitle: String = "Sign In"

    var body: some View {
        NavigationStack {
            Group {
                if let popupWebView = controller.popupWebView {
                    WebViewRepresentable(webView: popupWebView)
                } else {
                    ProgressView("Loading...")
                }
            }
            .navigationTitle(popupTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        controller.dismissPopup()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .popupTitleChanged)) { notification in
            if let title = notification.object as? String {
                popupTitle = title
            }
        }
        .interactiveDismissDisabled() // Prevent accidental dismiss during OAuth
    }
}

// Notification for popup title updates
extension Notification.Name {
    static let popupTitleChanged = Notification.Name("popupTitleChanged")
}

// MARK: - Safari Login View (for SSO)

/// Wraps SFSafariViewController for login flows where SSO is needed
struct SafariLoginView: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = false

        let safari = SFSafariViewController(url: url, configuration: config)
        safari.delegate = context.coordinator
        safari.dismissButtonStyle = .done
        return safari
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // No updates needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            print("Safari login finished by user")
            onDismiss()
        }
    }
}

#Preview {
    BrowserContentView()
        .environmentObject(BrowserController.shared)
}
