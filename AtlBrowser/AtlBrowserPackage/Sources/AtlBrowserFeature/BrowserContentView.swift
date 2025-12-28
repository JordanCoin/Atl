import SwiftUI
import WebKit

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

#Preview {
    BrowserContentView()
        .environmentObject(BrowserController.shared)
}
