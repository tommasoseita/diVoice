import Foundation

/// HTTP as the providers need it. Abstracted so tests can answer without the network.
public protocol HTTPClient: Sendable {
  func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
  /// Streams the body line by line (server-sent events). A non-2xx status throws `HTTPStatusError`.
  func lines(_ request: URLRequest, label: String, _ onLine: (String) throws -> Void) async throws
}

/// A WebSocket. `send` queues in call order, text and binary alike; failures surface from `receive`.
public protocol WebSocketConnection: Sendable {
  func send(_ text: String)
  func send(data: Data)
  /// Sends and returns once the message is written to the connection (or the send failed).
  func sendAndWait(_ text: String) async
  func receive() async throws -> String
  func close()
}

extension WebSocketConnection {
  public func sendAndWait(_ text: String) async { send(text) }
}

public protocol WebSocketConnector: Sendable {
  func connect(_ request: URLRequest) async throws -> WebSocketConnection
}

/// Base URL and credentials of a provider (direct) or of a relay.
public struct ProviderEndpoint: Sendable, Equatable {
  public var baseURL: URL
  public var apiKey: String
  /// The header for the key; nil: `Authorization: Bearer`.
  public var keyHeader: String?

  public init(baseURL: URL, apiKey: String, keyHeader: String? = nil) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.keyHeader = keyHeader
  }

  public static func direct(_ provider: ProviderID, apiKey: String) -> ProviderEndpoint {
    ProviderEndpoint(baseURL: provider.defaultBaseURL, apiKey: apiKey, keyHeader: provider.keyHeader)
  }

  /// The address of an OpenAI-compatible server, as the user typed it.
  public enum CompatibleAddress: Sendable, Equatable {
    /// https: encrypted.
    case secure(URL)
    /// Plain http to this Mac itself: nothing leaves it.
    case loopback(URL)
    /// Plain http to a private network address: accepted, but not encrypted.
    case localHTTP(URL)
    /// Plain http to a public address: refused.
    case remoteHTTP
    case invalid

    /// The base URL to call; nil when the address is refused or not valid.
    public var url: URL? {
      switch self {
      case .secure(let url), .loopback(let url), .localHTTP(let url): url
      case .remoteHTTP, .invalid: nil
      }
    }
  }

  /// Where a host is, for plain http: this Mac, a private network, or anywhere else.
  enum HostScope: Equatable { case loopback, privateNetwork, remote }

  /// Private networks are the address ranges that never cross the internet: IPv4 10/8, 172.16/12,
  /// 192.168/16, link-local 169.254/16 and shared 100.64/10 (VPNs such as Tailscale), IPv6
  /// unique local fc00::/7 and link-local fe80::/10, `.local` names and names without a domain.
  static func hostScope(_ host: String) -> HostScope {
    let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host == "::1" { return .loopback }
    if host.contains(":") {
      let first = host.prefix(3)
      if host.hasPrefix("fc") || host.hasPrefix("fd") || ["fe8", "fe9", "fea", "feb"].contains(String(first)) { return .privateNetwork }
      return .remote
    }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 4, !parts.contains(where: { $0.isEmpty || !$0.allSatisfy(\.isNumber) }) {
      let bytes = parts.compactMap { UInt8($0) }
      guard bytes.count == 4 else { return .remote }
      switch (bytes[0], bytes[1]) {
      case (127, _): return .loopback
      case (10, _), (192, 168), (169, 254), (172, 16...31), (100, 64...127): return .privateNetwork
      default: return .remote
      }
    }
    if host.hasSuffix(".local") || !host.contains(".") { return .privateNetwork }
    return .remote
  }

  /// Reads the address the user typed: with or without the scheme, a final slash, `/v1` or the
  /// whole `/v1/chat/completions`. Plain http is accepted only for this Mac and private networks.
  public static func compatibleAddress(_ address: String) -> CompatibleAddress {
    var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    // URLComponents would percent-encode spaces instead of refusing them.
    guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return .invalid }
    if !text.contains("://") {
      // Without a scheme: plain http for this Mac and private networks, https for the rest.
      let host = URLComponents(string: "http://" + text)?.host ?? ""
      text = (!host.isEmpty && hostScope(host) != .remote ? "http://" : "https://") + text
    }
    guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = components.host, !host.isEmpty
    else { return .invalid }
    var path = components.path
    for suffix in ["/", "/chat/completions", "/", "/v1", "/"] {
      while path.hasSuffix(suffix) { path.removeLast(suffix.count) }
    }
    components.scheme = scheme
    components.path = path
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { return .invalid }
    if scheme == "https" { return .secure(url) }
    switch hostScope(host) {
    case .loopback: return .loopback(url)
    case .privateNetwork: return .localHTTP(url)
    case .remote: return .remoteHTTP
    }
  }

  /// The base URL of an OpenAI-compatible server from the address the user typed; nil when it
  /// isn't valid, or is plain http outside this Mac and private networks.
  public static func compatibleBaseURL(_ address: String) -> URL? {
    compatibleAddress(address).url
  }

  /// An OpenAI-compatible server at `baseURL`, with a bearer key.
  public static func compatible(_ baseURL: URL, apiKey: String) -> ProviderEndpoint {
    ProviderEndpoint(baseURL: baseURL, apiKey: apiKey)
  }

  func url(_ path: String, query: [URLQueryItem] = []) -> URL {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) + path
    if !query.isEmpty { components.queryItems = query }
    return components.url!
  }

  func webSocketURL(_ path: String, query: [URLQueryItem] = []) -> URL {
    var components = URLComponents(url: url(path, query: query), resolvingAgainstBaseURL: false)!
    components.scheme = components.scheme == "http" ? "ws" : "wss"
    return components.url!
  }

  func request(_ url: URL, method: String = "GET", timeout: Double = 30) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    if let keyHeader {
      request.setValue(apiKey, forHTTPHeaderField: keyHeader)
    } else {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    return request
  }
}

