//
//  JSONLFramer.swift
//  ThreadHelm
//
//  模块职责：纯、无 I/O 的 JSONL 记录切分状态机。
//
//  framer 不做文件 I/O、不持有 FileHandle、不解析 JSON；FileHandle 层只负责
//  1 MiB 分块读取与前后 lstat 身份校验，把 (chunk, chunkStart) 交给 feed。
//
//  核心不变量：
//  - committedOffset：只推进到完整 LF 记录之后；绝不在超长未完成行内。
//  - pending：自 committedOffset 起的未完成行字节（不推进磁盘 checkpoint）。
//  - 超长记录的两种形态都作有界跳过：
//      a) 一条带 LF 的完整行 > record cap → 跳过该行并计数一次；
//      b) 无 LF 未完成行累计 > record cap → 进入 discard 只扫后续 LF，找到后
//         committedOffset 推进到 LF 之后，从该处恢复。
//  - sourceOrder 单调递增，绝不复位。
//  - 偏移一律用 feed(chunkStart) 的绝对字节数计算，不把旧偏移重复相加。
//

import Foundation

struct JSONLFramerRecord: Equatable {
    let startOffset: UInt64
    let byteCount: Int
    let sourceOrder: UInt64
    let data: Data

    var endOffset: UInt64 { startOffset + UInt64(byteCount) }
}

struct JSONLFramer {
    let maximumRecordBytes: Int
    /// 是否所有未完成字节都来自一或多个源文件。
    private(set) var committedOffset: UInt64 = 0
    private(set) var pending: Data = Data()
    private(set) var discarding = false
    private(set) var skippedOversized = 0
    private(set) var sourceOrder: UInt64 = 0
    /// 最近一个 feed 产出的记录（累计到同一帧状态里；调用方在多个 feed 上
    /// 全量收集，因此这里不区分 pass）。
    private(set) var records: [JSONLFramerRecord] = []

    init(
        maximumRecordBytes: Int,
        committedOffset: UInt64 = 0,
        sourceOrder: UInt64 = 0
    ) {
        self.maximumRecordBytes = maximumRecordBytes
        self.committedOffset = committedOffset
        self.sourceOrder = sourceOrder
    }

    /// 结束一次 pass：有未完成尾行时 checkpoint 停在最后完整 LF 后。
    /// 返回 true 表示达到安全边界（未在超长行 discard 中）。
    @discardableResult
    mutating func finishPass() -> Bool {
        !discarding
    }

    /// 丢弃累积 pending 并重置状态（例如身份变化后重建）。调用方负责把
    /// committedOffset 复位到新的安全起点。
    mutating func resetPending() {
        pending.removeAll(keepingCapacity: true)
        discarding = false
    }

    /// 喂一块连续字节。chunkStart 是该块第一个字节的绝对文件偏移。
    mutating func feed(_ chunk: Data, chunkStart: UInt64) {
        guard !chunk.isEmpty else { return }

        if discarding {
            feedDiscarding(chunk, chunkStart: chunkStart)
            return
        }

        // 正常路径：pending 自 committedOffset 起，append 后整体按 LF 切割。
        var buffer = pending
        let pendingStart = committedOffset
        buffer.append(chunk)
        pending.removeAll(keepingCapacity: true)

        var cursor = 0
        while cursor < buffer.count {
            guard let newline = buffer[cursor...].firstIndex(of: 0x0A) else {
                break
            }
            let end = buffer.index(after: newline)
            let size = buffer.distance(from: cursor, to: end)
            let absoluteStart = pendingStart + UInt64(cursor)
            sourceOrder &+= 1
            if size <= maximumRecordBytes {
                records.append(JSONLFramerRecord(
                    startOffset: absoluteStart,
                    byteCount: size,
                    sourceOrder: sourceOrder,
                    data: Data(buffer[cursor..<end])
                ))
                committedOffset = pendingStart + UInt64(end)
            } else {
                // 形态 a：带 LF 的完整行超过 cap，跳过并计数一次。
                skippedOversized += 1
                committedOffset = pendingStart + UInt64(end)
            }
            cursor = end
        }

        if cursor < buffer.count {
            // 剩余未完成行；若累计超过 cap 但尚未见 LF，转入形态 b 的丢弃。
            if buffer.count - cursor > maximumRecordBytes {
                skippedOversized += 1
                discarding = true
                pending.removeAll(keepingCapacity: true)
            } else {
                pending = Data(buffer[cursor..<buffer.count])
            }
        }
    }

    private mutating func feedDiscarding(_ chunk: Data, chunkStart: UInt64) {
        // 只扫 LF 以结束超长行。
        guard let lf = chunk.firstIndex(of: 0x0A) else {
            // 仍被超长行占据，跳过本块。
            return
        }
        let keep = chunk.index(after: lf)
        committedOffset = chunkStart + UInt64(keep)
        discarding = false
        // LF 之后若有内容，纳入 pending，再正常走一次 feed。
        let tail = chunk.subdata(in: keep..<chunk.count)
        if !tail.isEmpty {
            pending = tail
            // 对尾段复用正常路径：feed 内容但偏移要基于 committedOffset。
            feedNormalTail(tail, afterAbsolute: committedOffset)
        }
    }

    private mutating func feedNormalTail(_ tail: Data, afterAbsolute absStart: UInt64) {
        var buffer = tail
        var cursor = 0
        while cursor < buffer.count {
            guard let newline = buffer[cursor...].firstIndex(of: 0x0A) else { break }
            let end = buffer.index(after: newline)
            let size = buffer.distance(from: cursor, to: end)
            let absoluteStart = absStart + UInt64(cursor)
            sourceOrder &+= 1
            if size <= maximumRecordBytes {
                records.append(JSONLFramerRecord(
                    startOffset: absoluteStart,
                    byteCount: size,
                    sourceOrder: sourceOrder,
                    data: Data(buffer[cursor..<end])
                ))
            } else {
                skippedOversized += 1
            }
            committedOffset = absStart + UInt64(end)
            cursor = end
        }
        if cursor < buffer.count {
            pending = buffer.subdata(in: cursor..<buffer.count)
        } else {
            pending.removeAll(keepingCapacity: true)
        }
    }

    /// 清空已产出记录（如被调用方消费后）。
    mutating func clearRecords() {
        records.removeAll(keepingCapacity: true)
    }
}