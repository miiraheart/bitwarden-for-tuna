import Foundation

struct BitwardenHTTPResponse: Equatable, Sendable {
  let statusCode: Int
  let body: Data
}

enum BitwardenHTTPError: LocalizedError, Equatable {
  case malformedResponse

  var errorDescription: String? { "The Bitwarden CLI returned a response Tuna could not read." }
}

enum BitwardenHTTP {
  private static let separator = Data("\r\n\r\n".utf8)

  static func request(method: String, path: String, query: [String: String] = [:], body: Data? = nil) -> Data {
    var target = path
    if !query.isEmpty {
      target += "?" + query.keys.sorted().map { "\($0)=\(percentEncode(query[$0] ?? ""))" }.joined(separator: "&")
    }
    var lines = [
      "\(method) \(target) HTTP/1.1",
      "Host: localhost",
      "Accept: application/json",
      "Connection: close",
    ]
    if let body {
      lines.append("Content-Type: application/json")
      lines.append("Content-Length: \(body.count)")
    }
    var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    if let body { data.append(body) }
    return data
  }

  static func parseResponse(_ raw: Data) throws -> BitwardenHTTPResponse {
    guard let headerEnd = raw.range(of: separator) else { throw BitwardenHTTPError.malformedResponse }
    let headerText = String(decoding: raw[raw.startIndex..<headerEnd.lowerBound], as: UTF8.self)
    let headerLines = headerText.components(separatedBy: "\r\n")
    guard let statusLine = headerLines.first else { throw BitwardenHTTPError.malformedResponse }
    let statusParts = statusLine.split(separator: " ", maxSplits: 2)
    guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let code = Int(statusParts[1]) else {
      throw BitwardenHTTPError.malformedResponse
    }
    let headers = Dictionary(
      headerLines.dropFirst().compactMap { line -> (String, String)? in
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (name, value)
      }, uniquingKeysWith: { first, _ in first })
    let rawBody = raw[headerEnd.upperBound...]
    let contentLength = headers["content-length"].flatMap(Int.init)
    if let contentLength, contentLength < 0 { throw BitwardenHTTPError.malformedResponse }
    let body: Data
    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
      body = try decodeChunked(Data(rawBody))
    } else if let contentLength {
      body = Data(rawBody.prefix(contentLength))
    } else {
      body = Data(rawBody)
    }
    return BitwardenHTTPResponse(statusCode: code, body: body)
  }

  static func percentEncode(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private static func decodeChunked(_ data: Data) throws -> Data {
    var result = Data()
    var cursor = data.startIndex
    let crlf = Data("\r\n".utf8)
    while cursor < data.endIndex {
      guard let lineEnd = data[cursor...].range(of: crlf) else { throw BitwardenHTTPError.malformedResponse }
      let sizeText = String(decoding: data[cursor..<lineEnd.lowerBound], as: UTF8.self)
        .split(separator: ";").first.map(String.init) ?? ""
      guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
        throw BitwardenHTTPError.malformedResponse
      }
      if size == 0 { break }
      let chunkStart = lineEnd.upperBound
      let chunkEnd = data.index(chunkStart, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
      result.append(data[chunkStart..<chunkEnd])
      cursor = data.index(chunkEnd, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
    }
    return result
  }
}
