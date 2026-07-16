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

import ContainerizationExtras
import ContainerizationOS
import Foundation
import Logging

public struct ProcessIO: Sendable {
    let stdin: Pipe?
    let stdout: Pipe?
    let stderr: Pipe?
    var ioTracker: IoTracker?

    static let signalSet: [Int32] = [
        SIGTERM,
        SIGINT,
        SIGUSR1,
        SIGUSR2,
        SIGWINCH,
    ]

    public struct IoTracker: Sendable {
        let stream: AsyncStream<Void>
        let cont: AsyncStream<Void>.Continuation
        let configuredStreams: Int
    }

    public let stdio: [FileHandle?]

    public let console: Terminal?

    private let detachKeyMatcher: DetachKeyMatcher?

    public static func create(
        tty: Bool,
        interactive: Bool,
        detach: Bool,
        detachKeys: DetachKeySequence? = nil,
    ) throws -> ProcessIO {
        let current: Terminal? = try {
            if !tty || !interactive {
                return nil
            }
            let current = try Terminal(descriptor: STDIN_FILENO)
            try current.setraw()
            return current
        }()

        var stdio = [FileHandle?](repeating: nil, count: 3)
        let detachKeyMatcher = tty && interactive ? detachKeys.map { DetachKeyMatcher(sequence: $0) } : nil

        let stdin: Pipe? = {
            if !interactive {
                return nil
            }
            return Pipe()
        }()

        let stdout: Pipe? = {
            if detach {
                return nil
            }
            return Pipe()
        }()

        var configuredStreams = 0
        let (stream, cc) = AsyncStream<Void>.makeStream()
        if let stdout {
            configuredStreams += 1

            stdio[1] = stdout.fileHandleForWriting
            let pout = FileHandle.standardOutput
            let rout = stdout.fileHandleForReading
            rout.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    rout.readabilityHandler = nil
                    cc.yield()
                    return
                }
                try! pout.write(contentsOf: data)
            }
        }

        let stderr: Pipe? = {
            if detach || tty {
                return nil
            }
            return Pipe()
        }()
        if let stderr {
            configuredStreams += 1
            let perr: FileHandle = .standardError
            let rerr = stderr.fileHandleForReading
            rerr.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    rerr.readabilityHandler = nil
                    cc.yield()
                    return
                }
                try! perr.write(contentsOf: data)
            }
            stdio[2] = stderr.fileHandleForWriting
        }

        if let stdin {
            let pin = FileHandle.standardInput
            let stdinOSFile = OSFile(fd: pin.fileDescriptor)
            let pipeOSFile = OSFile(fd: stdin.fileHandleForWriting.fileDescriptor)
            try stdinOSFile.makeNonBlocking()
            nonisolated(unsafe) let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(getpagesize()))

            pin.readabilityHandler = { _ in
                Self.streamStdin(
                    from: stdinOSFile,
                    to: pipeOSFile,
                    buffer: buf,
                    detachKeyMatcher: detachKeyMatcher,
                ) {
                    pin.readabilityHandler = nil
                    buf.deallocate()
                    try? stdin.fileHandleForWriting.close()
                } onDetach: {
                    pin.readabilityHandler = nil
                    buf.deallocate()
                    try? stdin.fileHandleForWriting.close()
                    for pipe in [stdout, stderr].compactMap({ $0 }) {
                        let reader = pipe.fileHandleForReading
                        reader.readabilityHandler = nil
                        try? reader.close()
                    }
                }
            }
            stdio[0] = stdin.fileHandleForReading
        }

        var ioTracker: IoTracker? = nil
        if configuredStreams > 0 {
            ioTracker = .init(stream: stream, cont: cc, configuredStreams: configuredStreams)
        }

        return .init(
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            ioTracker: ioTracker,
            stdio: stdio,
            console: current,
            detachKeyMatcher: detachKeyMatcher
        )
    }

    public func handleProcess(process: ClientProcess, log: Logger) async throws -> Int32 {
        try await handle(process: process, log: log, start: true)
    }

    /// Handles streams, terminal resize, and signal forwarding for a process
    /// that has already been started by another client.
    public func handleAttachedProcess(
        process: ClientProcess,
        log: Logger,
        proxySignals: Bool = true,
    ) async throws -> Int32 {
        try await handle(process: process, log: log, start: false, proxySignals: proxySignals)
    }

    private func handle(
        process: ClientProcess,
        log: Logger,
        start: Bool,
        proxySignals: Bool = true,
    ) async throws -> Int32 {
        let signals = proxySignals ? AsyncSignalHandler.create(notify: Self.signalSet) : nil
        defer { detachKeyMatcher?.finish() }
        return try await withThrowingTaskGroup(of: Int32?.self, returning: Int32.self) { group in
            if start {
                try await process.start()
            }
            try closeAfterStart()

            let waitAdded = group.addTaskUnlessCancelled {
                let code: Int32
                do {
                    code = try await process.wait()
                } catch {
                    if detachKeyMatcher?.isDetached == true {
                        return 0
                    }
                    throw error
                }
                try await wait()
                return code
            }

            guard waitAdded else {
                group.cancelAll()
                return -1
            }

            if let detachKeyMatcher {
                _ = group.addTaskUnlessCancelled {
                    for await _ in detachKeyMatcher.stream {
                        process.disconnect()
                        return 0
                    }
                    return nil
                }
            }

            if let current = console {
                let size = try current.size
                // It's supremely possible the process could've exited already. We shouldn't treat
                // this as fatal.
                try? await process.resize(size)
                _ = group.addTaskUnlessCancelled {
                    let winchHandler = AsyncSignalHandler.create(notify: [SIGWINCH])
                    for await _ in winchHandler.signals {
                        do {
                            try await process.resize(try current.size)
                        } catch {
                            log.error(
                                "failed to send terminal resize event",
                                metadata: [
                                    "error": "\(error)"
                                ]
                            )
                        }
                    }
                    return nil
                }
            } else if let signals {
                _ = group.addTaskUnlessCancelled {
                    for await sig in signals.signals {
                        do {
                            try await process.kill(sig)
                        } catch {
                            log.error(
                                "failed to send signal",
                                metadata: [
                                    "signal": "\(sig)",
                                    "error": "\(error)",
                                ]
                            )
                        }
                    }
                    return nil
                }
            }

            while true {
                let result = try await group.next()
                if result == nil {
                    return -1
                }
                let status = result!
                if let status {
                    group.cancelAll()
                    return status
                }
            }
            return -1
        }
    }

    public func closeAfterStart() throws {
        try stdin?.fileHandleForReading.close()
        try stdout?.fileHandleForWriting.close()
        try stderr?.fileHandleForWriting.close()
    }

    public func close() throws {
        try console?.reset()
    }

    public func wait() async throws {
        guard let ioTracker = self.ioTracker else {
            return
        }
        do {
            try await Timeout.run(seconds: 3) {
                var counter = ioTracker.configuredStreams
                for await _ in ioTracker.stream {
                    counter -= 1
                    if counter == 0 {
                        ioTracker.cont.finish()
                        break
                    }
                }
            }
        } catch {
            throw error
        }
    }

    static func streamStdin(
        from: OSFile,
        to: OSFile,
        buffer: UnsafeMutableBufferPointer<UInt8>,
        detachKeyMatcher: DetachKeyMatcher? = nil,
        onErrorOrEOF: () -> Void,
        onDetach: () -> Void,
    ) {
        while true {
            let (bytesRead, action) = from.read(buffer)
            if bytesRead > 0 {
                let view = UnsafeMutableBufferPointer(
                    start: buffer.baseAddress,
                    count: bytesRead
                )

                if let detachKeyMatcher {
                    let result = detachKeyMatcher.filter(view)
                    if !result.forwarded.isEmpty {
                        var forwarded = result.forwarded
                        let (bytesWritten, _) = forwarded.withUnsafeMutableBufferPointer { output in
                            to.write(output)
                        }
                        if bytesWritten != result.forwarded.count {
                            onErrorOrEOF()
                            return
                        }
                    }
                    if result.detached {
                        onDetach()
                        return
                    }
                    continue
                }

                let (bytesWritten, _) = to.write(view)
                if bytesWritten != bytesRead {
                    onErrorOrEOF()
                    return
                }
            }

            switch action {
            case .error(_), .eof, .brokenPipe:
                onErrorOrEOF()
                return
            case .again:
                return
            case .success:
                break
            }
        }
    }
}

