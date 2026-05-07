import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension TableColumnBuilder {
  static func buildEither<Column>(first column: Column) -> Column
  where
    RowValue == Column.TableRowValue,
    Sort == Column.TableColumnSortComparator,
    Column: TableColumnContent
  {
    column
  }

  static func buildEither<Column>(second column: Column) -> Column
  where
    RowValue == Column.TableRowValue,
    Sort == Column.TableColumnSortComparator,
    Column: TableColumnContent
  {
    column
  }
}

struct ContentView: View {
  @ObservedObject private var viewModel = DropViewModel.shared
  @State private var selection = Set<AnalyzedFile.ID>()
  @State private var showsNormInfo = false
  @State private var now = Date()
  @State private var tableLayoutResetToken = UUID()
  @State private var sortOrder = [KeyPathComparator(\AnalyzedFile.fileName, order: .forward)]
  @AppStorage("showsLoudnessColumn") private var showsLoudnessColumn = true
  @AppStorage("showsTruePeakColumn") private var showsTruePeakColumn = true
  @AppStorage("showsSampleRateColumn") private var showsSampleRateColumn = false
  @AppStorage("showsBitDepthColumn") private var showsBitDepthColumn = false
  private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 14) {
      listView
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(16)
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Spacer()
      }

      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          showsNormInfo = true
        } label: {
          Label("About loudness norms", systemImage: "info.circle")
            .imageScale(.medium)
            .foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
        .help("About loudness norms")
        .accessibilityLabel("About loudness norms")

        Picker("Loudness Norm", selection: $viewModel.selectedProfile) {
          ForEach(LoudnessProfile.allCases) { profile in
            Text(profile.displayName).tag(profile)
          }
        }
        .pickerStyle(.menu)

        Button(action: openFiles) {
          Image(systemName: "plus")
        }
        .labelStyle(.iconOnly)
        .help("Add Files")
      }
    }
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $viewModel.isDragHovering) {
      providers in
      viewModel.handleDrop(providers: providers)
    }
    .alert(isPresented: $viewModel.showUnsupportedAlert) {
      Alert(
        title: Text("Unsupported Files"),
        message: Text(viewModel.unsupportedMessage),
        dismissButton: .default(Text("OK"))
      )
    }
    .sheet(isPresented: $showsNormInfo) {
      LoudnessNormInfoView()
    }
    .onReceive(timer) { tick in
      now = tick
    }
    .onDeleteCommand {
      guard !selection.isEmpty else { return }
      viewModel.removeFiles(withIDs: selection)
      selection.removeAll()
    }
  }

  private func openFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.resolvesAliases = true
    panel.title = "Select media files"

    if panel.runModal() == .OK {
      viewModel.handleDroppedURLs(panel.urls)
    }
  }

  private var listView: some View {
    Group {
      if viewModel.files.isEmpty {
        VStack {
          Spacer(minLength: 20)
          Text("Drop files onto the window")
            .foregroundColor(.secondary)
          Spacer(minLength: 20)
        }
      } else {
        tableView
      }
    }
  }

  private var tableView: some View {
    Table(sortedFiles, selection: $selection, sortOrder: $sortOrder) {
      fileColumn

      if showsLoudnessColumn {
        loudnessColumn
      }

      if showsTruePeakColumn {
        truePeakColumn
      }

      if showsSampleRateColumn {
        sampleRateColumn
      }

      if showsBitDepthColumn {
        bitDepthColumn
      }

      statusColumn
    }
    .contextMenu {
      columnToggles
    }
    .contextMenu(forSelectionType: AnalyzedFile.ID.self) { selectedIDs in
      if selectedIDs.count == 1, let singleID = selectedIDs.first {
        Button("Remove") {
          viewModel.removeFiles(withIDs: [singleID])
        }
      }

      if !selectedIDs.isEmpty {
        Button("Remove Selected") {
          viewModel.removeFiles(withIDs: selectedIDs)
        }
      }
    }
    .id(tableLayoutResetToken)
  }

  private var columnToggles: some View {
    Group {
      Toggle(isOn: .constant(true)) { Text("File") }
        .disabled(true)
      Toggle(isOn: $showsLoudnessColumn) { Text("Loudness") }
      Toggle(isOn: $showsTruePeakColumn) { Text("True Peak") }
      Toggle(isOn: $showsSampleRateColumn) { Text("Sample Rate") }
      Toggle(isOn: $showsBitDepthColumn) { Text("Bit Depth") }
      Toggle(isOn: .constant(true)) { Text(viewModel.selectedProfile.columnTitle) }
        .disabled(true)

      Divider()

      Button("Reset to Default") {
        resetColumnVisibilityDefaults()
      }
    }
  }

  private func resetColumnVisibilityDefaults() {
    showsLoudnessColumn = true
    showsTruePeakColumn = true
    showsSampleRateColumn = false
    showsBitDepthColumn = false
    tableLayoutResetToken = UUID()
  }

  private var fileColumn: some TableColumnContent<AnalyzedFile, KeyPathComparator<AnalyzedFile>> {
    TableColumn("File", value: \.fileName) { file in
      Text(file.url.lastPathComponent)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var loudnessColumn: some TableColumnContent<AnalyzedFile, KeyPathComparator<AnalyzedFile>>
  {
    TableColumn("Loudness", value: \.integratedSort) { file in
      Text(valueText(file.metrics?.integratedLUFS, suffix: " LUFS"))
        .lineLimit(1)
        .monospacedDigit()
    }
    .width(min: 80, ideal: 90, max: 100)
  }

  private var truePeakColumn: some TableColumnContent<AnalyzedFile, KeyPathComparator<AnalyzedFile>>
  {
    TableColumn("True Peak", value: \.truePeakSort) { file in
      Text(valueText(file.metrics?.truePeakDBTP, suffix: " dBTP"))
        .lineLimit(1)
        .monospacedDigit()
    }
    .width(min: 90, ideal: 110, max: 130)
  }

  private var sampleRateColumn:
    some TableColumnContent<AnalyzedFile, KeyPathComparator<AnalyzedFile>>
  {
    TableColumn("Sample Rate", value: \.sampleRateSort) { file in
      Text(sampleRateText(file.sampleRateHz))
        .lineLimit(1)
        .monospacedDigit()
    }
    .width(min: 80, ideal: 90, max: 110)
  }

  private var bitDepthColumn: some TableColumnContent<AnalyzedFile, KeyPathComparator<AnalyzedFile>>
  {
    TableColumn("Bit Depth", value: \.bitDepthSort) { file in
      Text(bitDepthText(file.bitDepth))
        .lineLimit(1)
        .monospacedDigit()
    }
    .width(min: 80, ideal: 90, max: 110)
  }

  private var statusColumn: some TableColumnContent<AnalyzedFile, KeyPathComparator<AnalyzedFile>> {
    TableColumn(viewModel.selectedProfile.columnTitle, value: \.statusSort) { file in
      statusView(file)
    }
    .width(min: 80, ideal: 90, max: 100)
  }

  @ViewBuilder
  private func statusView(_ file: AnalyzedFile) -> some View {
    if let icon = viewModel.stateIcon(for: file) {
      Image(systemName: icon)
        .foregroundColor(Color(viewModel.stateColor(for: file)))
    } else if viewModel.shouldShowInlineProgress(for: file, now: now) {
      if let progress = file.progress {
        ProgressView(value: progress)
          .controlSize(.small)
      } else {
        ProgressView()
          .controlSize(.small)
      }
    } else {
      ProgressView()
        .controlSize(.small)
    }
  }

  private func valueText(_ value: Double?, suffix: String) -> String {
    guard let value else { return "--" }
    return String(format: "%.1f%@", value, suffix)
  }

  private func sampleRateText(_ value: Int?) -> String {
    guard let value else { return "--" }
    return String(format: "%.3f kHz", Double(value) / 1000.0)
  }

  private func bitDepthText(_ value: Int?) -> String {
    guard let value else { return "--" }
    return "\(value)-bit"
  }

  private var sortedFiles: [AnalyzedFile] {
    viewModel.files.sorted(using: sortOrder)
  }
}

private struct LoudnessNormInfoView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Loudness Norms")
        .font(.title3.weight(.semibold))

      VStack(alignment: .leading, spacing: 14) {
        ForEach(LoudnessProfile.allCases) { profile in
          VStack(alignment: .leading, spacing: 4) {
            Text(profile.displayName)
              .font(.headline)
            Text(profile.checksDescription)
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.secondary.opacity(0.08))
    )
    .padding(.top, 16)
    .padding(.horizontal, 16)
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button("Close") {
          dismiss()
        }
        .buttonStyle(.automatic)
        .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 12)
    }
    .frame(minWidth: 520, minHeight: 360)
  }
}
