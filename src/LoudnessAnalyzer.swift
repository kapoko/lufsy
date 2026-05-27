import Darwin
import Foundation
import LufsyShared

struct LoudnessMetrics: Equatable {
  let integratedLUFS: Double
  let loudnessRangeLU: Double
  let truePeakDBTP: Double
  let samplePeakDBFS: Double
  let thresholdLUFS: Double
}

enum LoudnessVerdict: Equatable {
  case pass
  case fail(reason: String)
}

enum LoudnessProfile: String, CaseIterable, Identifiable {
  case ebuR128
  case atscA85
  case aribTrB32
  case youtube14
  case spotify14
  case applePodcasts16

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .ebuR128:
      return "EBU R128"
    case .atscA85:
      return "ATSC A/85"
    case .aribTrB32:
      return "ARIB TR-B32"
    case .youtube14:
      return "YouTube"
    case .spotify14:
      return "Spotify"
    case .applePodcasts16:
      return "Apple Podcasts"
    }
  }

  var columnTitle: String {
    switch self {
    case .ebuR128:
      return "EBU R128"
    case .atscA85:
      return "ATSC A/85"
    case .aribTrB32:
      return "ARIB TR-B32"
    case .youtube14:
      return "YouTube"
    case .spotify14:
      return "Spotify"
    case .applePodcasts16:
      return "Apple Podcasts"
    }
  }

  var targetLUFS: Double {
    switch self {
    case .ebuR128:
      return -23.0
    case .atscA85:
      return -24.0
    case .aribTrB32:
      return -24.0
    case .youtube14, .spotify14:
      return -14.0
    case .applePodcasts16:
      return -16.0
    }
  }

  var toleranceLU: Double {
    switch self {
    case .ebuR128, .atscA85:
      return 0.5
    case .aribTrB32, .youtube14, .spotify14, .applePodcasts16:
      return 1.0
    }
  }

  var maxTruePeakDBTP: Double {
    switch self {
    case .atscA85:
      return -2.0
    case .ebuR128, .aribTrB32, .youtube14, .spotify14, .applePodcasts16:
      return -1.0
    }
  }

  var maxLoudnessRangeLU: Double? {
    switch self {
    case .youtube14, .spotify14, .applePodcasts16:
      return 12.0
    default:
      return nil
    }
  }

  var integratedUnitLabel: String {
    switch self {
    case .atscA85, .aribTrB32:
      return "LKFS"
    default:
      return "LUFS"
    }
  }

  var checksDescription: String {
    let target = String(format: "%.1f", targetLUFS)
    let tolerance = String(format: "%.1f", toleranceLU)
    let tp = String(format: "%.1f", maxTruePeakDBTP)
    let integratedUnit = integratedUnitLabel

    if let maxLRA = maxLoudnessRangeLU {
      let lra = String(format: "%.1f", maxLRA)
      return
        "Integrated loudness: \(target) \(integratedUnit) (+/-\(tolerance) LU), true peak: <= \(tp) dBTP, loudness range: <= \(lra) LU."
    }

    return
      "Integrated loudness: \(target) \(integratedUnit) (+/-\(tolerance) LU), true peak: <= \(tp) dBTP."
  }
}

struct LoudnessAnalysisResult: Equatable {
  let metrics: LoudnessMetrics
  let sampleRateHz: Int?
  let bitDepth: Int?
}

enum LoudnessAnalyzerError: Error {
  case ffmpegNotFound
  case executionFailed
  case invalidOutput
}

final class LoudnessAnalyzer {
  func readAudioDetails(url: URL) throws -> (sampleRateHz: Int?, bitDepth: Int?) {
    try probeAudioDetails(url: url)
  }