final class DetachKeyMatcher: @unchecked Sendable {
    struct Result: Equatable {
        let forwarded: [UInt8]
        let detached: Bool
    }

    let stream: AsyncStream<Void>

    private let continuation: AsyncStream<Void>.Continuation
    private let sequence: [UInt8]
    private let lock = NSLock()
    private var pending = [UInt8]()
    private var detached = false

    init(sequence: DetachKeySequence) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.stream = stream
        self.continuation = continuation
        self.sequence = sequence.bytes
    }

    func filter<S: Sequence>(_ input: S) -> Result where S.Element == UInt8 {
        lock.lock()
        if detached {
            lock.unlock()
            return .init(forwarded: [], detached: true)
        }
        var forwarded = [UInt8]()
        var completed = false
        for byte in input {
            pending.append(byte)
            while !sequence.starts(with: pending) {
                forwarded.append(pending.removeFirst())
            }
            if pending == sequence {
                pending.removeAll(keepingCapacity: true)
                detached = true
                completed = true
                break
            }
        }
        lock.unlock()

        if completed {
            continuation.yield()
        }
        return .init(forwarded: forwarded, detached: completed)
    }

    var isDetached: Bool { lock.withLock { detached } }

    func finish() {
        continuation.finish()
    }
}

public struct OSFile: Sendable {
    private let fd: Int32

