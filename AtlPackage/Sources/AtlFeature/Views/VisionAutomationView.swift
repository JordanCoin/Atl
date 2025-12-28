import SwiftUI

// MARK: - Vision Automation View

/// Visual automation builder powered by vision AI
public struct VisionAutomationView: View {
    @StateObject private var viewModel = VisionAutomationViewModel()
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            HSplitView {
                // Left: Recording Panel
                RecordingPanel(viewModel: viewModel)
                    .frame(minWidth: 350, maxWidth: 450)

                // Right: Saved Automations
                SavedAutomationsPanel(viewModel: viewModel)
                    .frame(minWidth: 250)
            }
            .frame(minWidth: 700, minHeight: 500)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationTitle("Vision Automation")
            .sheet(isPresented: $viewModel.showingSettings) {
                SettingsSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showingEditAutomation) {
                if let automation = viewModel.editingAutomation {
                    EditAutomationSheet(
                        automation: automation,
                        onSave: { viewModel.saveAutomation($0) },
                        onCancel: { viewModel.showingEditAutomation = false }
                    )
                }
            }
        }
    }
}

// MARK: - Recording Panel

struct RecordingPanel: View {
    @ObservedObject var viewModel: VisionAutomationViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Record Actions")
                    .font(.headline)
                Spacer()

                // Simulator picker
                Picker("", selection: $viewModel.selectedSimulatorUDID) {
                    Text("Select Simulator").tag(nil as String?)
                    ForEach(viewModel.simulators, id: \.udid) { sim in
                        Text("\(sim.name) \(sim.state == "Booted" ? "(Booted)" : "")")
                            .tag(sim.udid as String?)
                    }
                }
                .frame(width: 180)

                Button {
                    Task { await viewModel.refreshSimulators() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            // Screenshot Preview
            ScreenshotPreview(viewModel: viewModel)
                .frame(height: 300)

            Divider()

            // Click Target Input
            VStack(alignment: .leading, spacing: 12) {
                Text("What do you want to click?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("e.g., 'the cart button', 'search box', 'menu icon'", text: $viewModel.clickTargetDescription)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        Task { await viewModel.findAndClick() }
                    } label: {
                        if viewModel.isProcessing {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text("Find & Click")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.clickTargetDescription.isEmpty || viewModel.selectedSimulatorUDID == nil || viewModel.isProcessing)
                }

                // AI Response
                if let response = viewModel.lastResponse {
                    VisionResponseView(response: response)
                }

                // Error
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()

            Divider()

            // Current Recording
            CurrentRecordingView(viewModel: viewModel)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Screenshot Preview

struct ScreenshotPreview: View {
    @ObservedObject var viewModel: VisionAutomationViewModel

    var body: some View {
        ZStack {
            if let imageData = viewModel.currentScreenshot,
               let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay {
                        // Show click target if found
                        if let response = viewModel.lastResponse, response.found {
                            ClickTargetOverlay(x: response.x, y: response.y, imageSize: nsImage.size)
                        }
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)

                    Text("No Screenshot")
                        .foregroundStyle(.secondary)

                    Button("Capture Screenshot") {
                        Task { await viewModel.captureScreenshot() }
                    }
                    .disabled(viewModel.selectedSimulatorUDID == nil)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.1))
    }
}

struct ClickTargetOverlay: View {
    let x: Int
    let y: Int
    let imageSize: NSSize

    var body: some View {
        GeometryReader { geometry in
            let scaleX = geometry.size.width / imageSize.width
            let scaleY = geometry.size.height / imageSize.height
            let scale = min(scaleX, scaleY)

            let offsetX = (geometry.size.width - imageSize.width * scale) / 2
            let offsetY = (geometry.size.height - imageSize.height * scale) / 2

            let targetX = offsetX + CGFloat(x) * scale
            let targetY = offsetY + CGFloat(y) * scale

            Circle()
                .stroke(Color.red, lineWidth: 3)
                .frame(width: 40, height: 40)
                .position(x: targetX, y: targetY)

            Circle()
                .fill(Color.red.opacity(0.3))
                .frame(width: 40, height: 40)
                .position(x: targetX, y: targetY)
        }
    }
}

// MARK: - Vision Response View

struct VisionResponseView: View {
    let response: VisionClickResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: response.found ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(response.found ? .green : .red)

                Text(response.found ? "Found: \(response.elementDescription)" : "Not Found")
                    .font(.subheadline.bold())

                Spacer()

                if response.found {
                    Text("(\(response.x), \(response.y))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Text("\(Int(response.confidence * 100))%")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(confidenceColor.opacity(0.2))
                        .foregroundStyle(confidenceColor)
                        .cornerRadius(4)
                }
            }

            Text(response.reasoning)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    var confidenceColor: Color {
        if response.confidence >= 0.8 { return .green }
        if response.confidence >= 0.5 { return .orange }
        return .red
    }
}

// MARK: - Current Recording View

struct CurrentRecordingView: View {
    @ObservedObject var viewModel: VisionAutomationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Current Recording")
                    .font(.subheadline.bold())

                Spacer()

                Text("\(viewModel.currentSteps.count) steps")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.clearCurrentRecording()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.currentSteps.isEmpty)
            }

            if viewModel.currentSteps.isEmpty {
                Text("No steps recorded yet. Use 'Find & Click' to add steps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(viewModel.currentSteps.enumerated()), id: \.element.id) { index, step in
                            RecordedStepRow(step: step, index: index) {
                                viewModel.deleteStep(at: index)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)

                HStack {
                    TextField("Automation name", text: $viewModel.automationName)
                        .textFieldStyle(.roundedBorder)

                    Button("Save Automation") {
                        viewModel.saveCurrentRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.currentSteps.isEmpty || viewModel.automationName.isEmpty)
                }
            }
        }
        .padding()
    }
}

