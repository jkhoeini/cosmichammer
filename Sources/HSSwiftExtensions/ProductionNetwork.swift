import Foundation
import HSDSTCore

final class ProductionNetwork: NetworkProtocol {
    private lazy var noRedirectSession: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
    }()

    func httpRequest(url: String, method: String, headers: [String: String],
                     body: Data?, redirect: Bool,
                     completion: @escaping (HTTPResponse?, Error?) -> Void) {
        guard let requestURL = URL(string: url) else {
            completion(nil, NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body

        let session = redirect ? URLSession.shared : noRedirectSession
        let task = session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(nil, error)
                    return
                }
                let httpResp = response as? HTTPURLResponse
                var respHeaders: [String: String] = [:]
                httpResp?.allHeaderFields.forEach { k, v in
                    respHeaders[String(describing: k)] = String(describing: v)
                }
                completion(HTTPResponse(
                    statusCode: httpResp?.statusCode ?? 0,
                    headers: respHeaders,
                    body: data
                ), nil)
            }
        }
        task.resume()
    }

    func createTCPConnection(host: String, port: UInt16,
                             connected: @escaping (Error?) -> Void) -> any TCPConnectionHandle {
        ProductionTCPStub(connected: connected)
    }

    func createUDPSocket() -> any UDPSocketHandle { ProductionUDPStub() }

    func createTCPListener(port: UInt16,
                           onNewConnection: @escaping (any TCPConnectionHandle) -> Void) throws -> any ListenerHandle {
        ProductionListenerStub(port: port)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class ProductionTCPStub: TCPConnectionHandle {
    var isConnected = false
    init(connected: @escaping (Error?) -> Void) {
        connected(NSError(domain: "HSDSTCore", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "TCP not yet migrated to DST protocol"]))
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) { completion(nil) }
    func receive(minimumLength: Int, maximumLength: Int, completion: @escaping (Data?, Error?) -> Void) { completion(nil, nil) }
    func cancel() {}
}

private final class ProductionUDPStub: UDPSocketHandle {
    func send(_ data: Data, toHost host: String, port: UInt16, completion: @escaping (Error?) -> Void) { completion(nil) }
    func receive(completion: @escaping (Data?, String?, UInt16, Error?) -> Void) { completion(nil, nil, 0, nil) }
    func bind(port: UInt16) throws {}
    func close() {}
}

private final class ProductionListenerStub: ListenerHandle {
    let port: UInt16
    init(port: UInt16) { self.port = port }
    func cancel() {}
}
