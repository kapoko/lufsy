import AppKit
import SwiftUI
import UniformTypeIdentifiers

#if LUFSY_PRO
  import LufsyPro
#endif

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
  @State private var showsRightSidebar = false
  @State private var tableLayoutResetToken = UUID()
  @State private var sortOrder = [KeyPathComparator(\AnalyzedFile.fileName, order: .forward)]
  @AppStorage("showsLoudnessColumn") private var showsLoudnessColumn = true
  @AppStorage("showsLoudnessRangeColumn") private var showsLoudnessRangeColumn = false
  @AppStorage("showsTruePeakColumn") private var showsTruePeakColumn = true
  @AppStorage("showsDBFSColumn") private var showsDBFSColumn = false
  @AppStorage("showsSampleRateColumn") private var showsSampleRateColumn = false
  @AppStorage("showsBitDepthColumn") private var showsBitDepthColumn = false

  var body: some View {
    Color.clear
      .overlay {
        listView
          .frame(minWidth: 560)
          .padding(16)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .inspector(isPresented: $showsRightSidebar) {
        #if LUFSY_PRO
          operationsSidebar
            .inspectorColumnWidth(min: 270, ideal: 350, max: 430)
        #else
          EmptyView()
        #endif
      }
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

          #if LUFSY_PRO
            LufsyProProcessToolbarButton(
              isProcessing: viewModel.isRenderingProPass,
              isEnabled: viewModel.canRender(for: selection),
              processedCount: viewModel.processedFilesCount,
              totalCount: viewModel.processingFilesTotal,
              action: { viewModel.renderSelectedFile(withIDs: selection) }
            )
          #endif

          Button(action: openFiles) {
            Image(systemName: "plus")
          }
          .labelStyle(.iconOnly)
          .help("Add Files")

          #if LUFSY_PRO
            LufsyProSidebarToggleButton(isPresented: $showsRightSidebar)
          #endif
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

  #if LUFSY_PRO
    private var operationsSidebar: some View {
      LufsyProSidebarView(
        context: .init(
          selectedNormName: viewModel.selectedProfile.displayName,
          standardLoudnessMatchEnabled: viewModel.proProcessingOptions.standardLoudnessMatchEnabled,
          toggleStandardLoudnessMatch: {
            viewModel.proProcessingOptions.standardLoudnessMatchEnabled.toggle()
          }
        )
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea()
    }
  #endif

  private var tableView: some View {
    Table(sortedFiles, selection: $selection, sortOrder: $sortOrder) {
      fileColumn

      if showsLoudnessColumn {
        loudnessColumn
      }

      if showsLoudnessRangeColumn {
        loudnessRangeColumn
      }

      if showsTruePeakColumn {
        truePeakColumn
      }

      if showsDBFSColumn {
        dbfsColumn
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
      if !selectedIDs.isEmpty {
        Button("Show in Finder") {
          showInFinder(ids: selectedIDs)
        }
      }

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

  private func showInFinder(ids: Set<AnalyzedFile.ID>) {
    let urls = viewModel.files
      .filter { ids.contains($0.id) }
      .map(\.url)
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  private var columnToggles: some View {
    Group {
      Toggle(isOn: .constant(true)) { Text("File") }
        .disabled(true)
      Toggle(isOn: $showsLoudnessColumn) { Text("Loudness") }
      Toggle(isOn: $showsLoudnessRangeColumn) { Text("Loudness Range") }
      Toggle(isOn: $showsTruePeakColumn) { Text("True Peak (dBTP)") }
      Toggle(isOn: $showsDBFSColumn) { Text("Peak (dBFS)") }
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
    showsLoudnessRangeColumn = false
    showsTruePeakColumn = true
    showsDBFSColumn = false
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
    TableColumn("True Peak (dBTP)", value: \.truePeakSort) { file in
      Text(valueText(file.metrics?.truePeakDBTP, suffix: " dBTP"))
        .lineLimit(1)
        .monospacedDigit()
    }
    .width(min: 90, ideal: 110, max: 130)
  }

  private var loudnessRangeColumn:
    some TableColumnContent<AnalyzedFile, KeyPathComparator<AnalyzedFile>>
  {
    TableColumn("Loudness Range", value: \.loudnessRangeSort) { file in
      Text(valueText(file.metrics?.loudnessRangeLU, suffix: " LU"))
        .lineLimit(1)
        .monospacedDigit()
    }
    .width(min: 100, ideal: 120, max: 140)
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

  private var dbfsColumn: some TableColumnContent<AnalyzedFile, KeyPathComparator<AnalyzedFile>> {
    TableColumn("Peak (dBFS)", value: \.dbfsSort) { file in
      Text(valueText(file.metrics?.samplePeakDBFS, suffix: " dBFS"))
        .lineLimit(1)
        .monospacedDigit()
    }
    .width(min: 90, ideal: 110, max: 130)
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
    } else if file.showInlineProgress {
      if let progress = viewModel.progressByID[file.id] {
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
    return String(format: "%.2f%@", value, suffix)
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
    viewModel.files.sorted { lhs, rhs in
      for comparator in sortOrder {
        let ordering = comparator.compare(lhs, rhs)
        if ordering == .orderedAscending { return true }
        if ordering == .orderedDescending { return false }
      }

      if lhs.fileName != rhs.fileName {
        return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
      }

      return lhs.id.uuidString < rhs.id.uuidString
    }
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