struct RecordedStepRow: View {
    let step: RecordedStep
    let index: Int
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Image(systemName: step.action.icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)

            Text(step.action.displayName)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer()

            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(4)
    }
}

// MARK: - Saved Automations Panel

struct SavedAutomationsPanel: View {
    @ObservedObject var viewModel: VisionAutomationViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Saved Automations")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            if viewModel.savedAutomations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)

                    Text("No saved automations")
                        .foregroundStyle(.secondary)

                    Text("Record actions and save them to create reusable automations.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.savedAutomations) { automation in
                        SavedAutomationRow(
                            automation: automation,
                            isRunning: viewModel.runningAutomationId == automation.id,
                            onRun: { Task { await viewModel.runAutomation(automation) } },
                            onEdit: { viewModel.editAutomation(automation) },
                            onDelete: { viewModel.deleteAutomation(automation) }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

struct SavedAutomationRow: View {
    let automation: RecordedAutomation
    let isRunning: Bool
    let onRun: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(automation.name)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                if isRunning {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            HStack {
                Text("\(automation.steps.count) steps")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onRun()
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(isRunning)

                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Sheet

struct SettingsSheet: View {
    @ObservedObject var viewModel: VisionAutomationViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Vision AI Settings")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: viewModel.isVisionAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(viewModel.isVisionAvailable ? .green : .red)
                        .font(.title2)

                    VStack(alignment: .leading) {
                        Text("Foundation Models")
                            .font(.headline)
                        Text(viewModel.isVisionAvailable ? "Available" : "Requires macOS 26+")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label("On-device processing", systemImage: "cpu")
                    Label("No API key required", systemImage: "key.slash")
                    Label("Privacy-preserving", systemImage: "lock.shield")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 350, height: 280)
    }
}

// MARK: - Edit Automation Sheet

struct EditAutomationSheet: View {
    @State var automation: RecordedAutomation
    let onSave: (RecordedAutomation) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Automation")
                .font(.title2.bold())

            TextField("Name", text: $automation.name)
                .textFieldStyle(.roundedBorder)

            TextField("Description", text: $automation.description)
                .textFieldStyle(.roundedBorder)

            Text("Steps")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            List {
                ForEach(automation.steps) { step in
                    HStack {
                        Image(systemName: step.action.icon)
                        Text(step.action.displayName)
                        Spacer()
                    }
                }
                .onMove { from, to in
                    automation.steps.move(fromOffsets: from, toOffset: to)
                }
                .onDelete { offsets in
                    automation.steps.remove(atOffsets: offsets)
                }
            }
            .frame(height: 200)

            HStack {
                Button("Cancel") {
                    onCancel()
                }

                Spacer()

                Button("Save") {
                    onSave(automation)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 450, height: 450)
    }
}

// MARK: - View Model

@MainActor
class VisionAutomationViewModel: ObservableObject {
    @Published var simulators: [SimulatorManager.SimulatorInfo] = []
    @Published var selectedSimulatorUDID: String?
    @Published var currentScreenshot: Data?
    @Published var clickTargetDescription = ""
    @Published var lastResponse: VisionClickResponse?
    @Published var isProcessing = false
    @Published var errorMessage: String?

    @Published var currentSteps: [RecordedStep] = []
    @Published var automationName = ""

    @Published var savedAutomations: [RecordedAutomation] = []
    @Published var runningAutomationId: UUID?

    @Published var showingSettings = false
    @Published var showingEditAutomation = false
    @Published var editingAutomation: RecordedAutomation?

    private let visionService = VisionService.shared
    private let storage = AutomationStorage.shared

    var isVisionAvailable: Bool { visionService.isAvailable }

    init() {
        Task {
            await refreshSimulators()
        }
        savedAutomations = storage.automations
    }

    func refreshSimulators() async {
        simulators = await SimulatorManager.shared.fetchSimulators()
        if selectedSimulatorUDID == nil {
            selectedSimulatorUDID = simulators.first(where: { $0.state == "Booted" })?.udid
                ?? simulators.first?.udid
        }
    }

    func captureScreenshot() async {
        guard let udid = selectedSimulatorUDID else { return }

        isProcessing = true
        errorMessage = nil

        if let data = await visionService.captureSimulatorScreenshot(udid: udid) {
            currentScreenshot = data
        } else {
            errorMessage = "Failed to capture screenshot"
        }

        isProcessing = false
    }

    func findAndClick() async {
        guard let udid = selectedSimulatorUDID else {
            errorMessage = "No simulator selected"
            return
        }

        guard !clickTargetDescription.isEmpty else {
            errorMessage = "Please describe what to click"
            return
        }

        guard isVisionAvailable else {
            errorMessage = "Foundation Models requires macOS 26 or later"
            showingSettings = true
            return
        }

        isProcessing = true
        errorMessage = nil

        // Capture fresh screenshot
        if let data = await visionService.captureSimulatorScreenshot(udid: udid) {
            currentScreenshot = data

            // Ask vision AI to find the target
            let response = await visionService.findClickTarget(
                screenshot: data,
                targetDescription: clickTargetDescription
            )

            lastResponse = response

            if response.found {
                // Execute the click using AXe
                await executeTap(udid: udid, x: response.x, y: response.y)

                // Record the step
                let step = RecordedStep(
                    action: .tap(x: response.x, y: response.y, label: clickTargetDescription),
                    description: "Tap on \(response.elementDescription)",
                    screenshotData: data
                )
                currentSteps.append(step)

                // Clear input for next action
                clickTargetDescription = ""

                // Capture new screenshot after action
                try? await Task.sleep(nanoseconds: 500_000_000)
                await captureScreenshot()
            } else {
                errorMessage = "Could not find: \(clickTargetDescription)"
            }
        } else {
            errorMessage = "Failed to capture screenshot"
        }

        isProcessing = false
    }

    private func executeTap(udid: String, x: Int, y: Int) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/axe")
        process.arguments = ["tap", "--udid", udid, "-x", "\(x)", "-y", "\(y)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Tap failed: \(error)")
        }
    }

    func deleteStep(at index: Int) {
        guard index < currentSteps.count else { return }
        currentSteps.remove(at: index)
    }

    func clearCurrentRecording() {
        currentSteps = []
        automationName = ""
        lastResponse = nil
    }

    func saveCurrentRecording() {
        guard !currentSteps.isEmpty, !automationName.isEmpty else { return }

        let automation = RecordedAutomation(
            name: automationName,
            steps: currentSteps
        )

        storage.save(automation)
        savedAutomations = storage.automations

        clearCurrentRecording()
    }

    func editAutomation(_ automation: RecordedAutomation) {
        editingAutomation = automation
        showingEditAutomation = true
    }

    func saveAutomation(_ automation: RecordedAutomation) {
        storage.save(automation)
        savedAutomations = storage.automations
        showingEditAutomation = false
        editingAutomation = nil
    }

    func deleteAutomation(_ automation: RecordedAutomation) {
        storage.delete(automation)
        savedAutomations = storage.automations
    }

    func runAutomation(_ automation: RecordedAutomation) async {
        guard let udid = selectedSimulatorUDID else {
            errorMessage = "No simulator selected"
            return
        }

        runningAutomationId = automation.id

        for step in automation.steps {
            switch step.action {
            case .tap(let x, let y, _):
                await executeTap(udid: udid, x: x, y: y)
            case .type(let text):
                await executeType(udid: udid, text: text)
            case .scroll(let direction, _):
                await executeScroll(udid: udid, direction: direction)
            case .wait(let seconds):
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            case .navigate(let url):
                await executeNavigate(udid: udid, url: url)
            case .pressButton(let button):
                await executeButton(udid: udid, button: button)
            case .gesture(let preset):
                await executeGesture(udid: udid, preset: preset)
            }

            // Wait between steps
            try? await Task.sleep(nanoseconds: UInt64(step.waitAfter * 1_000_000_000))
        }

        // Capture final screenshot
        await captureScreenshot()
        runningAutomationId = nil
    }

    private func executeType(udid: String, text: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/axe")
        process.arguments = ["type", "--udid", udid, text]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func executeScroll(udid: String, direction: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/axe")
        process.arguments = ["gesture", "--udid", udid, "scroll-\(direction)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func executeNavigate(udid: String, url: String) async {
        await SimulatorManager.shared.openSafari(udid: udid, url: url)
    }

    private func executeButton(udid: String, button: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/axe")
        process.arguments = ["button", "--udid", udid, button]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func executeGesture(udid: String, preset: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/axe")
        process.arguments = ["gesture", "--udid", udid, preset]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - Preview

#Preview {
    VisionAutomationView()
        .frame(width: 800, height: 600)
}
