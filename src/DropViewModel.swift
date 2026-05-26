import AppKit
import Foundation
import UniformTypeIdentifiers

#if LUFSY_PRO
  import LufsyPro
#endif

enum AnalysisState: Equatable {
  case queued
  case analyzing
  case processing
  case passed
  case failed(String)
}

struct AnalyzedFile: Identifiable, Equatable {
  let id = UUID()
  let url: URL
  var state: AnalysisState
  var metrics: LoudnessMetrics?
  var sampleRateHz: Int?
  var bitDepth: Int?
  var startedAt: Date?
  var showInlineProgress: Bool

  var fileName: String { url.lastPathComponent }
  var integratedSort: Double { metrics?.integratedLUFS ?? -.infinity }
  var loudnessRangeSort: Double { metrics?.loudnessRangeLU ?? -.infinity }
  var truePeakSort: Double { metrics?.truePeakDBTP ?? -.infinity }
  var dbfsSort: Double { metrics?.samplePeakDBFS ?? -.infinity }
  var sampleRateSort: Int { sampleRateHz ?? 0 }
  var bitDepthSort: Int { bitDepth ?? 0 }
  var statusSort: Int {
    switch state {
    case .queued:
      return 0
    case .analyzing:
      return 1
    case .processing:
      return 2
    case .failed:
      return 3
    case .passed:
      return 4
    }
  }
}

@MainActor
final class DropViewModel: ObservableObject {
  static let shared = DropViewModel()
  private static let selectedProfileDefaultsKey = "selectedLoudnessProfile"
  private static let inlineProgressRevealDelayNs: UInt64 = 3_000_000_000
  private static let minInlineProgressUpdateInterval: TimeInterval = 0.9
  private static let minInlineProgressDelta: Double = 0.05

  @Published var files: [AnalyzedFile] = []
  @Published var isDragHovering = false
  @Published var showUnsupportedAlert = false
  @Published var unsupportedMessage = ""
  @Published var progressByID: [UUID: Double] = [:]
  @Published var selectedProfile: LoudnessProfile = .ebuR128 {
    didSet {
      UserDefaults.standard.set(selectedProfile.rawValue, forKey: Self.selectedProfileDefaultsKey)
      reevaluateCompletedFiles()
    }
  }
  @Published var isRenderingProPass = false
  #if LUFSY_PRO
    @Published var proProcessingOptions = LufsyProProcessingOptions()
    @Published var processedFilesCount = 0
    @Published var processingFilesTotal = 0
  #endif

  private let maxConcurrentAnalyses = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
  private let analyzer = LoudnessAnalyzer()
  private struct ProgressCache {
    var lastUpdateAt: Date?
    var lastValue: Double?
  }
  private var progressCacheByID: [UUID: ProgressCache] = [:]

  private init() {
    if let rawValue = UserDefaults.standard.string(forKey: Self.selectedProfileDefaultsKey),
      let storedProfile = LoudnessProfile(rawValue: rawValue)
    {
      selectedProfile = storedProfile
    }
  }

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
    let existingSupported = uniqueSupported.filter { existingURLs.contains($0) }
    let newRows =
      uniqueSupported
      .filter { !existingURLs.contains($0) }
      .map { url in
        AnalyzedFile(
          url: url,
          state: .queued,
          metrics: nil,
          sampleRateHz: nil,
          bitDepth: nil,
          startedAt: nil,
          showInlineProgress: false
        )
      }

    if !existingSupported.isEmpty {
      let existingSet = Set(existingSupported)
      var existingIDs = Set<UUID>()
      for index in files.indices where existingSet.contains(files[index].url) {
        files[index].state = .queued
        files[index].metrics = nil
        files[index].startedAt = nil
        files[index].showInlineProgress = false
        progressByID[files[index].id] = nil
        progressCacheByID[files[index].id] = nil
        existingIDs.insert(files[index].id)
      }

      if !existingIDs.isEmpty {
        Task {
          await preloadAudioDetails(withIDs: existingIDs)
        }

        Task {
          await analyzeFiles(withIDs: existingIDs)
        }
      }
    }

    guard !newRows.isEmpty else {
      return
    }

    files.append(contentsOf: newRows)

    Task {
      await preloadAudioDetails(withIDs: Set(newRows.map(\.id)))
    }

