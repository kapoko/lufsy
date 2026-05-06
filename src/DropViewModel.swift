import AppKit
import Foundation
import UniformTypeIdentifiers

enum AnalysisState: Equatable {
  case queued
  case analyzing
  case passed
  case failed(String)
}

struct AnalyzedFile: Identifiable, Equatable {
  let id = UUID()
  let url: URL
  var state: AnalysisState
  var metrics: LoudnessMetrics?
  var startedAt: Date?
  var progress: Double?
}

@MainActor
final class DropViewModel: ObservableObject {
  static let shared = DropViewModel()

  @Published var files: [AnalyzedFile] = []
  @Published var isDragHovering = false
  @Published var showUnsupportedAlert = false
  @Published var unsupportedMessage = ""
  @Published var selectedProfile: LoudnessProfile = .ebuR128 {
    didSet {
      reevaluateCompletedFiles()
    }
  }

  private let maxConcurrentAnalyses = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
  private let analyzer = LoudnessAnalyzer()

  func handleDrop(providers: [NSItemProvider]) -> Bool {
    let fileProviders = providers.filter {
      $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    guard !fileProviders.isEmpty else { return false }

    let group = DispatchGroup()
    let lock = NSLock()
    var loadedURLs: [URL] = []

    for provider in fileProviders {
      group.enter()
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        defer { group.leave() }
        guard let url = Self.extractURL(from: item) else { return }
        lock.lock()
        loadedURLs.append(url)
        lock.unlock()
      }
    }

    group.notify(queue: .main) { [weak self] in
      self?.handleDroppedURLs(loadedURLs)
    }

    return true
  }

  func handleDroppedURLs(_ urls: [URL]) {
    let validation = AudioFileValidator.filterSupportedMediaFiles(from: urls)
    let uniqueSupported = Array(Set(validation.supported)).sorted {
      $0.lastPathComponent < $1.lastPathComponent
    }

    if !validation.unsupported.isEmpty {
      let names = validation.unsupported.map(\.lastPathComponent).prefix(6)
      unsupportedMessage = "Unsupported files:\n\n" + names.joined(separator: "\n")
      showUnsupportedAlert = true
    }

    let existingURLs = Set(files.map(\.url))
    let newRows =
      uniqueSupported
      .filter { !existingURLs.contains($0) }
      .map { AnalyzedFile(url: $0, state: .queued, metrics: nil, startedAt: nil, progress: nil) }

    guard !newRows.isEmpty else {
      return
    }

    files.append(contentsOf: newRows)

    Task {
      await analyzeFiles(withIDs: Set(newRows.map(\.id)))
    }
  }

  func removeFiles(withIDs ids: Set<UUID>) {
    files.removeAll { ids.contains($0.id) }
  }

  private func analyzeFiles(withIDs ids: Set<UUID>) async {
    let analyzer = self.analyzer

    for index in files.indices where ids.contains(files[index].id) {
      files[index].state = .analyzing
      files[index].startedAt = Date()
      files[index].progress = nil
    }

    await withTaskGroup(of: (UUID, LoudnessMetrics?, Bool).self) { group in
      let semaphore = AsyncSemaphore(value: maxConcurrentAnalyses)

      let pendingFiles = files.filter { ids.contains($0.id) }

      for file in pendingFiles {
        group.addTask {
          await semaphore.wait()

          do {
            let result = try analyzer.analyze(url: file.url) { progress in
              Task { @MainActor in
                self.updateProgress(for: file.id, progress: progress)
              }
            }
            await semaphore.signal()
            return (file.id, result.metrics, false)
          } catch {
            await semaphore.signal()
            return (file.id, nil, true)
          }
        }
      }

      for await (id, metrics, failed) in group {
        if let idx = files.firstIndex(where: { $0.id == id }) {
          files[idx].metrics = metrics
          files[idx].progress = nil
          if failed {
            files[idx].state = .failed("analysis failed")
          } else if let metrics {
            let verdict = analyzer.evaluate(metrics: metrics, profile: selectedProfile)
            switch verdict {
            case .pass:
              files[idx].state = .passed
            case .fail(let reason):
              files[idx].state = .failed(reason)
            }
          }
        }
      }
    }
  }

  private func updateProgress(for id: UUID, progress: Double?) {
    guard let idx = files.firstIndex(where: { $0.id == id }) else { return }
    guard files[idx].state == .analyzing else { return }
    if let progress {
      files[idx].progress = min(max(progress, 0), 0.99)
    } else {
      files[idx].progress = nil
    }
  }

  func shouldShowInlineProgress(for file: AnalyzedFile, now: Date) -> Bool {
    guard case .analyzing = file.state, let startedAt = file.startedAt else {
      return false
    }
    return now.timeIntervalSince(startedAt) >= 3
  }

  private func reevaluateCompletedFiles() {
    for index in files.indices {
      guard let metrics = files[index].metrics else { continue }
      guard files[index].state != .analyzing && files[index].state != .queued else { continue }

      let verdict = analyzer.evaluate(metrics: metrics, profile: selectedProfile)
      switch verdict {
      case .pass:
        files[index].state = .passed
      case .fail(let reason):
        files[index].state = .failed(reason)
      }
    }
  }

  func stateIcon(for file: AnalyzedFile) -> String? {
    switch file.state {
    case .queued, .analyzing:
      return nil
    case .passed:
      return "checkmark.circle.fill"
    case .failed:
      return "xmark.circle.fill"
    }
  }

  func stateColor(for file: AnalyzedFile) -> NSColor {
    switch file.state {
    case .passed:
      return .systemGreen
    case .failed:
      return .systemRed
    default:
      return .secondaryLabelColor
    }
  }

  nonisolated private static func extractURL(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL { return url }
    if let nsURL = item as? NSURL { return nsURL as URL }
    if let data = item as? Data,
      let value = String(data: data, encoding: .utf8)
    {
      return URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }
}

actor AsyncSemaphore {
  private let value: Int
  private var available: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(value: Int) {
    self.value = max(1, value)
    self.available = max(1, value)
  }

  func wait() async {
    if available > 0 {
      available -= 1
      return
    }

    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func signal() {
    if waiters.isEmpty {
      available = min(available + 1, value)
      return
    }

    let waiter = waiters.removeFirst()
    waiter.resume()
  }
}
