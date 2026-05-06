import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject private var viewModel = DropViewModel.shared
  @State private var selection = Set<AnalyzedFile.ID>()
  @State private var showsNormInfo = false
  @State private var now = Date()
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
          Image(systemName: "info.circle")
            .imageScale(.medium)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("About loudness norms")

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
        Table(viewModel.files, selection: $selection) {
          TableColumn("File") { file in
            Text(file.url.lastPathComponent)
              .lineLimit(1)
              .truncationMode(.middle)
              .contextMenu {
                Button("Remove") {
                  viewModel.removeFiles(withIDs: Set([file.id]))
                }

                if !selection.isEmpty {
                  Button("Remove Selected") {
                    viewModel.removeFiles(withIDs: selection)
                  }
                }
              }
          }

          TableColumn("Loudness") { file in
            Text(valueText(file.metrics?.integratedLUFS, suffix: " LUFS"))
              .lineLimit(1)
              .monospacedDigit()
          }
          .width(min: 80, ideal: 90, max: 100)

          TableColumn("True Peak") { file in
            Text(valueText(file.metrics?.truePeakDBTP, suffix: " dBTP"))
              .lineLimit(1)
              .monospacedDigit()
          }
          .width(min: 90, ideal: 110, max: 130)

          TableColumn(viewModel.selectedProfile.columnTitle) { file in
            statusView(file)
          }
          .width(min: 80, ideal: 90, max: 100)
        }
        .contextMenu {
          if !selection.isEmpty {
            Button("Remove Selected") {
              viewModel.removeFiles(withIDs: selection)
            }
          }
        }
      }
    }
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
