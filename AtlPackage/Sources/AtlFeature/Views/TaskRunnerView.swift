import SwiftUI

// MARK: - Task Runner View

/// Main view for selecting and running automation tasks on simulators
public struct TaskRunnerView: View {
    @StateObject private var viewModel = TaskRunnerViewModel()
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            HSplitView {
                // Left: Task Selection
                TaskSelectionPanel(viewModel: viewModel)
                    .frame(minWidth: 280, maxWidth: 350)

                // Right: Simulator Selection & Execution
                VStack(spacing: 0) {
                    SimulatorSelectionPanel(viewModel: viewModel)

                    Divider()

                    ExecutionPanel(viewModel: viewModel)
                }
                .frame(minWidth: 400)
            }
            .frame(minWidth: 700, minHeight: 500)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await viewModel.runSelectedTask()
                        }
                    } label: {
                        Label("Run Task", systemImage: "play.fill")
                    }
                    .disabled(!viewModel.canRun)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .navigationTitle("Task Runner")
        }
    }
}

// MARK: - Task Selection Panel

struct TaskSelectionPanel: View {
    @ObservedObject var viewModel: TaskRunnerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Tasks")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(TaskCategory.allCases, id: \.self) { category in
                        Button {
                            viewModel.filterCategory = category
                        } label: {
                            Label(category.rawValue, systemImage: category.icon)
                        }
                    }
                    Divider()
                    Button("All Categories") {
                        viewModel.filterCategory = nil
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
            }
            .padding()

            Divider()

            // Task List
            List(selection: $viewModel.selectedTask) {
                ForEach(viewModel.filteredTasks) { task in
                    TaskRow(task: task, isSelected: viewModel.selectedTask == task)
                        .tag(task)
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct TaskRow: View {
    let task: AutomationTask
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.icon)
                .font(.title2)
                .foregroundStyle(isSelected ? .white : .accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.system(size: 13, weight: .medium))

                Text(task.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: task.category.icon)
                        .font(.system(size: 9))
                    Text(task.category.rawValue)
                        .font(.system(size: 9))
                    Text("•")
                        .font(.system(size: 9))
                    Text("\(task.steps.count) steps")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Simulator Selection Panel

struct SimulatorSelectionPanel: View {
    @ObservedObject var viewModel: TaskRunnerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Simulators")
                    .font(.headline)
                Spacer()
                Button {
                    Task {
                        await viewModel.refreshSimulators()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            // Simulator Grid
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)
                ], spacing: 12) {
                    ForEach(viewModel.simulators) { simulator in
                        SimulatorCard(
                            simulator: simulator,
                            isSelected: viewModel.selectedSimulators.contains(simulator)
                        ) {
                            viewModel.toggleSimulator(simulator)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minHeight: 200)
    }
}

struct SimulatorCard: View {
    let simulator: SimulatorInfo
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        )

                    VStack(spacing: 8) {
                        Image(systemName: "iphone")
                            .font(.system(size: 32))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                        VStack(spacing: 2) {
                            Text(simulator.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)

                            HStack(spacing: 4) {
                                Circle()
                                    .fill(simulator.state == "Booted" ? Color.green : Color.orange)
                                    .frame(width: 6, height: 6)
                                Text(simulator.state)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(height: 100)
    }
}

// MARK: - Execution Panel

struct ExecutionPanel: View {
    @ObservedObject var viewModel: TaskRunnerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Execution")
                    .font(.headline)

                Spacer()

                if viewModel.isRunning {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding()

            Divider()

            // Variables Input
            if let task = viewModel.selectedTask, !task.steps.isEmpty {
                VariablesSection(task: task, variables: $viewModel.variables)
            }

            // Execution Log
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if viewModel.executionLog.isEmpty {
                        Text("Select a task and simulators, then click Run")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    } else {
                        ForEach(viewModel.executionLog, id: \.self) { log in
                            LogEntryRow(log: log)
                        }
                    }
                }
                .padding()
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct VariablesSection: View {
    let task: AutomationTask
    @Binding var variables: [String: String]

    var requiredVariables: [String] {
        var vars: Set<String> = []
        for step in task.steps {
            extractVariables(from: step.action, into: &vars)
        }
        return Array(vars).sorted()
    }

    var body: some View {
        if !requiredVariables.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Variables")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(requiredVariables, id: \.self) { variable in
                    HStack {
                        Text(variable)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 100, alignment: .trailing)

                        TextField("Value", text: Binding(
                            get: { variables[variable] ?? "" },
                            set: { variables[variable] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    }
                }
            }
            .padding()

            Divider()
        }
    }

    private func extractVariables(from action: TaskAction, into vars: inout Set<String>) {
        let pattern = /\{\{(\w+)\}\}/

        func check(_ text: String) {
            for match in text.matches(of: pattern) {
                vars.insert(String(match.1))
            }
        }

        switch action {
        case .goto(let url):
            check(url)
        case .type(let text):
            check(text)
        case .fill(_, let value):
            check(value)
        case .evaluate(let script, _):
            check(script)
        default:
            break
        }
    }
}

struct LogEntryRow: View {
    let log: ExecutionLog

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: log.icon)
                .foregroundStyle(log.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(log.message)
                    .font(.system(size: 12))

                if let detail = log.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(log.timestamp, style: .time)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - View Model

@MainActor
class TaskRunnerViewModel: ObservableObject {
    @Published var tasks: [AutomationTask] = BuiltInTasks.all
    @Published var simulators: [SimulatorInfo] = []
    @Published var selectedTask: AutomationTask?
    @Published var selectedSimulators: Set<SimulatorInfo> = []
    @Published var variables: [String: String] = [:]
    @Published var filterCategory: TaskCategory?
    @Published var isRunning = false
    @Published var executionLog: [ExecutionLog] = []

    var filteredTasks: [AutomationTask] {
        guard let category = filterCategory else { return tasks }
        return tasks.filter { $0.category == category }
    }

    var canRun: Bool {
        selectedTask != nil && !selectedSimulators.isEmpty && !isRunning
    }

    init() {
        Task {
            await refreshSimulators()
        }
    }

    func refreshSimulators() async {
        let sims = await SimulatorManager.shared.fetchSimulators()
        simulators = sims.map { sim in
            SimulatorInfo(
                udid: sim.udid,
                name: sim.name,
                state: sim.state
            )
        }

        // Auto-select booted simulators
        for sim in simulators where sim.state == "Booted" {
            selectedSimulators.insert(sim)
        }
    }

    func toggleSimulator(_ simulator: SimulatorInfo) {
        if selectedSimulators.contains(simulator) {
            selectedSimulators.remove(simulator)
        } else {
            selectedSimulators.insert(simulator)
        }
    }

    func runSelectedTask() async {
        guard let task = selectedTask, !selectedSimulators.isEmpty else { return }

        isRunning = true
        executionLog = []

        addLog(.info, "Starting task: \(task.name)")
        addLog(.info, "Running on \(selectedSimulators.count) simulator(s)")

        let results = await TaskOrchestrator.shared.execute(
            task: task,
            on: Array(selectedSimulators),
            variables: variables
        )

        for result in results {
            let simName = simulators.first { $0.udid == result.simulatorUDID }?.name ?? "Unknown"

            if result.status == .completed {
                addLog(.success, "[\(simName)] Task completed successfully")
            } else {
                addLog(.error, "[\(simName)] Task failed: \(result.error ?? "Unknown error")")
            }

            for stepResult in result.stepResults {
                let icon = stepResult.success ? "checkmark.circle" : "xmark.circle"
                let tool = stepResult.toolUsed.rawValue
                addLog(
                    stepResult.success ? .success : .error,
                    stepResult.message ?? "Step completed",
                    detail: "Used: \(tool) • \(String(format: "%.2fs", stepResult.duration))"
                )
            }
        }

        addLog(.info, "All executions finished")
        isRunning = false
    }

    private func addLog(_ type: LogType, _ message: String, detail: String? = nil) {
        executionLog.append(ExecutionLog(
            type: type,
            message: message,
            detail: detail,
            timestamp: Date()
        ))
    }
}

// MARK: - Log Types

struct ExecutionLog: Hashable {
    let type: LogType
    let message: String
    let detail: String?
    let timestamp: Date

    var icon: String {
        switch type {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch type {
        case .info: return .secondary
        case .success: return .green
        case .error: return .red
        case .warning: return .orange
        }
    }
}

enum LogType {
    case info, success, error, warning
}

// MARK: - Preview

#Preview {
    TaskRunnerView()
        .frame(width: 800, height: 600)
}
