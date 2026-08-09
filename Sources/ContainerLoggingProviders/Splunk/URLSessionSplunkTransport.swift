//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Security

public enum SplunkHTTPMethod: Equatable, Sendable {
    case options
    case post
}

public struct SplunkHTTPRequest: Sendable {
    public let url: String
    public let method: SplunkHTTPMethod
    public let headers: [String: String]
    public let body: Data
    public let maximumResponseBytes: Int

    public init(
        url: String,
        method: SplunkHTTPMethod,
        headers: [String: String] = [:],
        body: Data = Data(),
        maximumResponseBytes: Int
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.maximumResponseBytes = maximumResponseBytes
    }
}

public struct SplunkHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol SplunkHTTPTransport: Sendable {
    func execute(
        _ request: SplunkHTTPRequest,
        timeout: Duration
    ) async throws -> SplunkHTTPResponse

    func close() async
}

public protocol SplunkHTTPTransportFactory: Sendable {
    func makeTransport(
        configuration: SplunkDriverConfiguration
    ) throws -> any SplunkHTTPTransport
}

public struct URLSessionSplunkHTTPTransportFactory:
    SplunkHTTPTransportFactory
{
    public init() {}

    public func makeTransport(
        configuration: SplunkDriverConfiguration
    ) throws -> any SplunkHTTPTransport {
        try URLSessionSplunkHTTPTransport(tls: configuration.tls)
    }
}

public final class URLSessionSplunkHTTPTransport:
    SplunkHTTPTransport, @unchecked Sendable
{
    private let session: URLSession

    public init(tls: SplunkTLSConfiguration?) throws {
        let delegate = try SplunkTrustDelegate(configuration: tls)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.connectionProxyDictionary = Self.proxyDictionary()
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    public func execute(
        _ request: SplunkHTTPRequest,
        timeout: Duration
    ) async throws -> SplunkHTTPResponse {
        guard let url = URL(string: request.url) else {
            throw SplunkProviderError.malformedURL(request.url)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method == .post ? "POST" : "OPTIONS"
        urlRequest.httpBody = request.body.isEmpty ? nil : request.body
        urlRequest.timeoutInterval = timeout.splunkTimeInterval
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw SplunkProviderError.connectionFailed
            }
            var body = Data()
            body.reserveCapacity(min(request.maximumResponseBytes, 1_024))
            for try await byte in bytes {
                guard body.count < request.maximumResponseBytes else {
                    throw SplunkProviderError.responseBodyTooLarge(
                        maximumBytes: request.maximumResponseBytes
                    )
                }
                body.append(byte)
            }
            return SplunkHTTPResponse(
                statusCode: http.statusCode,
                body: body
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SplunkProviderError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw SplunkProviderError.requestTimedOut
        } catch {
            throw SplunkProviderError.connectionFailed
        }
    }

    public func close() async {
        session.invalidateAndCancel()
    }

    private static func proxyDictionary() -> [AnyHashable: Any]? {
        let environment = ProcessInfo.processInfo.environment
        let http = environment["HTTP_PROXY"] ?? environment["http_proxy"]
        let https = environment["HTTPS_PROXY"] ?? environment["https_proxy"]
        var result = [AnyHashable: Any]()
        addProxy(http, prefix: "HTTP", to: &result)
        addProxy(https ?? http, prefix: "HTTPS", to: &result)
        if !result.isEmpty {
            var exceptions = ["localhost", "127.0.0.1", "::1"]
            let noProxy = environment["NO_PROXY"] ?? environment["no_proxy"]
            exceptions.append(
                contentsOf: (noProxy ?? "").split(separator: ",").map {
                    String($0)
                }
            )
            result["ExceptionsList"] = Array(Set(exceptions)).sorted()
            result["ExcludeSimpleHostnames"] = 1
        }
        return result.isEmpty ? nil : result
    }

    private static func addProxy(
        _ value: String?,
        prefix: String,
        to result: inout [AnyHashable: Any]
    ) {
        guard
            let value,
            let components = URLComponents(string: value),
            let host = components.host
        else {
            return
        }
        result["\(prefix)Enable"] = 1
        result["\(prefix)Proxy"] = host
        if let port = components.port {
            result["\(prefix)Port"] = port
        }
    }
}

private final class SplunkTrustDelegate:
    NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
    private let configuration: SplunkTLSConfiguration?
    private let anchors: [SecCertificate]

    init(configuration: SplunkTLSConfiguration?) throws {
        self.configuration = configuration
        if let path = configuration?.caCertificatePath {
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw SplunkProviderError.certificateReadFailed
            }
            self.anchors = try Self.certificates(fromPEM: data)
        } else {
            self.anchors = []
        }
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @Sendable (
                URLSession.AuthChallengeDisposition,
                URLCredential?
            ) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @Sendable (
                URLSession.AuthChallengeDisposition,
                URLCredential?
            ) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @Sendable (
                URLSession.AuthChallengeDisposition,
                URLCredential?
            ) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            let configuration
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if configuration.insecureSkipVerify {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        let serverName =
            configuration.serverName
            ?? challenge.protectionSpace.host
        SecTrustSetPolicies(
            trust,
            SecPolicyCreateSSL(true, serverName as CFString)
        )
        if !anchors.isEmpty {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private static func certificates(fromPEM data: Data) throws -> [SecCertificate] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SplunkProviderError.certificateInvalid
        }
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var certificates = [SecCertificate]()
        var remainder = text[...]
        while let beginRange = remainder.range(of: begin) {
            remainder = remainder[beginRange.upperBound...]
            guard let endRange = remainder.range(of: end) else {
                throw SplunkProviderError.certificateInvalid
            }
            let encoded = remainder[..<endRange.lowerBound]
                .filter { !$0.isWhitespace }
            guard
                let der = Data(base64Encoded: String(encoded)),
                let certificate = SecCertificateCreateWithData(
                    nil,
                    der as CFData
                )
            else {
                throw SplunkProviderError.certificateInvalid
            }
            certificates.append(certificate)
            remainder = remainder[endRange.upperBound...]
        }
        guard !certificates.isEmpty else {
            throw SplunkProviderError.certificateInvalid
        }
        return certificates
    }
}

extension Duration {
    fileprivate var splunkTimeInterval: TimeInterval {
        let components = self.components
        let seconds = Double(components.seconds)
        let fractional = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return max(0.001, seconds + fractional)
    }
}