    Task {
      await analyzeFiles(withIDs: Set(newRows.map(\.id)))
    }
  }

  func removeFiles(withIDs ids: Set<UUID>) {
    files.removeAll { ids.contains($0.id) }
    for id in ids {
      progressByID[id] = nil
      progressCacheByID[id] = nil
    }
  }

  #if LUFSY_PRO
    func canRender(for selectedIDs: Set<UUID>) -> Bool {
      LufsyProSelectionPlanner.canRender(
        selectedIDs: selectedIDs,
        files: proFileSnapshots,
        options: proProcessingOptions
      )
    }

    func renderSelectedFile(withIDs selectedIDs: Set<UUID>) {
      guard !isRenderingProPass else { return }
      let items = LufsyProSelectionPlanner.planRenderItems(
        selectedIDs: selectedIDs,
        files: proFileSnapshots,
        targetLUFS: selectedProfile.targetLUFS,
        maxTruePeakDBTP: selectedProfile.maxTruePeakDBTP
      )
      guard !items.isEmpty else { return }

      beginProRendering(for: items)
      let startedAt = Date()
      let requestsCount = items.count
      let processingOptions = proProcessingOptions

      Task {
        defer {
          Task { @MainActor in self.endProRendering(for: items) }
        }

        do {
          let renderedURLs = try await Task.detached(priority: .userInitiated) {
            try LufsyProProcessing.render(
              requests: items.map(\.request),
              options: processingOptions,
              onFileProgress: { requestIndex, progress in
                let fileID = items[requestIndex].id
                Task { @MainActor in
                  self.updateProcessingProgress(for: fileID, progress: progress)
                }
              },
              onFileCompleted: { done, _ in
                Task { @MainActor in
                  self.processedFilesCount = done
                }
              }
            )
          }.value

          await MainActor.run {
            let elapsed = Date().timeIntervalSince(startedAt)
            print(String(format: "[render] done %d file(s) in %.2fs", requestsCount, elapsed))
            self.handleDroppedURLs(renderedURLs)
          }
        } catch {
          await MainActor.run {
            let elapsed = Date().timeIntervalSince(startedAt)
            print(String(format: "[render] failed batch (%d file(s)) in %.2fs (%@)", requestsCount, elapsed, String(describing: error)))
            self.unsupportedMessage = "Render failed for one or more selected files."
            self.showUnsupportedAlert = true
          }
        }
      }
    }

    private func beginProRendering(for items: [LufsyProRenderItem]) {
      isRenderingProPass = true
      processedFilesCount = 0
      processingFilesTotal = items.count

      for item in items {
        guard let idx = files.firstIndex(where: { $0.id == item.id }) else { continue }
        files[idx].state = .processing
        files[idx].showInlineProgress = true
        progressByID[item.id] = 0
        progressCacheByID[item.id] = nil
      }
    }

    private func endProRendering(for items: [LufsyProRenderItem]) {
      isRenderingProPass = false
      processedFilesCount = 0
      processingFilesTotal = 0

      for item in items {
        progressByID[item.id] = nil
        progressCacheByID[item.id] = nil
        guard let idx = files.firstIndex(where: { $0.id == item.id }),
          files[idx].state == .processing
        else { continue }

        files[idx].showInlineProgress = false
        guard let metrics = files[idx].metrics else { continue }
        let verdict = analyzer.evaluate(metrics: metrics, profile: selectedProfile)
        switch verdict {
        case .pass:
          files[idx].state = .passed
        case .fail(let reason):
          files[idx].state = .failed(reason)
        }
      }
    }

    private var proFileSnapshots: [LufsyProFileSnapshot] {
      files.map { file in
        LufsyProFileSnapshot(
          id: file.id,
          inputURL: file.url,
          fileName: file.fileName,
          isAnalyzing: file.state == .analyzing,
          isQueued: file.state == .queued,
          isProcessing: file.state == .processing,
          integratedLUFS: file.metrics?.integratedLUFS,
          sampleRateHz: file.sampleRateHz,
          bitDepth: file.bitDepth
        )
      }
    }
  #endif

  private func analyzeFiles(withIDs ids: Set<UUID>) async {
    let analyzer = self.analyzer

    for index in files.indices where ids.contains(files[index].id) {
      files[index].state = .analyzing
      files[index].startedAt = Date()
      files[index].showInlineProgress = false
      progressByID[files[index].id] = nil
      scheduleInlineProgressReveal(for: files[index].id)
    }

    await withTaskGroup(of: (UUID, LoudnessMetrics?, Int?, Int?, Bool).self) { group in
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
            return (file.id, result.metrics, result.sampleRateHz, result.bitDepth, false)
          } catch {
            await semaphore.signal()
            return (file.id, nil, nil, nil, true)
          }
        }
      }

      for await (id, metrics, sampleRateHz, bitDepth, failed) in group {
        if let idx = files.firstIndex(where: { $0.id == id }) {
          let fileName = files[idx].fileName
          let elapsed = files[idx].startedAt.map { Date().timeIntervalSince($0) }

          files[idx].metrics = metrics
          files[idx].sampleRateHz = sampleRateHz
          files[idx].bitDepth = bitDepth
          files[idx].showInlineProgress = false
          progressByID[id] = nil
          progressCacheByID[id] = nil
          if failed {
            files[idx].state = .failed("analysis failed")
            logAnalysisDuration(for: fileName, elapsed: elapsed, success: false)
          } else if let metrics {
            let verdict = analyzer.evaluate(metrics: metrics, profile: selectedProfile)
            switch verdict {
            case .pass:
              files[idx].state = .passed
            case .fail(let reason):
              files[idx].state = .failed(reason)
            }
            logAnalysisDuration(for: fileName, elapsed: elapsed, success: true)
          }
        }
      }
    }
  }

  private func preloadAudioDetails(withIDs ids: Set<UUID>) async {
    let analyzer = self.analyzer
    let pendingFiles = files.filter { ids.contains($0.id) }

    await withTaskGroup(of: (UUID, Int?, Int?).self) { group in
      for file in pendingFiles {
        group.addTask {
          do {
            let details = try analyzer.readAudioDetails(url: file.url)
            return (file.id, details.sampleRateHz, details.bitDepth)
          } catch {
            return (file.id, nil, nil)
          }
        }
      }

      for await (id, sampleRateHz, bitDepth) in group {
        guard let idx = files.firstIndex(where: { $0.id == id }) else { continue }
        if files[idx].sampleRateHz == nil {
          files[idx].sampleRateHz = sampleRateHz
        }
        if files[idx].bitDepth == nil {
          files[idx].bitDepth = bitDepth
        }
      }
    }
  }

  private func logAnalysisDuration(for fileName: String, elapsed: TimeInterval?, success: Bool) {
    guard let elapsed else {
      print("[analysis] \(success ? "done" : "failed") \(fileName)")
      return
    }

    print(
      String(
        format: "[analysis] %@ %@ in %.2fs",
        success ? "done" : "failed",
        fileName,
        elapsed
      ))
  }

  private func reevaluateCompletedFiles() {
    for index in files.indices {
      guard let metrics = files[index].metrics else { continue }
      guard files[index].state != .analyzing && files[index].state != .queued
          && files[index].state != .processing
      else { continue }

      let verdict = analyzer.evaluate(metrics: metrics, profile: selectedProfile)
      switch verdict {
      case .pass:
        files[index].state = .passed
      case .fail(let reason):
        files[index].state = .failed(reason)
      }
    }
  }

  private func scheduleInlineProgressReveal(for id: UUID) {
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.inlineProgressRevealDelayNs)
      await MainActor.run {
        self?.revealInlineProgress(for: id)
      }
    }
  }

  private func revealInlineProgress(for id: UUID) {
    guard let idx = files.firstIndex(where: { $0.id == id }) else { return }
    guard files[idx].state == .analyzing else { return }
    files[idx].showInlineProgress = true
    if let lastValue = progressCacheByID[id]?.lastValue {
      progressByID[id] = lastValue
      var cache = progressCacheByID[id] ?? ProgressCache()
      cache.lastUpdateAt = Date()
      progressCacheByID[id] = cache
    }
  }

  private func updateProgress(for id: UUID, progress: Double?) {
    guard let idx = files.firstIndex(where: { $0.id == id }) else { return }
    guard files[idx].state == .analyzing else { return }

    if let progress {
      let clamped = min(max(progress, 0), 0.99)
      if files[idx].showInlineProgress == false {
        var cache = progressCacheByID[id] ?? ProgressCache()
        cache.lastValue = clamped
        progressCacheByID[id] = cache
        return
      }

      let now = Date()
      let cache = progressCacheByID[id] ?? ProgressCache()

      if let lastAt = cache.lastUpdateAt,
        let lastValue = cache.lastValue,
        now.timeIntervalSince(lastAt) < Self.minInlineProgressUpdateInterval,
        abs(clamped - lastValue) < Self.minInlineProgressDelta
      {
        return
      }

      progressByID[id] = clamped
      progressCacheByID[id] = ProgressCache(lastUpdateAt: now, lastValue: clamped)
    } else {
      progressByID[id] = nil
      progressCacheByID[id] = nil
    }
  }

  #if LUFSY_PRO
    private func updateProcessingProgress(for id: UUID, progress: Double) {
      guard let idx = files.firstIndex(where: { $0.id == id }) else { return }
      guard files[idx].state == .processing else { return }
      progressByID[id] = min(max(progress, 0), 0.99)
      files[idx].showInlineProgress = true
    }
  #endif

  func stateIcon(for file: AnalyzedFile) -> String? {
    switch file.state {
    case .queued, .analyzing, .processing:
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
