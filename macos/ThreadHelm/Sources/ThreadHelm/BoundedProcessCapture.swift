//
//  BoundedProcessCapture.swift
//  ThreadHelm
//
//  模块职责：为短生命周期 CLI 调用提供非阻塞输出读取和有上限的进程
//  收尾，避免子进程忽略 SIGTERM 或后代进程持续持有 pipe 时永久阻塞。
//

import Darwin
import Foundation

enum ProcessOutputCaptureTermination: Equatable {
    case exited
    case completed
    case timedOut
    case outputClosed
    case outputLimitExceeded
    case readFailed
}

struct ProcessOutputCaptureResult {
    let data: Data
    let termination: ProcessOutputCaptureTermination
}

func captureProcessOutput(
    process: Process,
    output: FileHandle,
    timeout: TimeInterval,
    terminationGracePeriod: TimeInterval = 0.25,
    maximumOutputBytes: Int,
    onChunk: ((Data) -> Bool)? = nil
) -> ProcessOutputCaptureResult {
    let descriptor = output.fileDescriptor
    let originalFlags = fcntl(descriptor, F_GETFL)
    if originalFlags >= 0 {
        _ = fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK)
    }
    defer {
        if originalFlags >= 0 {
            _ = fcntl(descriptor, F_SETFL, originalFlags)
        }
    }

    let deadline = Date().addingTimeInterval(max(0.01, timeout))
    let byteLimit = max(1, maximumOutputBytes)
    var captured = Data()
    var readBuffer = [UInt8](repeating: 0, count: 16_384)

    func drainAvailableOutput() -> ProcessOutputCaptureTermination? {
        while true {
            let count = readBuffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                let availableCapacity = byteLimit - captured.count
                guard count <= availableCapacity else {
                    if availableCapacity > 0 {
                        captured.append(
                            contentsOf: readBuffer.prefix(availableCapacity)
                        )
                    }
                    return .outputLimitExceeded
                }
                let chunk = Data(readBuffer.prefix(count))
                captured.append(chunk)
                if let onChunk, !onChunk(chunk) {
                    return .completed
                }
                continue
            }
            if count == 0 {
                return .outputClosed
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return nil
            }
            return .readFailed
        }
    }

    while true {
        if let termination = drainAvailableOutput() {
            if termination == .outputClosed {
                if waitForProcessExit(
                    process,
                    timeout: terminationGracePeriod
                ) {
                    return ProcessOutputCaptureResult(
                        data: captured,
                        termination: .exited
                    )
                }
            }
            _ = stopProcess(
                process,
                gracePeriod: terminationGracePeriod
            )
            return ProcessOutputCaptureResult(
                data: captured,
                termination: termination
            )
        }

        if !process.isRunning {
            _ = drainAvailableOutput()
            return ProcessOutputCaptureResult(
                data: captured,
                termination: .exited
            )
        }

        if Date() >= deadline {
            _ = stopProcess(
                process,
                gracePeriod: terminationGracePeriod
            )
            _ = drainAvailableOutput()
            return ProcessOutputCaptureResult(
                data: captured,
                termination: .timedOut
            )
        }
        usleep(10_000)
    }
}

@discardableResult
func stopProcess(
    _ process: Process,
    gracePeriod: TimeInterval = 0.25
) -> Bool {
    guard process.isRunning else { return true }
    process.terminate()
    if waitForProcessExit(process, timeout: gracePeriod) {
        return true
    }
    if process.isRunning {
        _ = kill(process.processIdentifier, SIGKILL)
    }
    return waitForProcessExit(process, timeout: gracePeriod)
}

private func waitForProcessExit(
    _ process: Process,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(max(0.01, timeout))
    while process.isRunning, Date() < deadline {
        usleep(10_000)
    }
    return !process.isRunning
}
