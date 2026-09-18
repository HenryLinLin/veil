import AppKit

final class RulePacks: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var data = Data()
    private var completion: ((Result<[CustomRule], Error>) -> Void)?
    private let limit: Int64 = 1_048_576
    static func parse(_ data: Data) throws -> [CustomRule] {
        struct Pack: Decodable { let version: Int; let rules: [CustomRule] }
        guard data.count <= 1_048_576 else { throw failure("Rule packs must be smaller than 1 MB.") }
        let pack = try JSONDecoder().decode(Pack.self, from: data)
        guard pack.version == 1 else { throw failure("Unsupported rule pack version.") }
        let rules = pack.rules.map { ["id": $0.id, "pattern": $0.pattern, "score": $0.score] as [String: Any] }
        let config = String(data: try JSONSerialization.data(withJSONObject: ["custom_rules": rules]), encoding: .utf8)!
        if let error = CoreEngine.validate(config) { throw failure(error) }
        return pack.rules
    }
    func fetch(_ url: URL, completion: @escaping (Result<[CustomRule], Error>) -> Void) {
        guard session == nil else { completion(.failure(Self.failure("A rule download is already running."))); return }
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            completion(.failure(Self.failure("Use an HTTPS rule pack URL without embedded credentials."))); return
        }
        self.completion = completion
        data.removeAll()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        session.dataTask(with: url).resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.expectedContentLength <= limit else {
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard Int64(self.data.count + data.count) <= limit else { dataTask.cancel(); return }
        self.data.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.user == nil, request.url?.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<[CustomRule], Error> = error.map { .failure($0) } ?? Result { try Self.parse(data) }
        let callback = completion
        completion = nil
        data.removeAll()
        self.session = nil
        session.finishTasksAndInvalidate()
        callback?(result)
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Veil rules", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
