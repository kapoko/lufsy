import Foundation

public enum FFmpegResolver {
  public static func resolveExecutable(
    preferredBinaryName: String? = nil
  ) -> (executable: String, arguments: [String])? {
    if let overridePath = ProcessInfo.processInfo.environment["LUFSY_FFMPEG_PATH"],
      FileManager.default.isExecutableFile(atPath: overridePath)
    {
      return (overridePath, [])
    }

    let candidatePaths = [
      "/opt/homebrew/bin/ffmpeg",
      "/usr/local/bin/ffmpeg",
      "/usr/bin/ffmpeg",
    ]

    if let binaryName = preferredBinaryName,
      let bundledPath = Bundle.main.path(forResource: binaryName, ofType: nil),
      FileManager.default.isExecutableFile(atPath: bundledPath)
    {
      return (bundledPath, [])
    }

    if let binaryName = preferredBinaryName {
      let executablePath = Bundle.main.executablePath ?? ""
      let executableDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
      let bundleRelative = executableDir.appendingPathComponent("../Resources/\(binaryName)").path
      if FileManager.default.isExecutableFile(atPath: bundleRelative) {
        return (bundleRelative, [])
      }
    }

    for candidate in candidatePaths where FileManager.default.isExecutableFile(atPath: candidate) {
      return (candidate, [])
    }

    if let pathFromEnvironment = resolveFromPATH(binaryName: "ffmpeg") {
      return (pathFromEnvironment, [])
    }

    return ("/usr/bin/env", ["ffmpeg"])
  }

  public static func preferredBundledBinaryName() -> String {
    let machine = currentMachineIdentifier()
    if machine.contains("arm64") || machine.contains("aarch64") {
      return "ffmpeg-arm64"
    }
    return "ffmpeg-x86_64"
  }

  private static func resolveFromPATH(binaryName: String) -> String? {
    let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let directories = pathValue.split(separator: ":")

    for directory in directories {
      let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(binaryName).path
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }

    return nil
  }

  private static func currentMachineIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)

    return Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { result, element in
      guard let value = element.value as? Int8, value != 0 else { return }
      result.append(Character(UnicodeScalar(UInt8(value))))
    }
  }
}