    public enum IOAction: Equatable {
        case eof
        case again
        case success
        case brokenPipe
        case error(_ errno: Int32)
    }

    public init(fd: Int32) {
        self.fd = fd
    }

    public init(handle: FileHandle) {
        self.fd = handle.fileDescriptor
    }

    func makeNonBlocking() throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1 else {
            throw POSIXError.fromErrno()
        }

        if fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1 {
            throw POSIXError.fromErrno()
        }
    }

    func write(_ buffer: UnsafeMutableBufferPointer<UInt8>) -> (wrote: Int, action: IOAction) {
        if buffer.count == 0 {
            return (0, .success)
        }

        var bytesWrote: Int = 0
        while true {
            let n = Darwin.write(
                self.fd,
                buffer.baseAddress!.advanced(by: bytesWrote),
                buffer.count - bytesWrote
            )
            if n == -1 {
                if errno == EAGAIN || errno == EIO {
                    return (bytesWrote, .again)
                }
                return (bytesWrote, .error(errno))
            }

            if n == 0 {
                return (bytesWrote, .brokenPipe)
            }

            bytesWrote += n
            if bytesWrote < buffer.count {
                continue
            }
            return (bytesWrote, .success)
        }
    }

    func read(_ buffer: UnsafeMutableBufferPointer<UInt8>) -> (read: Int, action: IOAction) {
        if buffer.count == 0 {
            return (0, .success)
        }

        var bytesRead: Int = 0
        while true {
            let n = Darwin.read(
                self.fd,
                buffer.baseAddress!.advanced(by: bytesRead),
                buffer.count - bytesRead
            )
            if n == -1 {
                if errno == EAGAIN || errno == EIO {
                    return (bytesRead, .again)
                }
                return (bytesRead, .error(errno))
            }

            if n == 0 {
                return (bytesRead, .eof)
            }

            bytesRead += n
            if bytesRead < buffer.count {
                continue
            }
            return (bytesRead, .success)
        }
    }
}
