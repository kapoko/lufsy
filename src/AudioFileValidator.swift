import Foundation
import UniformTypeIdentifiers

enum AudioFileValidator {
  static func filterSupportedMediaFiles(from urls: [URL]) -> (supported: [URL], unsupported: [URL]) {
    var supported: [URL] = []
    var unsupported: [URL] = []

    for url in urls {
      guard let contentType = resolvedContentType(for: url) else {
        unsupported.append(url)
        continue
      }

      if contentType.conforms(to: .audio) || contentType.conforms(to: .movie)
        || contentType.conforms(to: .video)
      {
        supported.append(url)
      } else {
        unsupported.append(url)
      }
    }

    return (supported, unsupported)
  }

  private static func resolvedContentType(for url: URL) -> UTType? {
    if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
      let contentType = values.contentType
    {
      return contentType
    }

    let ext = url.pathExtension
    guard !ext.isEmpty else { return nil }
    return UTType(filenameExtension: ext)
  }
}
