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

import AWSClientRuntime
import AWSCloudWatchLogs
import AWSSDKIdentity
import ClientRuntime
import ContainerLoggingProviders
import ContainerVersion
import Foundation
import Smithy
import SmithyHTTPAPI
import SmithyIdentity

public struct AWSCloudWatchLogsClientFactory: AWSLogsClientFactory {
    public init() {}

    public func makeClient(
        configuration: AWSLogsDriverConfiguration
    ) async throws -> any AWSLogsClient {
        let region: String
        if let configured = configuration.region, !configured.isEmpty {
            region = configured
        } else {
            guard
                let discovered = try await IMDSRegionProvider().getRegion(),
                !discovered.isEmpty
            else {
                throw AWSLogsProviderError.cannotDetermineRegion
            }
            region = discovered
        }

        let credentialResolver: (any AWSCredentialIdentityResolver)?
        if let uri = configuration.credentialsEndpointURI {
            credentialResolver = try CustomAWSCredentialIdentityResolver(
                AWSLogsEndpointCredentialIdentityResolver(uri: uri)
            )
        } else {
            credentialResolver = nil
        }

        var headers = [
            "User-Agent": "Docker/\(ReleaseVersion.version())"
        ]
        if configuration.logFormat != nil {
            headers["x-amzn-logs-format"] = "json/emf"
        }
        let config = try await CloudWatchLogsClient.CloudWatchLogsClientConfig(
            awsCredentialIdentityResolver: credentialResolver,
            region: region,
            signingRegion: region,
            endpoint: configuration.endpoint,
            httpInterceptorProviders: [
                AWSLogsHeaderInterceptorProvider(headers: headers)
            ]
        )
        return AWSCloudWatchLogsClientAdapter(
            CloudWatchLogsClient(config: config)
        )
    }
}

private actor AWSCloudWatchLogsClientAdapter: AWSLogsClient {
    private let client: CloudWatchLogsClient

    init(_ client: CloudWatchLogsClient) {
        self.client = client
    }

    func createLogGroup(name: String) async throws {
        do {
            _ = try await client.createLogGroup(
                input: CreateLogGroupInput(logGroupName: name)
            )
        } catch {
            throw Self.map(error)
        }
    }

    func createLogStream(group: String, stream: String) async throws {
        do {
            _ = try await client.createLogStream(
                input: CreateLogStreamInput(
                    logGroupName: group,
                    logStreamName: stream
                )
            )
        } catch {
            throw Self.map(error)
        }
    }

    func putLogEvents(
        group: String,
        stream: String,
        events: [AWSLogsInputEvent],
        sequenceToken: String?
    ) async throws -> AWSLogsPutResult {
        do {
            let output = try await client.putLogEvents(
                input: PutLogEventsInput(
                    logEvents: events.map {
                        CloudWatchLogsClientTypes.InputLogEvent(
                            message: $0.message,
                            timestamp: Int($0.timestampMilliseconds)
                        )
                    },
                    logGroupName: group,
                    logStreamName: stream,
                    sequenceToken: sequenceToken
                )
            )
            return AWSLogsPutResult(
                nextSequenceToken: output.nextSequenceToken
            )
        } catch {
            throw Self.map(error)
        }
    }

    func close() async {}

    private static func map(_ error: any Error) -> AWSLogsClientError {
        switch error {
        case is ResourceNotFoundException:
            .resourceNotFound
        case is ResourceAlreadyExistsException:
            .resourceAlreadyExists
        case let error as DataAlreadyAcceptedException:
            .dataAlreadyAccepted(
                expectedSequenceToken:
                    error.properties.expectedSequenceToken
            )
        case let error as InvalidSequenceTokenException:
            .invalidSequenceToken(
                expectedSequenceToken:
                    error.properties.expectedSequenceToken
            )
        default:
            .requestFailed
        }
    }
}

private struct AWSLogsHeaderInterceptorProvider: HttpInterceptorProvider {
    let headers: [String: String]

    func create<InputType, OutputType>()
        -> any Interceptor<InputType, OutputType, HTTPRequest, HTTPResponse>
    {
        AWSLogsHeaderInterceptor(headers: headers)
    }
}

private struct AWSLogsHeaderInterceptor<InputType, OutputType>: Interceptor {
    typealias RequestType = HTTPRequest
    typealias ResponseType = HTTPResponse

    let headers: [String: String]

    func modifyBeforeSigning(
        context: some MutableRequest<InputType, HTTPRequest>
    ) async throws {
        let builder = context.getRequest().toBuilder()
        for (name, value) in headers {
            builder.withHeader(name: name, value: value)
        }
        context.updateRequest(updated: builder.build())
    }
}

private struct AWSLogsEndpointCredentialIdentityResolver:
    AWSCredentialIdentityResolver
{
    private struct Response: Decodable {
        let accessKeyID: String
        let secretAccessKey: String
        let token: String?
        let expiration: Date?

        enum CodingKeys: String, CodingKey {
            case accessKeyID = "AccessKeyId"
            case secretAccessKey = "SecretAccessKey"
            case token = "Token"
            case expiration = "Expiration"
        }
    }

    let uri: String

    func getIdentity(
        identityProperties: Attributes?
    ) async throws -> AWSCredentialIdentity {
        guard let url = URL(string: "http://169.254.170.2" + uri) else {
            throw AWSLogsProviderError.credentialsEndpointFailed
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AWSLogsProviderError.credentialsEndpointFailed
        }
        guard
            let http = response as? HTTPURLResponse,
            http.statusCode == 200
        else {
            throw AWSLogsProviderError.credentialsEndpointFailed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(Response.self, from: data) else {
            throw AWSLogsProviderError.credentialsEndpointFailed
        }
        return AWSCredentialIdentity(
            accessKey: decoded.accessKeyID,
            secret: decoded.secretAccessKey,
            expiration: decoded.expiration,
            sessionToken: decoded.token
        )
    }
}
