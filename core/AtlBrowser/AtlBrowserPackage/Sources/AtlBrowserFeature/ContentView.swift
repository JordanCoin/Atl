import SwiftUI

public struct ContentView: View {
    @StateObject private var browserController = BrowserController.shared

    public var body: some View {
        BrowserContentView()
            .environmentObject(browserController)
    }

    public init() {}
}