  func analyze(url: URL, onProgress: ((Double?) -> Void)? = nil) throws -> LoudnessAnalysisResult {
    guard let ffmpegCommand = resolveFFmpegCommand() else {
      throw LoudnessAnalyzerError.ffmpegNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpegCommand.executable)
    process.arguments = ffmpegCommand.arguments + [
      "-nostdin",
      "-hide_banner",
      "-threads", "0",
      "-progress", "pipe:2",
      "-stats_period", "0.2",
      "-i", url.path,
      "-vn",
      "-filter_complex",
      "[0:a]asplit=2[loud][peak];[loud]loudnorm=I=-23:TP=-1.0:LRA=7:print_format=json[loudout];[peak]astats=metadata=0:reset=0:measure_overall=Peak_level:measure_perchannel=none,anullsink",
      "-map", "[loudout]",
      "-f", "null",
      "-",
    ]

    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    process.standardOutput = Pipe()

    let stderrHandle = stderrPipe.fileHandleForReading
    let outputLock = NSLock()
    var stderrText = ""
    var totalDurationSeconds: Double?

    stderrHandle.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

      outputLock.lock()
      stderrText += chunk
      outputLock.unlock()

      if totalDurationSeconds == nil {
        totalDurationSeconds = self.parseDuration(from: chunk)
      }

      if let outTimeSeconds = self.parseOutTime(from: chunk) {
        if let totalDurationSeconds, totalDurationSeconds > 0 {
          let progress = min(max(outTimeSeconds / totalDurationSeconds, 0), 0.99)
          onProgress?(progress)
        } else {
          onProgress?(nil)
        }
      }
    }

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      stderrHandle.readabilityHandler = nil
      throw LoudnessAnalyzerError.executionFailed
    }

    stderrHandle.readabilityHandler = nil

    guard process.terminationStatus == 0 else {
      throw LoudnessAnalyzerError.executionFailed
    }

    outputLock.lock()
    let collectedOutput = stderrText
    outputLock.unlock()

    let metrics = try parseMetrics(from: collectedOutput)
    let details = parseAudioDetails(from: collectedOutput)
    return LoudnessAnalysisResult(
      metrics: metrics, sampleRateHz: details.sampleRateHz, bitDepth: details.bitDepth)
  }

  private func probeAudioDetails(url: URL) throws -> (sampleRateHz: Int?, bitDepth: Int?) {
    guard let ffmpegCommand = resolveFFmpegCommand() else {
      throw LoudnessAnalyzerError.ffmpegNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpegCommand.executable)
    process.arguments = ffmpegCommand.arguments + [
      "-hide_banner",
      "-nostdin",
      "-i", url.path,
      "-vn",
      "-f", "null",
      "-",
    ]

    let stderrPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = stderrPipe

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw LoudnessAnalyzerError.executionFailed
    }

    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    let details = parseAudioDetails(from: output)
    return details
  }

  private func parseAudioDetails(from output: String) -> (sampleRateHz: Int?, bitDepth: Int?) {
    let audioLine = firstAudioStreamLine(in: output)
    let sampleRate = parseSampleRateHz(from: audioLine)
    let bitDepth = parseBitDepth(from: audioLine)
    return (sampleRate, bitDepth)
  }

  private func firstAudioStreamLine(in output: String) -> String? {
    let lines = output.components(separatedBy: .newlines)
    return lines.first { $0.contains("Audio:") }
  }

  private func parseSampleRateHz(from line: String?) -> Int? {
    guard let line else { return nil }
    let pattern = "([0-9]{4,6})\\s*Hz"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(location: 0, length: line.utf16.count)
    guard let match = regex.firstMatch(in: line, options: [], range: range),
      match.numberOfRanges > 1
    else {
      return nil
    }

    let ns = line as NSString
    let value = ns.substring(with: match.range(at: 1))
    return Int(value)
  }

  private func parseBitDepth(from line: String?) -> Int? {
    guard let line else { return nil }
    let lowercased = line.lowercased()

    let floatingPointFormats = ["flt", "fltp", "dbl", "dblp"]
    if floatingPointFormats.contains(where: { lowercased.contains($0) }) {
      return nil
    }

    let tokens: [(String, Int)] = [
      ("s8", 8),
      ("u8", 8),
      ("s16", 16),
      ("s24", 24),
      ("s32", 32),
    ]

    for (token, depth) in tokens where lowercased.contains(token) {
      return depth
    }

    let pattern = "([0-9]{1,2})\\s*-?bit"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(location: 0, length: lowercased.utf16.count)
    guard let match = regex.firstMatch(in: lowercased, options: [], range: range),
      match.numberOfRanges > 1
    else {
      return nil
    }

    let ns = lowercased as NSString
    let raw = ns.substring(with: match.range(at: 1))
    if let depth = Int(raw), depth > 0 {
      return depth
    }

    return nil
  }

  private func parseMetrics(from output: String) throws -> LoudnessMetrics {
    guard let jsonText = extractJSONBlock(from: output),
      let data = jsonText.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw LoudnessAnalyzerError.invalidOutput
    }

    guard
      let inputI = parseDouble(from: object["input_i"]),
      let inputLRA = parseDouble(from: object["input_lra"]),
      let inputTP = parseDouble(from: object["input_tp"]),
      let inputThresh = parseDouble(from: object["input_thresh"]),
      let samplePeak = parseOverallPeakLevelDBFS(from: output)
    else {
      throw LoudnessAnalyzerError.invalidOutput
    }

    return LoudnessMetrics(
      integratedLUFS: inputI,
      loudnessRangeLU: inputLRA,
      truePeakDBTP: inputTP,
      samplePeakDBFS: samplePeak,
      thresholdLUFS: inputThresh
    )
  }

  private func parseOverallPeakLevelDBFS(from output: String) -> Double? {
    let pattern = "Peak level dB:\\s*(-?[0-9]+(?:\\.[0-9]+)?)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(location: 0, length: output.utf16.count)
    let matches = regex.matches(in: output, options: [], range: range)
    guard let last = matches.last, last.numberOfRanges > 1 else { return nil }

    let ns = output as NSString
    let raw = ns.substring(with: last.range(at: 1))
    return Double(raw)
  }

  private func parseDouble(from value: Any?) -> Double? {
    guard let raw = value as? String else { return nil }
    return Double(raw)
  }

  private func parseOutTime(from outputChunk: String) -> Double? {
    let lines = outputChunk.components(separatedBy: .newlines)
    for line in lines.reversed() {
      if line.hasPrefix("out_time_ms=") {
        let raw = line.replacingOccurrences(of: "out_time_ms=", with: "")
        if let micros = Double(raw) {
          return micros / 1_000_000
        }
      }
    }
    return nil
  }

  private func parseDuration(from outputChunk: String) -> Double? {
    let pattern = "Duration: (\\d{2}):(\\d{2}):(\\d{2})\\.(\\d{2})"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(location: 0, length: outputChunk.utf16.count)
    guard let match = regex.firstMatch(in: outputChunk, options: [], range: range) else {
      return nil
    }

    let ns = outputChunk as NSString
    let hours = Double(ns.substring(with: match.range(at: 1))) ?? 0
    let minutes = Double(ns.substring(with: match.range(at: 2))) ?? 0
    let seconds = Double(ns.substring(with: match.range(at: 3))) ?? 0
    let centiseconds = Double(ns.substring(with: match.range(at: 4))) ?? 0
    return hours * 3600 + minutes * 60 + seconds + centiseconds / 100
  }

  private func extractJSONBlock(from text: String) -> String? {
    guard let start = text.lastIndex(of: "{"),
      let end = text[start...].firstIndex(of: "}")
    else {
      return nil
    }

    return String(text[start...end])
  }

  func evaluate(metrics: LoudnessMetrics, profile: LoudnessProfile) -> LoudnessVerdict {
    let lower = profile.targetLUFS - profile.toleranceLU
    let upper = profile.targetLUFS + profile.toleranceLU

    if metrics.integratedLUFS < lower || metrics.integratedLUFS > upper {
      return .fail(reason: "Loudness out of range")
    }

    if metrics.truePeakDBTP > profile.maxTruePeakDBTP {
      return .fail(reason: "True peak above limit")
    }

    if let maxLRA = profile.maxLoudnessRangeLU, metrics.loudnessRangeLU > maxLRA {
      return .fail(reason: "Loudness range too wide")
    }

    return .pass
  }

  private func resolveFFmpegCommand() -> (executable: String, arguments: [String])? {
    FFmpegResolver.resolveExecutable(preferredBinaryName: FFmpegResolver.preferredBundledBinaryName())
  }
}