// MARK: - URLSession implementations

public struct URLSessionHTTPClient: HTTPClient {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw EngineError("invalid HTTP response") }
    return (data, http)
  }

  public func lines(_ request: URLRequest, label: String, _ onLine: (String) throws -> Void) async throws {
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw EngineError("\(label): invalid HTTP response") }
    guard (200..<300).contains(http.statusCode) else {
      var body = Data()
      for try await byte in bytes {
        body.append(byte)
        if body.count >= 2048 { break }
      }
      throw HTTPStatusError(label: label, status: http.statusCode, body: String(decoding: body, as: UTF8.self))
    }
    for try await line in bytes.lines { try onLine(line) }
  }
}

public struct URLSessionWebSocketConnector: WebSocketConnector {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func connect(_ request: URLRequest) async throws -> WebSocketConnection {
    let task = session.webSocketTask(with: request)
    task.maximumMessageSize = 16 * 1024 * 1024
    task.resume()
    return URLSessionWebSocket(task: task)
  }
}

final class URLSessionWebSocket: WebSocketConnection, @unchecked Sendable {
  private let task: URLSessionWebSocketTask

  init(task: URLSessionWebSocketTask) {
    self.task = task
  }

  func send(_ text: String) {
    task.send(.string(text)) { _ in }
  }

  func send(data: Data) {
    task.send(.data(data)) { _ in }
  }

  func sendAndWait(_ text: String) async {
    try? await task.send(.string(text))
  }

  func receive() async throws -> String {
    do {
      switch try await task.receive() {
      case .string(let text): return text
      case .data(let data): return String(decoding: data, as: UTF8.self)
      @unknown default: return ""
      }
    } catch {
      if task.closeCode != .invalid {
        let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        throw EngineError("connection closed (\(task.closeCode.rawValue)) \(reason)".trimmingCharacters(in: .whitespaces))
      }
      if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
        throw EngineError("connection refused (HTTP \(http.statusCode))")
      }
      throw error
    }
  }

  func close() {
    task.cancel(with: .normalClosure, reason: nil)
  }
}

// MARK: - Audio and form encoding

public enum WAV {
  /// Wraps mono PCM s16le in a WAV file.
  public static func wrap(_ pcm: Data, sampleRate: Int) -> Data {
    var header = Data()
    func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
    func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
    header.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + pcm.count))
    header.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))  // PCM
    append(UInt16(1))  // mono
    append(UInt32(sampleRate))
    append(UInt32(sampleRate * 2))
    append(UInt16(2))
    append(UInt16(16))
    header.append(contentsOf: Array("data".utf8))
    append(UInt32(pcm.count))
    return header + pcm
  }
}

struct MultipartForm {
  let boundary = "divoice-\(UUID().uuidString)"
  private(set) var body = Data()

  var contentType: String { "multipart/form-data; boundary=\(boundary)" }

  mutating func field(_ name: String, _ value: String) {
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
  }

  mutating func file(_ name: String, filename: String, contentType: String, data: Data) {
    body.append(
      Data(
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n"
          .utf8))
    body.append(data)
    body.append(Data("\r\n".utf8))
  }

  func finished() -> Data {
    body + Data("--\(boundary)--\r\n".utf8)
  }
}

enum JSON {
  static func string(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  static func object(_ text: String) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
  }

  static func object(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  /// A provider error object as a short message.
  static func describeError(_ value: Any?) -> String {
    guard let value else { return "unknown error" }
    if let text = value as? String { return text }
    if let object = value as? [String: Any] {
      let message = (object["message"] as? String) ?? string(object)
      if let code = object["code"] { return "\(message) (\(code))" }
      return message
    }
    return "\(value)"
  }
}
