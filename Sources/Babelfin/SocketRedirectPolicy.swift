import Foundation

/// Authenticated WebSocket handshakes never follow redirects, including same-origin redirects.
final class SocketRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Keep Foundation diagnostics (which may contain request URLs) inside the transport boundary.
enum SocketTransportError: Error { case connectionFailed }
