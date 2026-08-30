//
//  TaskProgressSelfTest.swift
//  ThreadHelm
//
//  模块职责：--self-test-task-progress 自测（阶段一与入口）——Codex 任务
//  生命周期解析、安全活动摘要、列表排序/去重/滚动数据源、标题解析、
//  深度链接、点击/滚动/刷新命中测试、活动预览与悬停回调、已完成任务
//  可见性过滤。阶段二见 TaskProgressSelfTestPhase2.swift。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func runTaskProgressSelfTest() -> Never {
    let now = Date()
    let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
    runAgentIntegrationSelfTest()
    runTaskProgressSelfTestPhase1(now: now, started: started)
    runCodexClaudeTranscriptProviderRegressionSelfTest(now: now, started: started)
    runCodexClaudeAtomicReplaceCacheSelfTest()
    runCodexTailMetadataBackfillSelfTest(now: now, started: started)
    runCodexCompletedItemFormatSelfTest()
    runCodexUnavailableRolloutRootSelfTest()
    runTaskProgressSelfTestPhase2(now: now, started: started)
    runTaskRepositoryContextSelfTest()
    runTaskProgressRefreshGateSelfTest()
    guard runTaskProgressRefreshStabilityRegressionSelfTest() else {
        fputs("task progress refresh reader stability failed\n", stderr)
        exit(1)
    }
    runClaudeDesktopTaskDiscoverySelfTest()
    runClaudeAgentsCommandTimeoutSelfTest()
    runRuntimeHealthWriterFailureSelfTest()
    runDiscoveryCacheAndAutoIntegrationBackoffSelfTest()
    print("task-progress-self-test: agent-core=5+builtin+sixth; agent-registry=dedupe+fail-open; agent-reducer=duplicate+out-of-order+stable-tie; lifecycle=7/7; safe-activity=pass; updated-sort=pass; active-scroll=pass; terminal-backfill=pass; title=1/1; index=1/1; deep-link=2/2; completed-unread=pass; read-state=6/6; top-level-filter=explicit-visible+automation-safe; task-dedup=pass; full-collection=pass; codex-cwd=tail-metadata-backfill; codex-root-denial=no-retry+restart-recovery; provider-atomic-replace=codex+claude; events=all-safe; privacy=pass; open-results=typed+count-only+0600; attention=allowlist+60s+foreground; attention-feedback=count-only+0600; refresh-gate=single-flight+generation; refresh-reader=reuse; repository-context=git+worktree+checks+commit-status+unknown+cache+isolated-env+fixed-host+slash-remote; claude-desktop=local-session+navigation; claude-agents-timeout=bounded; applescript-timeout=bounded; runtime-health=dynamic-only+failure-logged-once; system-symbols=6/6; claude-source=pass; claude-public-output=pass; claude-agent-merge=order-independent+dead-pid; claude-navigation=identity-first+pid-reuse+dead-process+deleted-session+moved-project+same-cwd; claude-entry-points=same-cwd; claude-terminal-focus=pid-chain+3-hosts; claude-iterm-resume=2/2; claude-otty=3/3; claude-resume=2/2; discovery-cache=ttl+invalidate; auto-integration-backoff=5m/15m/60m+min-interval-survives-success; auto-integration-accounting=7/7; auto-integration-candidate=dual-gate+filter+single-per-round")
    exit(0)
}

private func runTaskRepositoryContextSelfTest() {
    func fail(_ message: String) -> Never {
        fputs("task repository context self-test failed: \(message)\n", stderr)
        exit(1)
    }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }
    func json(_ value: String) -> Data {
        guard let data = value.data(using: .utf8) else {
            fail("JSON fixture encoding")
        }
        return data
    }

    let sha = String(repeating: "a", count: 40)
    let cleanPorcelain = """
    # branch.oid \(sha)
    # branch.head main
    """
    guard let clean = parsedTaskGitStatus(
        repositoryRoot: "/tmp/threadhelm-repository",
        porcelainV2: cleanPorcelain,
        checkoutKind: .checkout
    ) else { fail("clean porcelain parsing") }
    expect(clean.branch == "main", "clean branch")
    expect(!clean.isDetached, "clean detached state")
    expect(!clean.isDirty, "clean dirty state")
    expect(clean.upstreamName == nil, "clean upstream absence")
    expect(clean.aheadCount == nil && clean.behindCount == nil, "clean counts")
    expect(clean.headSHA == sha, "clean full SHA")
    expect(clean.headShortSHA == String(repeating: "a", count: 12), "short SHA")

    let upstreamPorcelain = """
    # branch.oid \(sha)
    # branch.head feature/truth
    # branch.upstream origin/feature/truth
    # branch.ab +2 -3
    1 .M N... 100644 100644 100644 \(sha) \(sha) source.swift
    """
    guard let upstream = parsedTaskGitStatus(
        repositoryRoot: "/tmp/threadhelm-repository",
        porcelainV2: upstreamPorcelain,
        checkoutKind: .linkedWorktree
    ) else { fail("upstream porcelain parsing") }
    expect(upstream.branch == "feature/truth", "upstream branch")
    expect(upstream.checkoutKind == .linkedWorktree, "linked worktree parsing")
    expect(upstream.isDirty, "dirty parsing")
    expect(upstream.upstreamName == "origin/feature/truth", "upstream name")
    expect(upstream.aheadCount == 2 && upstream.behindCount == 3, "ahead/behind")

    let detachedPorcelain = """
    # branch.oid \(sha)
    # branch.head (detached)
    """
    guard let detached = parsedTaskGitStatus(
        repositoryRoot: "/tmp/threadhelm-repository",
        porcelainV2: detachedPorcelain,
        checkoutKind: .checkout
    ) else { fail("detached porcelain parsing") }
    expect(detached.isDetached && detached.branch == nil, "detached identity")
    expect(
        parsedTaskGitStatus(
            repositoryRoot: "/tmp/threadhelm-repository",
            porcelainV2: cleanPorcelain + "\n# branch.ab +x -1",
            checkoutKind: .checkout
        ) == nil,
        "malformed ahead/behind must fail closed"
    )
    expect(
        parsedTaskGitStatus(
            repositoryRoot: "/tmp/threadhelm-repository",
            porcelainV2: "# branch.oid abcdef1\n# branch.head main",
            checkoutKind: .checkout
        ) == nil,
        "short object ID must fail closed"
    )

    expect(
        taskGitCheckoutKind(
            repositoryRoot: "/tmp/threadhelm-repository",
            gitDirectory: ".git",
            commonGitDirectory: ".git"
        ) == .checkout,
        "ordinary checkout detection"
    )
    expect(
        taskGitCheckoutKind(
            repositoryRoot: "/tmp/threadhelm-linked",
            gitDirectory: "/tmp/threadhelm-repository/.git/worktrees/linked",
            commonGitDirectory: "/tmp/threadhelm-repository/.git"
        ) == .linkedWorktree,
        "linked worktree detection"
    )

    let scpRemote = "git" + "@" + "github.com:OpenAI/Codex.git"
    let sshRemote = "ssh://git" + "@" + "github.com/OpenAI/Codex.git"
    let credentialRemote = "https://token" + "@" + "github.com/OpenAI/Codex.git"
    expect(
        githubRepositorySlug(from: "https://github.com/OpenAI/Codex.git")
            == "OpenAI/Codex",
        "HTTPS GitHub remote"
    )
    expect(
        githubRepositorySlug(from: scpRemote) == "OpenAI/Codex",
        "SCP GitHub remote"
    )
    expect(
        githubRepositorySlug(from: sshRemote) == "OpenAI/Codex",
        "SSH GitHub remote"
    )
    for unsafeRemote in [
        credentialRemote,
        "https://gitlab.com/OpenAI/Codex.git",
        "https://github.com/OpenAI/Codex/extra.git",
        "https://github.com/OpenAI/Codex.git?credential=hidden",
        "https://github.com/../Codex.git",
        "https://github.com/OpenAI/Codex.git\ninvalid",
        "git" + "@" + "github.com:/OpenAI/Codex.git",
    ] {
        expect(
            githubRepositorySlug(from: unsafeRemote) == nil,
            "unsafe GitHub remote accepted"
        )
    }

    let sanitizedEnvironment = taskStatusCommandEnvironment(inheriting: [
        "PATH": "/usr/bin",
        "GH_HOST": "github.enterprise.invalid",
        "GIT_DIR": "/tmp/wrong.git",
        "GIT_WORK_TREE": "/tmp/wrong-worktree",
        "GIT_INDEX_FILE": "/tmp/wrong-index",
        "GIT_COMMON_DIR": "/tmp/wrong-common",
        "GIT_OBJECT_DIRECTORY": "/tmp/wrong-objects",
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "core.worktree",
        "GIT_CONFIG_VALUE_0": "/tmp/wrong-config-worktree",
    ])
    for unsafeKey in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_KEY_0",
        "GIT_CONFIG_VALUE_0",
    ] {
        expect(
            sanitizedEnvironment[unsafeKey] == nil,
            "inherited \(unsafeKey) must be removed"
        )
    }
    expect(sanitizedEnvironment["PATH"] == "/usr/bin", "safe environment kept")
    expect(
        sanitizedEnvironment["GIT_OPTIONAL_LOCKS"] == "0"
            && sanitizedEnvironment["GIT_PAGER"] == "cat"
            && sanitizedEnvironment["GIT_TERMINAL_PROMPT"] == "0",
        "controlled Git environment"
    )

    guard let checkArguments = taskCheckStatusCommandArguments(
        githubRepository: "OpenAI/Codex",
        headSHA: sha
    ) else { fail("GitHub check arguments") }
    expect(
        Array(checkArguments.prefix(4))
            == ["api", "--hostname", "github.com", "-H"],
        "GitHub checks must pin github.com"
    )
    expect(
        taskCheckStatusCommandArguments(
            githubRepository: "github.enterprise.invalid/OpenAI/Codex",
            headSHA: sha
        ) == nil,
        "unsafe GitHub check repository"
    )
    guard let commitStatusArguments = taskCommitStatusCommandArguments(
        githubRepository: "OpenAI/Codex",
        headSHA: sha
    ) else { fail("GitHub commit status arguments") }
    expect(
        Array(commitStatusArguments.prefix(4))
            == ["api", "--hostname", "github.com", "-H"],
        "GitHub commit statuses must pin github.com"
    )
    expect(
        commitStatusArguments.contains(
            "repos/OpenAI/Codex/commits/\(sha)/status?per_page=100"
        ),
        "GitHub commit status endpoint"
    )
    expect(
        taskCommitStatusCommandArguments(
            githubRepository: "github.enterprise.invalid/OpenAI/Codex",
            headSHA: sha
        ) == nil,
        "unsafe GitHub commit status repository"
    )

    guard let passed = taskCheckStatus(from: json("""
    {"total_count":2,"check_runs":[
      {"status":"completed","conclusion":"success"},
      {"status":"completed","conclusion":"success"}
    ]}
    """)) else { fail("passed checks parsing") }
    expect(
        passed == TaskCheckStatus(
            state: .passed,
            totalCount: 2,
            successCount: 2,
            failureCount: 0,
            pendingCount: 0,
            inconclusiveCount: 0
        ),
        "passed checks counts"
    )

    guard let mixed = taskCheckStatus(from: json("""
    {"total_count":4,"check_runs":[
      {"status":"completed","conclusion":"success"},
      {"status":"completed","conclusion":"failure"},
      {"status":"in_progress","conclusion":null},
      {"status":"completed","conclusion":"skipped"}
    ]}
    """)) else { fail("mixed checks parsing") }
    expect(mixed.state == .failed, "failed checks priority")
    expect(mixed.successCount == 1, "mixed success count")
    expect(mixed.failureCount == 1, "mixed failure count")
    expect(mixed.pendingCount == 1, "mixed pending count")
    expect(mixed.inconclusiveCount == 1, "mixed inconclusive count")

    guard let inconclusive = taskCheckStatus(from: json("""
    {"total_count":4,"check_runs":[
      {"status":"completed","conclusion":"cancelled"},
      {"status":"completed","conclusion":"neutral"},
      {"status":"completed","conclusion":"skipped"},
      {"status":"completed","conclusion":"stale"}
    ]}
    """)) else { fail("inconclusive checks parsing") }
    expect(inconclusive.state == .inconclusive, "inconclusive state")
    expect(inconclusive.inconclusiveCount == 4, "inconclusive count")

    guard let noChecks = taskCheckStatus(from: json(
        #"{"total_count":0,"check_runs":[]}"#
    )) else { fail("zero checks parsing") }
    expect(noChecks == .unknown, "zero checks must be unknown")
    expect(
        taskCheckStatus(from: json(
            #"{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"}]}"#
        )) == nil,
        "paginated checks must fail closed"
    )
    expect(
        taskCheckStatus(from: json(
            #"{"total_count":1,"check_runs":[{"status":"new_status","conclusion":null}]}"#
        )) == nil,
        "unknown check status must fail closed"
    )
    expect(
        taskCheckStatus(from: json(
            #"{"total_count":1,"check_runs":[{"status":"completed","conclusion":"new_conclusion"}]}"#
        )) == nil,
        "unknown check conclusion must fail closed"
    )

    guard let passedCommitStatuses = taskCommitStatus(from: json("""
    {"total_count":2,"statuses":[
      {"state":"success"},
      {"state":"success"}
    ]}
    """)) else { fail("passed commit statuses parsing") }
    expect(
        passedCommitStatuses == TaskCheckStatus(
            state: .passed,
            totalCount: 2,
            successCount: 2,
            failureCount: 0,
            pendingCount: 0,
            inconclusiveCount: 0
        ),
        "passed commit status counts"
    )

    guard let failedCommitStatuses = taskCommitStatus(from: json("""
    {"total_count":2,"statuses":[
      {"state":"success"},
      {"state":"failure"}
    ]}
    """)) else { fail("failed commit statuses parsing") }
    expect(failedCommitStatuses.state == .failed, "failed commit status state")
    expect(failedCommitStatuses.failureCount == 1, "failed commit status count")

    guard let errorCommitStatus = taskCommitStatus(from: json(
        #"{"total_count":1,"statuses":[{"state":"error"}]}"#
    )) else { fail("error commit status parsing") }
    expect(errorCommitStatus.state == .failed, "error commit status state")
    expect(errorCommitStatus.failureCount == 1, "error commit status count")

    guard let pendingCommitStatus = taskCommitStatus(from: json(
        #"{"total_count":1,"statuses":[{"state":"pending"}]}"#
    )) else { fail("pending commit status parsing") }
    expect(pendingCommitStatus.state == .pending, "pending commit status state")
    expect(pendingCommitStatus.pendingCount == 1, "pending commit status count")

    guard let noCommitStatuses = taskCommitStatus(from: json(
        #"{"state":"pending","total_count":0,"statuses":[]}"#
    )) else { fail("zero commit statuses parsing") }
    expect(noCommitStatuses == .unknown, "zero commit statuses must be unknown")
    expect(
        taskCommitStatus(from: json(
            #"{"total_count":2,"statuses":[{"state":"success"}]}"#
        )) == nil,
        "paginated commit statuses must fail closed"
    )
    expect(
        taskCommitStatus(from: json(
            #"{"total_count":1,"statuses":[{"state":"new_state"}]}"#
        )) == nil,
        "unknown commit status must fail closed"
    )

    expect(
        combinedTaskCheckStatus(
            checkRuns: passed,
            commitStatuses: failedCommitStatuses
        ) == TaskCheckStatus(
            state: .failed,
            totalCount: 4,
            successCount: 3,
            failureCount: 1,
            pendingCount: 0,
            inconclusiveCount: 0
        ),
        "failed commit status must override passed check runs"
    )
    expect(
        combinedTaskCheckStatus(
            checkRuns: inconclusive,
            commitStatuses: pendingCommitStatus
        ).state == .pending,
        "pending commit status must override inconclusive check runs"
    )
    expect(
        combinedTaskCheckStatus(
            checkRuns: inconclusive,
            commitStatuses: passedCommitStatuses
        ).state == .inconclusive,
        "inconclusive check runs must override passed commit statuses"
    )
    expect(
        combinedTaskCheckStatus(
            checkRuns: noChecks,
            commitStatuses: noCommitStatuses
        ) == .unknown,
        "zero checks and commit statuses must be unknown"
    )

    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let duplicateDirectory = "/tmp/threadhelm-repository-cache-shared"
    var cacheItems = [
        TaskProgressItem(
            title: "cache one",
            kind: .running,
            threadID: "cache-one",
            workingDirectory: duplicateDirectory
        ),
        TaskProgressItem(
            title: "cache two",
            kind: .running,
            threadID: "cache-two",
            workingDirectory: duplicateDirectory
        ),
    ]
    for index in 0..<9 {
        cacheItems.append(
            TaskProgressItem(
                title: "cache \(index)",
                kind: .running,
                threadID: "cache-\(index)",
                workingDirectory: "/tmp/threadhelm-repository-cache-\(index)"
            )
        )
    }
    var probeCounts: [String: Int] = [:]
    let mapped = taskRepositoryEvidenceByTaskIdentity(
        items: cacheItems,
        previous: [:],
        now: now,
        maximumDirectories: 8
    ) { directory, _, observedAt in
        probeCounts[directory, default: 0] += 1
        return TaskRepositoryEvidence(
            workingDirectory: directory,
            gitStatus: nil,
            checkStatus: .unknown,
            gitObservedAt: observedAt,
            checksObservedAt: observedAt
        )
    }
    expect(probeCounts.count == 8, "repository probe limit")
    expect(probeCounts[duplicateDirectory] == 1, "same-directory deduplication")
    expect(mapped[cacheItems[0].identityKey] == mapped[cacheItems[1].identityKey],
           "same-directory task mapping")
    expect(mapped.count == 9, "probe limit identity mapping")

    let cachedGitStatus = TaskGitStatus(
        repositoryRoot: duplicateDirectory,
        branch: "main",
        isDetached: false,
        checkoutKind: .checkout,
        isDirty: false,
        upstreamName: nil,
        aheadCount: nil,
        behindCount: nil,
        headSHA: sha,
        githubRepository: nil
    )
    let cachedEvidence = TaskRepositoryEvidence(
        workingDirectory: duplicateDirectory,
        gitStatus: cachedGitStatus,
        checkStatus: .unknown,
        gitObservedAt: now,
        checksObservedAt: now
    )
    let cacheHit = probeTaskRepositoryEvidence(
        workingDirectory: duplicateDirectory,
        previous: cachedEvidence,
        now: now.addingTimeInterval(1),
        gitExecutableURL: URL(fileURLWithPath: "/threadhelm/missing-git"),
        ghExecutableURL: nil
    )
    expect(cacheHit == cachedEvidence, "fresh repository cache hit")

    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ThreadHelmRepositorySelfTest-\(UUID().uuidString)")
    let repositoryURL = temporaryRoot.appendingPathComponent("repository")
    let nestedURL = repositoryURL.appendingPathComponent("nested")
    let linkedURL = temporaryRoot.appendingPathComponent("linked")
    do {
        try FileManager.default.createDirectory(
            at: nestedURL,
            withIntermediateDirectories: true
        )
    } catch {
        fail("temporary repository directory")
    }
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    func runGit(_ arguments: [String]) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = taskStatusCommandEnvironment(
            inheriting: ProcessInfo.processInfo.environment
        )
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        do {
            try process.run()
        } catch {
            return false
        }
        let capture = captureProcessOutput(
            process: process,
            output: output.fileHandleForReading,
            timeout: 5,
            maximumOutputBytes: 16 * 1_024
        )
        return capture.termination == .exited && process.terminationStatus == 0
    }

    expect(runGit(["-C", repositoryURL.path, "init"]), "git init")
    expect(
        runGit([
            "-C", repositoryURL.path, "symbolic-ref", "HEAD", "refs/heads/main",
        ]),
        "set main branch"
    )
    let fixtureURL = repositoryURL.appendingPathComponent("fixture.txt")
    do {
        try Data("clean\n".utf8).write(to: fixtureURL, options: .atomic)
    } catch {
        fail("write clean fixture")
    }
    expect(runGit(["-C", repositoryURL.path, "add", "fixture.txt"]), "git add")
    expect(
        runGit([
            "-C", repositoryURL.path,
            "-c", "user.name=ThreadHelm Self Test",
            "-c", "user.email=threadhelm.invalid",
            "-c", "commit.gpgsign=false",
            "commit", "-m", "repository fixture",
        ]),
        "git commit"
    )

    let cleanEvidence = probeTaskRepositoryEvidence(
        workingDirectory: nestedURL.path,
        previous: nil,
        now: now,
        ghExecutableURL: nil
    )
    guard let probedClean = cleanEvidence.gitStatus else {
        fail("real clean repository probe")
    }
    expect(probedClean.repositoryRoot == repositoryURL.path, "real repository root")
    expect(probedClean.branch == "main", "real branch")
    expect(probedClean.checkoutKind == .checkout, "real checkout kind")
    expect(!probedClean.isDirty, "real clean state")
    expect(probedClean.headSHA?.count == 40, "real full HEAD")
    expect(cleanEvidence.checkStatus == .unknown, "gh absence is unknown")

    expect(
        runGit([
            "-C", repositoryURL.path, "remote", "add", "team/fork",
            "https://github.com/OpenAI/Codex.git",
        ]),
        "add slash remote"
    )
    expect(
        runGit([
            "-C", repositoryURL.path, "config", "branch.main.remote",
            "team/fork",
        ]),
        "configure slash upstream remote"
    )
    expect(
        runGit([
            "-C", repositoryURL.path, "config", "branch.main.merge",
            "refs/heads/main",
        ]),
        "configure slash upstream branch"
    )
    expect(
        runGit([
            "-C", repositoryURL.path, "update-ref",
            "refs/remotes/team/fork/main", "HEAD",
        ]),
        "create slash upstream ref"
    )
    let slashRemoteEvidence = probeTaskRepositoryEvidence(
        workingDirectory: repositoryURL.path,
        previous: nil,
        now: now,
        ghExecutableURL: nil
    )
    expect(
        slashRemoteEvidence.gitStatus?.upstreamName == "team/fork/main",
        "slash upstream name"
    )
    expect(
        slashRemoteEvidence.gitStatus?.githubRepository == "OpenAI/Codex",
        "slash remote repository"
    )

    do {
        try Data("dirty\n".utf8).write(to: fixtureURL, options: .atomic)
    } catch {
        fail("write dirty fixture")
    }
    let dirtyEvidence = probeTaskRepositoryEvidence(
        workingDirectory: repositoryURL.path,
        previous: nil,
        now: now,
        ghExecutableURL: nil
    )
    expect(dirtyEvidence.gitStatus?.isDirty == true, "real dirty state")

    expect(
        runGit([
            "-C", repositoryURL.path, "worktree", "add", "--detach",
            linkedURL.path, "HEAD",
        ]),
        "git worktree add"
    )
    let linkedEvidence = probeTaskRepositoryEvidence(
        workingDirectory: linkedURL.path,
        previous: nil,
        now: now,
        ghExecutableURL: nil
    )
    expect(
        linkedEvidence.gitStatus?.checkoutKind == .linkedWorktree,
        "real linked worktree probe"
    )
    expect(linkedEvidence.gitStatus?.isDetached == true, "real detached worktree")
}

private func runDiscoveryCacheAndAutoIntegrationBackoffSelfTest() {
    var simulatedTime = Date()
    var probeCount = 0
    let cache = LocalAgentDiscoveryCache(
        agentID: .claudeCode,
        ttl: 300,
        now: { simulatedTime },
        discover: {
            probeCount += 1
            return AgentDiscovery(
                isInstalled: true,
                version: "v\(probeCount)",
                compatibility: .validated
            )
        }
    )

    let d1 = cache.read()
    guard probeCount == 1, d1.version == "v1" else {
        fputs("LocalAgentDiscoveryCache initial read failed\n", stderr)
        exit(1)
    }

    simulatedTime = simulatedTime.addingTimeInterval(100)
    let d2 = cache.read()
    guard probeCount == 1, d2.version == "v1" else {
        fputs("LocalAgentDiscoveryCache TTL cache hit failed\n", stderr)
        exit(1)
    }

    simulatedTime = simulatedTime.addingTimeInterval(201)
    let d3 = cache.read()
    guard probeCount == 2, d3.version == "v2" else {
        fputs("LocalAgentDiscoveryCache TTL expiration re-probe failed\n", stderr)
        exit(1)
    }

    cache.invalidate()
    let d4 = cache.read()
    guard probeCount == 3, d4.version == "v3" else {
        fputs("LocalAgentDiscoveryCache invalidate failed\n", stderr)
        exit(1)
    }

    var backoffTime = Date()
    let backoff = AgentAutoIntegrationBackoffGate(now: { backoffTime })

    guard backoff.canAttempt(agentID: .cursor, version: "1.0.0") else {
        fputs("BackoffGate initial canAttempt failed\n", stderr)
        exit(1)
    }

    backoff.recordFailure(agentID: .cursor, version: "1.0.0")
    guard !backoff.canAttempt(agentID: .cursor, version: "1.0.0") else {
        fputs("BackoffGate failure 1 delay failed\n", stderr)
        exit(1)
    }
    backoffTime = backoffTime.addingTimeInterval(301)
    guard backoff.canAttempt(agentID: .cursor, version: "1.0.0") else {
        fputs("BackoffGate failure 1 expiry failed\n", stderr)
        exit(1)
    }

    backoff.recordFailure(agentID: .cursor, version: "1.0.0")
    backoffTime = backoffTime.addingTimeInterval(400)
    guard !backoff.canAttempt(agentID: .cursor, version: "1.0.0") else {
        fputs("BackoffGate failure 2 delay failed\n", stderr)
        exit(1)
    }
    backoffTime = backoffTime.addingTimeInterval(501)
    guard backoff.canAttempt(agentID: .cursor, version: "1.0.0") else {
        fputs("BackoffGate failure 2 expiry failed\n", stderr)
        exit(1)
    }

    // 第三次及以后封顶在 60 分钟。
    backoff.recordFailure(agentID: .cursor, version: "1.0.0")
    backoffTime = backoffTime.addingTimeInterval(3000)
    guard !backoff.canAttempt(agentID: .cursor, version: "1.0.0") else {
        fputs("BackoffGate failure 3 cap delay failed\n", stderr)
        exit(1)
    }
    backoffTime = backoffTime.addingTimeInterval(601)
    guard backoff.canAttempt(agentID: .cursor, version: "1.0.0") else {
        fputs("BackoffGate failure 3 cap expiry failed\n", stderr)
        exit(1)
    }

    guard backoff.canAttempt(agentID: .cursor, version: "1.0.1") else {
        fputs("BackoffGate version change reset failed\n", stderr)
        exit(1)
    }

    // 关键回归：成功销账**不得**解除最小间隔。否则"报告成功但状态没收敛"
    // 会立刻允许重试，而成功又会触发下一轮评估 —— 形成无延迟写盘循环。
    let loopGate = AgentAutoIntegrationBackoffGate(now: { backoffTime })
    loopGate.recordAttempt(agentID: .omp, version: "17.3.2")
    loopGate.recordSuccess(agentID: .omp, version: "17.3.2")
    guard !loopGate.canAttempt(agentID: .omp, version: "17.3.2") else {
        fputs("BackoffGate minimum interval must survive recordSuccess\n", stderr)
        exit(1)
    }
    backoffTime = backoffTime.addingTimeInterval(
        AgentAutoIntegrationBackoffGate.minimumAttemptInterval + 1
    )
    guard loopGate.canAttempt(agentID: .omp, version: "17.3.2") else {
        fputs("BackoffGate minimum interval expiry failed\n", stderr)
        exit(1)
    }

    // 缓存 TTL 必须严格短于刷新周期，否则定时器唤醒时缓存常常刚好还没过期，
    // 该 Agent 的实际探测间隔退化成两个周期。
    guard agentDiscoveryCacheTTL < agentHealthRefreshInterval else {
        fputs("discovery cache TTL must be shorter than the refresh interval\n", stderr)
        exit(1)
    }

    runAutoIntegrationAccountingSelfTest()
    runAutoIntegrationCandidateSelfTest()
}

/// 结果 → 退避记账的映射。这是曾经导致无界写盘循环的那条规则本体。
private func runAutoIntegrationAccountingSelfTest() {
    func check(
        _ label: String,
        _ actual: AgentIntegrationAccountingOutcome,
        _ expected: AgentIntegrationAccountingOutcome
    ) {
        guard actual == expected else {
            fputs(
                "auto-integration accounting \(label): expected \(expected), got \(actual)\n",
                stderr
            )
            exit(1)
        }
    }

    // 抛错永远是失败，即使带着结果字段。
    check(
        "throw",
        agentIntegrationAccountingOutcome(
            result: .installed,
            statusAfter: .installed,
            threw: true
        ),
        .failed
    )
    // 关键回归：写入报告成功、但重新探测未收敛 —— 必须记失败。
    // 记成功会清掉失败计数，而成功又会触发下一轮评估，形成无延迟写盘循环。
    check(
        "installed but not converged",
        agentIntegrationAccountingOutcome(
            result: .installed,
            statusAfter: .notInstalled,
            threw: false
        ),
        .failed
    )
    check(
        "repaired but still drifted",
        agentIntegrationAccountingOutcome(
            result: .repaired,
            statusAfter: .needsRepair,
            threw: false
        ),
        .failed
    )
    check(
        "installed and converged",
        agentIntegrationAccountingOutcome(
            result: .installed,
            statusAfter: .installed,
            threw: false
        ),
        .succeeded
    )
    // 幂等 no-op 是成功语义，记成失败会让真正需要的自动集成被退避压制。
    check(
        "idempotent no-op",
        agentIntegrationAccountingOutcome(
            result: .unchanged,
            statusAfter: .installed,
            threw: false
        ),
        .succeeded
    )
    // 宿主不在：不写盘，但要退避，否则每个周期都会为同一个缺席的 Agent 重试。
    check(
        "host absent skip",
        agentIntegrationAccountingOutcome(
            result: .unchanged,
            statusAfter: .notInstalled,
            threw: false
        ),
        .skippedHostAbsent
    )
    check(
        "missing result",
        agentIntegrationAccountingOutcome(
            result: nil,
            statusAfter: .installed,
            threw: false
        ),
        .failed
    )
}

/// 自动集成的候选选取：双门禁、候选过滤、一轮只处理一个、退避门被真正咨询。
private func runAutoIntegrationCandidateSelfTest() {
    func status(
        _ agentID: AgentID,
        installed: Bool,
        compatibility: AgentCompatibility,
        integrationStatus: AgentIntegrationStatus?
    ) -> AgentRuntimeStatus {
        AgentRuntimeStatus(
            metadata: builtInAgentMetadata().first { $0.id == agentID }!,
            discovery: AgentDiscovery(
                isInstalled: installed,
                version: installed ? "9.9.9" : nil,
                compatibility: compatibility
            ),
            integrationStatus: integrationStatus,
            diagnostics: AgentDiagnostics(
                health: .healthy,
                summary: "self-test",
                counters: [:]
            ),
            activeSessionCount: 0,
            attentionCount: 0
        )
    }

    func fail(_ message: String) -> Never {
        fputs("auto-integration candidate \(message)\n", stderr)
        exit(1)
    }

    let ready = status(
        .cursor,
        installed: true,
        compatibility: .validated,
        integrationStatus: .notInstalled
    )
    let alsoReady = status(
        .omp,
        installed: true,
        compatibility: .validated,
        integrationStatus: .notInstalled
    )
    // 门禁必须收到与记账一致的版本键，否则退避会记到另一个键上而形同虚设。
    let always: (AgentID, String) -> Bool = { _, version in
        guard version == "9.9.9" else {
            fputs(
                "auto-integration candidate must consult the backoff gate with "
                    + "the accounting version key, got \(version)\n",
                stderr
            )
            exit(1)
        }
        return true
    }

    // 双门禁：任一缺失都不得产生候选。
    guard agentAutoIntegrationCandidate(
        statuses: [ready], isEnabled: false, hasConfirmed: true, canAttempt: always
    ) == nil else {
        fail("must not run while disabled")
    }
    guard agentAutoIntegrationCandidate(
        statuses: [ready], isEnabled: true, hasConfirmed: false, canAttempt: always
    ) == nil else {
        fail("must not run before the one-time confirmation")
    }

    // 候选过滤：未安装、已集成、用户停用过的都不该被选中。
    for (label, rejected) in [
        ("not installed", status(.cursor, installed: false, compatibility: .validated, integrationStatus: .notInstalled)),
        ("already installed", status(.cursor, installed: true, compatibility: .validated, integrationStatus: .installed)),
        ("needs repair", status(.cursor, installed: true, compatibility: .validated, integrationStatus: .needsRepair)),
        ("disabled by user", status(.cursor, installed: true, compatibility: .validated, integrationStatus: .disabled)),
        ("check failed", status(.cursor, installed: true, compatibility: .validated, integrationStatus: .checkFailed)),
        ("no integration status", status(.cursor, installed: true, compatibility: .validated, integrationStatus: nil)),
    ] {
        guard agentAutoIntegrationCandidate(
            statuses: [rejected], isEnabled: true, hasConfirmed: true, canAttempt: always
        ) == nil else {
            fail("must not select \(label)")
        }
    }

    // 版本漂移照样是候选。原来这里挡着，于是上游一发版自动集成就整条
    // 静默停摆——而手动安装在 00a538f 已经解耦，两条路各说各话。
    for compatibility in [
        AgentCompatibility.unvalidated,
        .unknown,
    ] {
        let drifted = status(
            .cursor,
            installed: true,
            compatibility: compatibility,
            integrationStatus: .notInstalled
        )
        guard agentAutoIntegrationCandidate(
            statuses: [drifted],
            isEnabled: true,
            hasConfirmed: true,
            canAttempt: always
        )?.agentID == .cursor else {
            fail("must still select \(compatibility.rawValue)")
        }
    }

    // 正常命中，且一轮只返回一个候选。
    guard let picked = agentAutoIntegrationCandidate(
        statuses: [ready, alsoReady],
        isEnabled: true,
        hasConfirmed: true,
        canAttempt: always
    ), picked == AgentAutoIntegrationCandidate(agentID: .cursor, version: "9.9.9")
    else {
        fail("must select the first eligible agent only")
    }

    // 退避门必须被真正咨询：拒绝首个候选时应跳到下一个。
    guard let skipped = agentAutoIntegrationCandidate(
        statuses: [ready, alsoReady],
        isEnabled: true,
        hasConfirmed: true,
        canAttempt: { agentID, _ in agentID != .cursor }
    ), skipped.agentID == .omp else {
        fail("must honour the backoff gate")
    }
    guard agentAutoIntegrationCandidate(
        statuses: [ready, alsoReady],
        isEnabled: true,
        hasConfirmed: true,
        canAttempt: { _, _ in false }
    ) == nil else {
        fail("must yield nothing when every candidate is backed off")
    }
}

private func runClaudeDesktopTaskDiscoverySelfTest() {
    let fileManager = FileManager.default
    let home = fileManager.temporaryDirectory.appendingPathComponent(
        "threadhelm-claude-desktop-\(UUID().uuidString)",
        isDirectory: true
    )
    let localSessionID = "local_11111111-1111-4111-8111-111111111111"
    let cliSessionID = "22222222-2222-4222-8222-222222222222"
    let sessionDirectory = home
        .appendingPathComponent(
            "Library/Application Support/Claude/local-agent-mode-sessions",
            isDirectory: true
        )
        .appendingPathComponent(
            "33333333-3333-4333-8333-333333333333",
            isDirectory: true
        )
        .appendingPathComponent(
            "44444444-4444-4444-8444-444444444444",
            isDirectory: true
        )
    let localSessionDirectory = sessionDirectory.appendingPathComponent(
        localSessionID,
        isDirectory: true
    )
    let transcriptDirectory = localSessionDirectory
        .appendingPathComponent(".claude/projects", isDirectory: true)
        .appendingPathComponent("-desktop-workspace", isDirectory: true)
    let transcriptURL = transcriptDirectory.appendingPathComponent(
        "\(cliSessionID).jsonl"
    )
    let metadataURL = sessionDirectory.appendingPathComponent(
        "\(localSessionID).json"
    )
    // 时间线必须与转写内容同源：以前 now/mtime 取真实当前时间、内容却
    // 固定在 2026-08-14，于是「活跃」断言实际测的是 mtime 而非对话活动。
    // 活跃判定改看内容时间后，这里跟着对齐到内容之后 1 秒。
    var currentTime = ISO8601DateFormatter().date(
        from: "2026-08-14T08:00:02Z"
    ) ?? Date()
    defer { try? fileManager.removeItem(at: home) }

    let userRecord = #"{"type":"user","timestamp":"2026-08-14T08:00:00.000Z","cwd":"/desktop/outputs","message":{"role":"user","content":"Desktop 会话识别回归"}}"#
    let toolRecord = #"{"type":"assistant","timestamp":"2026-08-14T08:00:01.000Z","cwd":"/desktop/outputs","message":{"role":"assistant","content":[{"type":"tool_use","id":"desktop-tool","name":"Bash"}],"stop_reason":"tool_use"}}"#
    do {
        try fileManager.createDirectory(
            at: transcriptDirectory,
            withIntermediateDirectories: true
        )
        try Data(
            #"{"sessionId":"\#(localSessionID)","cliSessionId":"\#(cliSessionID)"}"#.utf8
        ).write(to: metadataURL)
        try Data(
            [userRecord, toolRecord].joined(separator: "\n")
                .appending("\n")
                .utf8
        ).write(to: transcriptURL)
        try fileManager.setAttributes(
            [.modificationDate: currentTime],
            ofItemAtPath: transcriptURL.path
        )
    } catch {
        fputs("Claude Desktop task fixture failed\n", stderr)
        exit(1)
    }

    let reader = ClaudeTaskProgressReader(
        homeDirectory: home,
        indexRootDirectory: home.appendingPathComponent(
            "transcript-index", isDirectory: true
        ),
        environment: [:],
        claudeExecutable: { nil },
        now: { currentTime }
    )
    let item = reader.readCollection().items.first {
        $0.sessionID == cliSessionID
    }
    guard item?.title == "Desktop 会话识别回归",
          item?.kind == .running,
          item?.activityText == "正在运行命令",
          item?.allowsAgentOpen == true,
          item?.canOpen == true
    else {
        fputs("Claude Desktop local session was not discovered safely\n", stderr)
        exit(1)
    }
    currentTime = currentTime.addingTimeInterval(31)
    guard !reader.readCollection().items.contains(where: {
        $0.sessionID == cliSessionID
    }) else {
        fputs("stale Claude Desktop activity stayed cached as running\n", stderr)
        exit(1)
    }
}

private func runCodexTailMetadataBackfillSelfTest(now: Date, started: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "threadhelm-codex-tail-metadata-\(UUID().uuidString)",
        isDirectory: true
    )
    let rolloutURL = directory.appendingPathComponent(
        "rollout-2026-08-11T00-00-00-00000000-0000-0000-0000-000000000001.jsonl"
    )
    let environmentKey = "THREADHELM_TASK_ROLLOUT_FILE"
    let previousValue = getenv(environmentKey).map { String(cString: $0) }
    defer {
        if let previousValue {
            setenv(environmentKey, previousValue, 1)
        } else {
            unsetenv(environmentKey)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    let sessionMeta = #"{"type":"session_meta","payload":{"cwd":"/tmp/threadhelm-tail-project","thread_source":"root"}}"#
    let publicUpdate = #"{"timestamp":"2026-08-11T00:00:01Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"正在验证大型会话"}}"#
    let filler = String(repeating: "x", count: 1_100_000)
    do {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(
            [sessionMeta, filler, started, publicUpdate]
                .joined(separator: "\n")
                .appending("\n")
                .utf8
        ).write(to: rolloutURL)
    } catch {
        fputs("Codex tail metadata fixture failed\n", stderr)
        exit(1)
    }

    setenv(environmentKey, rolloutURL.path, 1)
    let item = CodexTaskProgressReader(
        indexRootDirectory: directory.appendingPathComponent(
            "transcript-index", isDirectory: true
        )
    ).readCollection().items.first
    guard item?.workingDirectory == "/tmp/threadhelm-tail-project",
          item?.activityText == "正在验证大型会话"
    else {
        fputs("Codex tail metadata cwd backfill failed\n", stderr)
        exit(1)
    }
}

private func runCodexUnavailableRolloutRootSelfTest() {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-codex-unavailable-root-\(UUID().uuidString)",
        isDirectory: true
    )
    let codexHome = temporaryRoot.appendingPathComponent(
        "codex-home",
        isDirectory: true
    )
    let sessionsRoot = codexHome.appendingPathComponent(
        "sessions",
        isDirectory: true
    )
    let rolloutRoot = temporaryRoot.appendingPathComponent(
        "external-codex-sessions",
        isDirectory: true
    )
    let sessionID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let rolloutURL = rolloutRoot.appendingPathComponent(
        "rollout-2033-05-18T00-00-00-\(sessionID).jsonl"
    )
    let codexHomeKey = "CODEX_HOME"
    let rolloutOverrideKey = "THREADHELM_TASK_ROLLOUT_FILE"
    let stateOverrideKey = "THREADHELM_CODEX_STATE_FILE"
    let previousCodexHome = getenv(codexHomeKey).map { String(cString: $0) }
    let previousRolloutOverride = getenv(rolloutOverrideKey).map {
        String(cString: $0)
    }
    let previousStateOverride = getenv(stateOverrideKey).map {
        String(cString: $0)
    }
    defer {
        for (key, value) in [
            (codexHomeKey, previousCodexHome),
            (rolloutOverrideKey, previousRolloutOverride),
            (stateOverrideKey, previousStateOverride),
        ] {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        try? manager.removeItem(at: temporaryRoot)
    }

    do {
        try manager.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true
        )
        try manager.createSymbolicLink(
            at: sessionsRoot,
            withDestinationURL: rolloutRoot
        )
    } catch {
        fputs("Codex unavailable rollout root fixture setup failed\n", stderr)
        exit(1)
    }
    setenv(codexHomeKey, codexHome.path, 1)
    unsetenv(rolloutOverrideKey)
    unsetenv(stateOverrideKey)

    var currentTime = Date(timeIntervalSince1970: 2_000_000_000)
    let indexRoot = temporaryRoot.appendingPathComponent(
        "transcript-index",
        isDirectory: true
    )
    let reader = CodexTaskProgressReader(
        indexRootDirectory: indexRoot,
        now: { currentTime }
    )
    guard reader.readCollection().items.isEmpty else {
        fputs("missing Codex rollout root must fail closed\n", stderr)
        exit(1)
    }

    let records = [
        #"{"type":"session_meta","payload":{"cwd":"/tmp/threadhelm-unavailable-root","thread_source":"root"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"restart recovery"}}"#,
    ]
    do {
        try manager.createDirectory(
            at: rolloutRoot,
            withIntermediateDirectories: true
        )
        try Data((records.joined(separator: "\n") + "\n").utf8)
            .write(to: rolloutURL)
        try manager.setAttributes(
            [.modificationDate: currentTime],
            ofItemAtPath: rolloutURL.path
        )
    } catch {
        fputs("Codex unavailable rollout recovery fixture failed\n", stderr)
        exit(1)
    }

    currentTime = currentTime.addingTimeInterval(10)
    guard reader.readCollection().items.isEmpty else {
        fputs("unavailable Codex rollout root retried in the same process\n", stderr)
        exit(1)
    }
    let restarted = CodexTaskProgressReader(
        indexRootDirectory: indexRoot,
        now: { currentTime }
    ).readCollection().items.first
    guard restarted?.workingDirectory == "/tmp/threadhelm-unavailable-root",
          restarted?.activityText == "restart recovery"
    else {
        fputs("Codex rollout root did not recover after reader restart\n", stderr)
        exit(1)
    }
}

/// Codex 0.147 起把用户消息、助手消息和工具调用统一写成
/// `event_msg/item_completed`，旧的 agent_message / user_message /
/// custom_tool_call 不再出现。81 条真值夹具走的是脱敏信号而非 JSONL，
/// 覆盖不到这段归一化，所以在这里端到端验一次。
private func runCodexCompletedItemFormatSelfTest() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "threadhelm-codex-item-completed-\(UUID().uuidString)",
        isDirectory: true
    )
    let rolloutURL = directory.appendingPathComponent(
        "rollout-2026-08-26T00-00-00-00000000-0000-0000-0000-00000000000f.jsonl"
    )
    let environmentKey = "THREADHELM_TASK_ROLLOUT_FILE"
    let previousValue = getenv(environmentKey).map { String(cString: $0) }
    defer {
        if let previousValue {
            setenv(environmentKey, previousValue, 1)
        } else {
            unsetenv(environmentKey)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    let secret = "机密命令内容不得进入事件文本"
    let sessionMeta = #"{"type":"session_meta","payload":{"cwd":"/tmp/threadhelm-item-project","thread_source":"user"}}"#
    // UserMessage 的 content 分量是小写 "text"，AgentMessage 是大写 "Text"。
    let userItem = #"{"timestamp":"2026-08-26T00:00:01Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"新格式任务标题"},{"type":"local_image","path":"x.png"}]}}}"#
    let taskStarted = #"{"timestamp":"2026-08-26T00:00:02Z","type":"event_msg","payload":{"type":"task_started"}}"#
    let reasoningItem = #"{"timestamp":"2026-08-26T00:00:03Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"r1","summary_text":["这条 thinking 绝不能出现"]}}}"#
    let agentItem = #"{"timestamp":"2026-08-26T00:00:04Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m1","phase":"commentary","content":[{"type":"Text","text":"新格式公开输出"}]}}}"#
    let commandItem = #"{"timestamp":"2026-08-26T00:00:05Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"e1","status":"completed","command":["/bin/zsh","-lc","echo \#(secret)"],"stdout":"\#(secret)"}}}"#

    do {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(
            [
                sessionMeta, userItem, taskStarted,
                reasoningItem, agentItem, commandItem,
            ]
            .joined(separator: "\n")
            .appending("\n")
            .utf8
        ).write(to: rolloutURL)
    } catch {
        fputs("Codex item_completed fixture failed\n", stderr)
        exit(1)
    }

    setenv(environmentKey, rolloutURL.path, 1)
    let item = CodexTaskProgressReader(
        indexRootDirectory: directory.appendingPathComponent(
            "transcript-index", isDirectory: true
        )
    ).readCollection().items.first
    let eventTexts = (item?.events ?? []).map(\.text)
    let publicTexts = (item?.projection.publicMessages ?? []).map(\.text)

    guard item?.title == "新格式任务标题",
          item?.workingDirectory == "/tmp/threadhelm-item-project",
          publicTexts.contains("新格式公开输出"),
          // 工具记录在冷扫描回放中被有意跳过：历史工具不该显示成当前
          // 活动，这与旧格式 function_call 的处理一致。锁定该行为。
          !eventTexts.contains(where: { $0.contains("正在运行命令") }),
          // 无论回放与否，命令与 stdout 都不得进入任何面向用户的文本。
          !eventTexts.contains(where: { $0.contains(secret) }),
          !publicTexts.contains(where: { $0.contains(secret) }),
          // thinking 不属于公开活动。
          !eventTexts.contains(where: { $0.contains("绝不能出现") }),
          !publicTexts.contains(where: { $0.contains("绝不能出现") })
    else {
        fputs("Codex item_completed normalization failed\n", stderr)
        fputs("  title=\(item?.title ?? "nil")\n", stderr)
        fputs("  cwd=\(item?.workingDirectory ?? "nil")\n", stderr)
        fputs("  kind=\(String(describing: item?.kind))\n", stderr)
        fputs("  events=\(eventTexts)\n", stderr)
        fputs("  public=\(publicTexts)\n", stderr)
        exit(1)
    }
}

private func runTaskProgressRefreshGateSelfTest() {
    var gate = TaskProgressRefreshGate()
    guard let slowGeneration = gate.begin() else {
        fputs("task progress refresh gate did not start first read\n", stderr)
        exit(1)
    }
    guard gate.begin() == nil else {
        fputs("task progress refresh gate allowed an overlapping read\n", stderr)
        exit(1)
    }
    guard gate.begin() == nil else {
        fputs("task progress refresh gate replaced a still-running read\n", stderr)
        exit(1)
    }
    guard gate.complete(generation: slowGeneration),
          let freshGeneration = gate.begin(),
          freshGeneration != slowGeneration
    else {
        fputs("task progress refresh gate did not resume after completion\n", stderr)
        exit(1)
    }
    guard !gate.complete(generation: slowGeneration),
          gate.complete(generation: freshGeneration),
          gate.begin() != nil
    else {
        fputs("task progress refresh gate accepted a stale completion\n", stderr)
        exit(1)
    }
    var followUp = AgentRuntimeRefreshFollowUp()
    guard followUp.consume() == nil else {
        fputs("agent runtime refresh follow-up was initially pending\n", stderr)
        exit(1)
    }
    followUp.request(suppressAutoIntegration: true)
    followUp.request(suppressAutoIntegration: false)
    guard followUp.consume()?.suppressAutoIntegration == false,
          followUp.consume() == nil
    else {
        fputs("agent runtime refresh follow-up coalescing failed\n", stderr)
        exit(1)
    }
    guard gate.complete(generation: freshGeneration) == false else {
        fputs("task progress refresh gate completed twice\n", stderr)
        exit(1)
    }
}

private func runClaudeAgentsCommandTimeoutSelfTest() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "threadhelm-claude-agents-timeout-\(UUID().uuidString)",
        isDirectory: true
    )
    let executable = directory.appendingPathComponent("claude")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(
            """
            #!/bin/sh
            trap '' TERM
            printf '[{"sessionId":"00000000-0000-0000-0000-000000000001"}]'
            exec /bin/sleep 30
            """.utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    } catch {
        fputs("Claude agents timeout fixture failed\n", stderr)
        exit(1)
    }

    let startedAt = Date()
    let output = captureClaudeAgentsJSON(
        executableURL: executable,
        timeout: 0.1,
        terminationGracePeriod: 0.1
    )
    guard output == nil, Date().timeIntervalSince(startedAt) < 1 else {
        fputs("Claude agents command did not stop after timeout\n", stderr)
        exit(1)
    }
}

private func runRuntimeHealthWriterFailureSelfTest() {
    var healthPayload: Data?
    let channelWriter = RuntimeHealthWriter(
        fileURL: URL(fileURLWithPath: "/tmp/threadhelm-health-channel.json"),
        createDirectory: { _, _ in },
        writeData: { data, _ in healthPayload = data },
        logFailure: { _ in }
    )
    channelWriter.write(
        status: "started",
        panelVisible: false,
        agentEventChannelAvailable: false,
        force: true
    )
    let channelObject = healthPayload.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    let removedHealthKeys = [
        "petID",
        "petGapPoints",
        "pointerCenterErrorPoints",
        "panelBaseHeightPoints",
        "panelWidthPoints",
        "panelHeightPoints",
        "panelScale",
        "locationSource",
    ]
    guard channelObject?["agentEventChannel"] as? String == "degraded",
          channelObject?["panelVisible"] as? Bool == false,
          removedHealthKeys.allSatisfy({ channelObject?[$0] == nil })
    else {
        fputs("runtime health event-channel status missing\n", stderr)
        exit(1)
    }

    let blockedURL = URL(fileURLWithPath: "/tmp/threadhelm-health-blocked/panel-health.json")
    var messages: [String] = []
    let writer = RuntimeHealthWriter(
        fileURL: blockedURL,
        createDirectory: { _, _ in
            throw NSError(domain: "RuntimeHealthWriterSelfTest", code: 1)
        },
        writeData: { _, _ in
            throw NSError(domain: "RuntimeHealthWriterSelfTest", code: 2)
        },
        logFailure: { message in
            messages.append(message)
        }
    )
    writer.write(
        status: "dynamic-island-visible",
        panelVisible: true,
        force: true
    )
    writer.write(
        status: "dynamic-island-visible",
        panelVisible: true,
        force: true
    )
    guard messages.count == 1,
          messages[0].contains("ThreadHelm health write failed")
    else {
        fputs("runtime health writer failure logging failed\n", stderr)
        exit(1)
    }
}

private func runCodexClaudeTranscriptProviderRegressionSelfTest(
    now: Date,
    started: String
) {
    let duplicateA = #"{"timestamp":"2026-07-25T10:02:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"重复公开消息"}}"#
    let duplicateB = #"{"timestamp":"2026-07-25T10:03:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"重复公开消息"}}"#
    let duplicateCodex = CodexTaskProgressReader.parse(
        lines: [started, duplicateA, duplicateB],
        modificationDate: now,
        now: now
    )
    guard duplicateCodex.items.first?.projection.publicMessages.map(\.text)
        == ["重复公开消息", "重复公开消息"]
    else {
        fputs("Codex duplicate public messages with different source records were collapsed\n", stderr)
        exit(1)
    }

    var boundedCodex = CodexTaskProgressReader.CodexReducerState(
        modificationDate: now
    )
    boundedCodex.apply(started)
    let longText = String(repeating: "甲", count: 5_000)
    for index in 0..<40 {
        boundedCodex.apply(
            #"{"timestamp":"2026-07-25T10:\#(String(format: "%02d", index % 60)):00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"\#(longText)"}}"#
        )
    }
    for index in 0..<80 {
        boundedCodex.apply(
            #"{"timestamp":"2026-07-25T11:\#(String(format: "%02d", index % 60)):00Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"tool-\#(index)"}}"#
        )
    }
    let boundedCodexItem = boundedCodex.snapshot(
        modificationDate: now,
        now: now,
        sessionKey: "codex-budget"
    ).items.first
    guard let boundedProjection = boundedCodexItem?.projection,
          boundedProjection.publicMessages.count == 32,
          boundedProjection.publicMessages.allSatisfy({
              $0.text.utf8.count <= AgentActivityBudget.maximumPublicMessageBytes
          }),
          (boundedCodexItem?.activityText?.utf8.count ?? 0)
              <= AgentActivityBudget.maximumPublicMessagesTotalBytes
                + AgentActivityBudget.maximumToolStatusBytes
    else {
        fputs("Codex reducer public/tool/text budgets failed\n", stderr)
        exit(1)
    }

    let fileManager = FileManager.default
    let temp = fileManager.temporaryDirectory.appendingPathComponent(
        "threadhelm-provider-regression-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try fileManager.createDirectory(
            at: temp,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: temp) }
        let transcriptURL = temp.appendingPathComponent("rollout-test.jsonl")
        let publicLine = duplicateA + "\n"
        let toolLines = (0..<40).map {
            #"{"timestamp":"2026-07-25T10:10:00Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"tool-tail-\#($0)"}}"#
        }.joined(separator: "\n") + "\n"
        try Data((publicLine + toolLines).utf8).write(to: transcriptURL)
        guard let reader = TranscriptEventReader.make(at: transcriptURL),
              case .success(let records) = reader.readForwardPass()
        else {
            fputs("provider regression transcript reader failed\n", stderr)
            exit(1)
        }
        var reducer = CodexTaskProgressReader.CodexReducerState(
            modificationDate: now
        )
        var publicDescriptors: [TranscriptRecordLocation] = []
        for record in records {
            guard let line = String(data: record.data, encoding: .utf8) else {
                continue
            }
            let location = TranscriptRecordLocation(
                startOffset: record.startOffset,
                byteCount: UInt32(record.byteCount),
                sourceOrder: record.sourceOrder,
                eventClass: .publicMessage,
                occurredAt: nil
            )
            if reducer.apply(
                line,
                location: location,
                sessionKey: "stable-session"
            ) == .publicMessage {
                publicDescriptors.append(location)
            }
        }
        let item = reducer.snapshot(
            modificationDate: now,
            now: now,
            sessionKey: "stable-session"
        ).items.first
        guard publicDescriptors.count == 1,
              item?.projection.publicMessages.first?.id.stableSourceKey
                == "bytes-\(publicDescriptors[0].startOffset)-\(publicDescriptors[0].byteCount)",
              item?.projection.publicMessages.first?.id.sessionKey
                == "stable-session"
        else {
            fputs("Codex provider descriptor classification or stable byte ID failed\n", stderr)
            exit(1)
        }
    } catch {
        fputs("provider regression fixture setup failed: \(error)\n", stderr)
        exit(1)
    }

    let claudeSessionID = "2af8c2f6-1fd8-4d55-94dd-57efbb866c7b"
    var claudeReducer = ClaudeTaskProgressReader.ClaudeReducerState(
        modificationDate: now
    )
    claudeReducer.apply(
        #"{"type":"assistant","timestamp":"2026-07-25T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Claude 必须保留的公开消息"}]}}"#,
        modificationDate: now,
        location: TranscriptRecordLocation(
            startOffset: 10,
            byteCount: 20,
            sourceOrder: 1,
            eventClass: .publicMessage,
            occurredAt: nil
        ),
        sessionKey: claudeSessionID
    )
    for index in 0..<80 {
        claudeReducer.apply(
            #"{"type":"assistant","timestamp":"2026-07-25T10:10:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-\#(index)","name":"Bash","input":{}}],"stop_reason":"tool_use"}}"#,
            modificationDate: now,
            sessionKey: claudeSessionID
        )
    }
    let claudeItem = claudeReducer.buildItem(
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude",
        processID: nil,
        processStartIdentity: nil,
        activeKind: .running,
        startedAt: now,
        modificationDate: now,
        now: now,
        statusOverride: nil,
        allowsAgentOpen: true
    )
    guard claudeItem?.projection.publicMessages.first?.text
            == "Claude 必须保留的公开消息",
          claudeItem?.projection.publicMessages.first?.id.stableSourceKey
            == "bytes-10-20",
          claudeReducer.activeTools.count == 32
    else {
        fputs("Claude reducer budget or stable byte ID failed\n", stderr)
        exit(1)
    }
}

private func runCodexClaudeAtomicReplaceCacheSelfTest() {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-provider-replace-\(UUID().uuidString)",
        isDirectory: true
    )
    let rolloutEnvironmentKey = "THREADHELM_TASK_ROLLOUT_FILE"
    let previousRollout = getenv(rolloutEnvironmentKey).map {
        String(cString: $0)
    }
    defer {
        if let previousRollout {
            setenv(rolloutEnvironmentKey, previousRollout, 1)
        } else {
            unsetenv(rolloutEnvironmentKey)
        }
        try? manager.removeItem(at: temp)
    }

    do {
        try manager.createDirectory(at: temp, withIntermediateDirectories: true)
        let fixedDate = Date()
        let indexRoot = temp.appendingPathComponent("index", isDirectory: true)

        let codexSessionID = "11111111-2222-4333-8444-555555555555"
        let codexURL = temp.appendingPathComponent(
            "rollout-2026-08-18T00-00-00-\(codexSessionID).jsonl"
        )
        func codexData(_ text: String) -> Data {
            let lines = [
                #"{"type":"session_meta","payload":{"cwd":"/private/tmp/threadhelm-\#(text)","thread_source":"root"}}"#,
                #"{"timestamp":"2026-08-18T00:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#,
                #"{"timestamp":"2026-08-18T00:00:01Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"\#(text)"}}"#,
            ]
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        let codexFirstData = codexData("AAAA")
        let codexReplacementData = codexData("BBBB")
        guard codexFirstData.count == codexReplacementData.count else {
            fputs("Codex atomic replace fixtures differ in size\n", stderr)
            exit(1)
        }
        try codexFirstData.write(to: codexURL)
        try manager.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: codexURL.path
        )
        setenv(rolloutEnvironmentKey, codexURL.path, 1)
        guard let codexFirstIdentity = TranscriptEventReader.make(
            at: codexURL
        )?.identity else {
            fputs("Codex atomic replace identity setup failed\n", stderr)
            exit(1)
        }
        let codexReader = CodexTaskProgressReader(indexRootDirectory: indexRoot)
        let codexFirst = codexReader.readCollection().items.first
        guard codexFirst?.projection.publicMessages.contains(where: {
            $0.text.contains("AAAA")
        }) == true,
              codexFirst?.workingDirectory == "/private/tmp/threadhelm-AAAA"
        else {
            fputs("Codex atomic replace initial projection failed\n", stderr)
            exit(1)
        }
        try codexReplacementData.write(to: codexURL, options: .atomic)
        try manager.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: codexURL.path
        )
        guard TranscriptEventReader.make(at: codexURL)?.identity
                != codexFirstIdentity,
              let codexReplacement = codexReader.readCollection().items.first,
              codexReplacement.projection.publicMessages.contains(where: {
                  $0.text.contains("BBBB")
              }),
              !codexReplacement.projection.publicMessages.contains(where: {
                  $0.text.contains("AAAA")
              }),
              codexReplacement.workingDirectory
                == "/private/tmp/threadhelm-BBBB"
        else {
            fputs("Codex same-size atomic replace reused stale cache\n", stderr)
            exit(1)
        }

        let claudeSessionID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let claudeProject = temp
            .appendingPathComponent("claude-home", isDirectory: true)
            .appendingPathComponent(".claude/projects/test", isDirectory: true)
        let claudeURL = claudeProject.appendingPathComponent(
            "\(claudeSessionID).jsonl"
        )
        try manager.createDirectory(
            at: claudeProject,
            withIntermediateDirectories: true
        )
        func claudeData(_ text: String) -> Data {
            let lines = [
                #"{"type":"user","message":{"role":"user","content":"Replace cache test"}}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn"}}"#,
            ]
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        let claudeFirstData = claudeData("AAAA")
        let claudeReplacementData = claudeData("BBBB")
        guard claudeFirstData.count == claudeReplacementData.count else {
            fputs("Claude atomic replace fixtures differ in size\n", stderr)
            exit(1)
        }
        try claudeFirstData.write(to: claudeURL)
        try manager.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: claudeURL.path
        )
        guard let claudeFirstIdentity = TranscriptEventReader.make(
            at: claudeURL
        )?.identity else {
            fputs("Claude atomic replace identity setup failed\n", stderr)
            exit(1)
        }
        let claudeHome = temp.appendingPathComponent(
            "claude-home", isDirectory: true
        )
        let claudeReader = ClaudeTaskProgressReader(
            homeDirectory: claudeHome,
            indexRootDirectory: indexRoot,
            environment: [:],
            claudeExecutable: { nil },
            now: { fixedDate }
        )
        guard claudeReader.readCollection().items.first(where: {
            $0.sessionID == claudeSessionID
        })?.projection.publicMessages.contains(where: {
            $0.text.contains("AAAA")
        }) == true else {
            fputs("Claude atomic replace initial projection failed\n", stderr)
            exit(1)
        }
        try claudeReplacementData.write(to: claudeURL, options: .atomic)
        try manager.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: claudeURL.path
        )
        let claudeReplacement = claudeReader.readCollection().items.first {
            $0.sessionID == claudeSessionID
        }
        guard TranscriptEventReader.make(at: claudeURL)?.identity
                != claudeFirstIdentity,
              claudeReplacement?.projection.publicMessages.contains(where: {
                  $0.text.contains("BBBB")
              }) == true,
              claudeReplacement?.projection.publicMessages.contains(where: {
                  $0.text.contains("AAAA")
              }) != true
        else {
            fputs("Claude same-size atomic replace reused stale cache\n", stderr)
            exit(1)
        }
    } catch {
        fputs("Codex/Claude atomic replace cache fixture failed: \(error)\n", stderr)
        exit(1)
    }
}

private func runTaskProgressSelfTestPhase1(now: Date, started: String) {
    let completed = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
    let failed = #"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#
    let request = #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-1"}}"#
    let response = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call-1"}}"#
    let cases: [(String, [String], Date, TaskProgressKind)] = [
        ("running", [started], now, .running),
        ("waiting", [started, request], now, .waitingForInput),
        ("resumed", [started, request, response], now, .running),
        ("completed", [started, completed], now, .completed),
        ("failed", [started, failed], now, .failed),
        ("fresh-tail-fallback", [], now, .running),
        ("idle", [], now.addingTimeInterval(-31 * 60), .idle),
    ]

    for test in cases {
        let result = CodexTaskProgressReader.parse(
            lines: test.1,
            modificationDate: test.2,
            now: now
        )
        guard result.kind == test.3 else {
            fputs("task progress case \(test.0) failed: \(result.kind.rawValue)\n", stderr)
            exit(1)
        }
    }

    let timestampedStarted = #"{"timestamp":"2026-07-25T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#
    let publicCommentary = #"{"timestamp":"2026-07-25T10:02:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"**第一行会被后续输出覆盖。**\n第二行。\n第三行。\n第四行覆盖第一行。","agent_reasoning":"隐藏推理绝不显示"}}"#
    let continuedCommentary = #"{"timestamp":"2026-07-25T10:06:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"继续检查最终构建与安装状态。"}}"#
    let finalAnswer = #"{"timestamp":"2026-07-25T10:07:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"最终结果已经准备完成。"}}"#
    let commandStarted = #"{"timestamp":"2026-07-25T10:03:00Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"tool-1","arguments":"secret command"}}"#
    let commandFinished = #"{"timestamp":"2026-07-25T10:04:00Z","type":"response_item","payload":{"type":"function_call_output","call_id":"tool-1","output":"secret output"}}"#
    let hiddenReasoning = #"{"timestamp":"2026-07-25T10:05:00Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"隐藏推理绝不显示"}]}}"#
    let sessionMeta = #"{"type":"session_meta","payload":{"cwd":"/tmp/threadhelm","thread_source":"root"}}"#
    let openAITestCredential = ["sk", "proj", "ABCDEFGHIJKLMNOPQRSTUV"]
        .joined(separator: "-")
    guard let gitHubCredentialData = Data(
        base64Encoded: "Z2hwX0FCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaMTIzNDU2Nzg5MA=="
    ),
          let gitHubTestCredential = String(
              data: gitHubCredentialData,
              encoding: .utf8
          )
    else {
        fputs("task progress credential fixture decode failed\n", stderr)
        exit(1)
    }
    let codexCommentaryCredential = ["sk", "proj", "CODEXCOMMENTARYSECRET"]
        .joined(separator: "-")
    let slackTestCredential = ["xoxb", "123456789012", "abcdefghijklmnop"]
        .joined(separator: "-")
    let publicCredentialText = "Authorization: Bearer codex-bearer-secret-1234567890 "
        + "api_key=\(openAITestCredential) "
        + "password=correct-horse-battery-staple "
        + "\(gitHubTestCredential) "
        + slackTestCredential
    guard let redactedCredentialText = safePublicActivityParagraph(
        from: publicCredentialText
    ),
          redactedCredentialText.contains("[已隐藏]"),
          !redactedCredentialText.contains("codex-bearer-secret-1234567890"),
          !redactedCredentialText.contains(openAITestCredential),
          !redactedCredentialText.contains("correct-horse-battery-staple"),
          !redactedCredentialText.contains(gitHubTestCredential),
          !redactedCredentialText.contains(slackTestCredential),
          safePublicActivityParagraph(
              from: #"{"access_token":"raw-json-secret-123456"}"#
          ) == nil,
          safePublicActivityParagraph(
              from: "-----BEGIN PRIVATE KEY-----\nprivate-key-secret\n-----END PRIVATE KEY-----"
          ) == nil
    else {
        fputs("public activity credential sanitizer failed\n", stderr)
        exit(1)
    }
    let codexCredentialCommentary = #"{"timestamp":"2026-07-25T10:07:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"Authorization: Bearer codex-commentary-secret-1234567890 api_key=\#(codexCommentaryCredential)"}}"#
    let codexRawJSONCommentary = #"{"timestamp":"2026-07-25T10:08:00Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"{\"refresh_token\":\"codex-json-secret-123456\"}"}}"#
    let codexCredentialSnapshot = CodexTaskProgressReader.parse(
        lines: [
            timestampedStarted,
            codexCredentialCommentary,
            codexRawJSONCommentary,
        ],
        modificationDate: now,
        now: now
    )
    let codexCredentialSurface = ([
        codexCredentialSnapshot.items.first?.activityText,
    ] + (codexCredentialSnapshot.items.first?.events.map(\.text) ?? []))
        .compactMap { $0 }
        .joined(separator: " ")
    guard codexCredentialSurface.contains("[已隐藏]"),
          !codexCredentialSurface.contains("codex-commentary-secret-1234567890"),
          !codexCredentialSurface.contains(codexCommentaryCredential),
          !codexCredentialSurface.contains("codex-json-secret-123456")
    else {
        fputs("Codex public commentary credential filtering failed\n", stderr)
        exit(1)
    }
    let parsedWithDirectory = CodexTaskProgressReader.parse(
        lines: [
            sessionMeta,
            timestampedStarted,
            publicCommentary,
            commandStarted,
            continuedCommentary,
            finalAnswer,
        ],
        modificationDate: now,
        now: now
    )
    guard parsedWithDirectory.items.first?.workingDirectory == "/tmp/threadhelm",
          let codexProjection = parsedWithDirectory.items.first?.projection,
          codexProjection.publicMessages.map(\.text) == [
              "最终结果已经准备完成。",
              "继续检查最终构建与安装状态。",
              "第一行会被后续输出覆盖。 第二行。 第三行。 第四行覆盖第一行。",
          ],
          codexProjection.currentToolStatus?.text == "正在运行命令",
          codexProjection.terminalEvent == nil,
          parsedWithDirectory.items.first?.events.count == 4,
          parsedWithDirectory.items.first?.events.first?.text
            == "最终结果已经准备完成。",
          parsedWithDirectory.items.first?.events.allSatisfy({
              !$0.text.contains("secret")
                  && !$0.text.contains("隐藏推理")
          }) == true
    else {
        fputs("Codex cwd or complete safe events failed\n", stderr)
        exit(1)
    }

    let longEventText = String(repeating: "完整公开活动内容", count: 64)
    let completeEvents = (1...5).reduce(into: [TaskActivityEvent]()) { result, index in
        result = appendingTaskActivityEvent(
            TaskActivityEvent(
                kind: .commentary,
                occurredAt: now.addingTimeInterval(TimeInterval(index)),
                text: index == 5 ? longEventText : "安全事件 \(index)"
            ),
            to: result
        )
    }
    guard completeEvents.count == 5,
          completeEvents.last?.text == longEventText,
          (completeEvents.last?.text.count ?? 0) > 280
    else {
        fputs("complete activity event preservation failed\n", stderr)
        exit(1)
    }
    let firstLongParagraph = String(repeating: "甲", count: 5_000)
    let secondLongParagraph = String(repeating: "乙", count: 5_000)
    let completeParagraph = appendingTaskActivityParagraph(
        secondLongParagraph,
        to: firstLongParagraph
    )
    guard completeParagraph == "\(firstLongParagraph) \(secondLongParagraph)",
          completeParagraph.count == 10_001
    else {
        fputs("complete activity paragraph preservation failed\n", stderr)
        exit(1)
    }

    let secondStarted = #"{"timestamp":"2026-07-25T10:05:30Z","type":"event_msg","payload":{"type":"task_started"}}"#
    let currentTurnOnly = CodexTaskProgressReader.parse(
        lines: [
            timestampedStarted,
            publicCommentary,
            secondStarted,
            continuedCommentary,
        ],
        modificationDate: now,
        now: now
    )
    guard currentTurnOnly.items.first?.projection.publicMessages.map(\.text)
            == ["继续检查最终构建与安装状态。"],
          currentTurnOnly.items.first?.projection.currentToolStatus == nil,
          currentTurnOnly.items.first?.projection.terminalEvent == nil,
          currentTurnOnly.items.first?.events.map(\.text)
            == ["继续检查最终构建与安装状态。"]
    else {
        fputs("Codex current-turn activity reset failed\n", stderr)
        exit(1)
    }

    let full = TaskProgressCollectionSnapshot.displaying(
        (0..<7).map {
            TaskProgressItem(
                title: "Run \($0)",
                kind: .running,
                startedAt: now,
                updatedAt: now.addingTimeInterval(TimeInterval($0))
            )
        } + [
            TaskProgressItem(title: "Failed", kind: .failed, startedAt: now)
        ]
    )
    guard full.items.count == 8,
          full.compactProjection().items.count == 7,
          full.filtered(source: .all, state: .failed).count == 1
    else {
        fputs("full task collection projection or filtering failed\n", stderr)
        exit(1)
    }

    let claudeSessionID = "b687a9ef-4535-4bb4-a9d5-e692bbcdb0a6"
    let namedSessionMetadataOnly = #"{"type":"user","timestamp":"2026-08-12T06:22:05.276Z","message":{"role":"user","content":"<system-reminder>\nThe user named this session \"Pi验证\". This may indicate the session's focus or intent.\n</system-reminder>"}}"#
    let inactiveNamedSession = ClaudeTaskProgressReader.parseTranscript(
        lines: [namedSessionMetadataOnly],
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude-project",
        activeKind: nil,
        startedAt: now,
        modificationDate: now
    )
    guard inactiveNamedSession == nil else {
        fputs("inactive Claude metadata transcript reported as running\n", stderr)
        exit(1)
    }

    let claudePublicText = #"{"type":"assistant","timestamp":"2026-07-25T10:01:00.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"隐藏推理绝不显示"},{"type":"text","text":"正在检查 Claude 任务"}],"stop_reason":null}}"#
    let claudeToolUse = #"{"type":"assistant","timestamp":"2026-07-25T10:02:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-claude-1","name":"Bash","input":{"command":"echo secret"}}],"stop_reason":null}}"#
    let claudeToolResult = #"{"type":"user","timestamp":"2026-07-25T10:03:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-claude-1","content":"secret output"}]}}"#
    let claudeSecondPublicText = #"{"type":"assistant","timestamp":"2026-07-25T10:04:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"继续整理公开状态"}],"stop_reason":null}}"#
    let claudeLongPublicTextValue = String(repeating: "完整 Claude 输出内容", count: 40)
    let claudeLongPublicText = #"{"type":"assistant","timestamp":"2026-07-25T10:04:30.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(claudeLongPublicTextValue)"}],"stop_reason":null}}"#
    let claudeGitHubTestCredential = "gh" + "o_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
    let claudeCredentialText = #"{"type":"assistant","timestamp":"2026-07-25T10:05:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"client_secret=claude-client-secret-123456 access_token=\#(claudeGitHubTestCredential)"}],"stop_reason":null}}"#
    let claudeRawJSONText = #"{"type":"assistant","timestamp":"2026-07-25T10:06:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"{\"password\":\"claude-json-secret-123456\"}"}],"stop_reason":null}}"#
    let claudeWithEvents = ClaudeTaskProgressReader.parseTranscript(
        lines: [
            claudePublicText,
            claudeToolUse,
            claudeToolResult,
            claudeSecondPublicText,
            claudeLongPublicText,
        ],
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude-project",
        activeKind: .running,
        startedAt: now.addingTimeInterval(-30),
        modificationDate: now
    )
    guard let claudeProjection = claudeWithEvents?.projection,
          claudeProjection.publicMessages.count == 3,
          claudeProjection.publicMessages.map(\.text) == [
              claudeLongPublicTextValue,
              "继续整理公开状态",
              "正在检查 Claude 任务",
          ],
          // tool_result 已收敛：不显示陈旧工具状态
          claudeProjection.currentToolStatus == nil,
          claudeProjection.terminalEvent == nil,
          claudeProjection.publicMessages.allSatisfy({
              !$0.text.contains("secret")
                  && !$0.text.contains("隐藏推理")
          }) == true
    else {
        fputs("Claude complete safe events or privacy filtering failed\n", stderr)
        exit(1)
    }

    let claudeWaitingInput = #"{"type":"assistant","timestamp":"2026-07-25T10:08:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-wait-1","name":"request_user_input","input":{}}],"stop_reason":"tool_use"}}"#
    let claudeWaitingItem = ClaudeTaskProgressReader.parseTranscript(
        lines: [claudeWaitingInput],
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude-project",
        activeKind: .waitingForInput,
        startedAt: now.addingTimeInterval(-30),
        modificationDate: now
    )
    guard claudeWaitingItem?.kind == .waitingForInput,
          claudeWaitingItem?.projection.terminalEvent == nil,
          claudeWaitingItem?.projection.currentToolStatus == nil,
          claudeWaitingItem?.projection.publicMessages.isEmpty == true,
          claudeWaitingItem?.statusText == "等你确认"
    else {
        fputs("Claude waiting input must not fabricate terminal event\n", stderr)
        exit(1)
    }

    // 两个不同活动工具必须产生不同事件 ID（§4.4 禁止跨事件误认）。
    let claudeToolA = #"{"type":"assistant","timestamp":"2026-07-25T10:09:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-a","name":"Bash","input":{}}],"stop_reason":"tool_use"}}"#
    let claudeToolB = #"{"type":"assistant","timestamp":"2026-07-25T10:10:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-b","name":"Edit","input":{}}],"stop_reason":"tool_use"}}"#
    let claudeToolAItem = ClaudeTaskProgressReader.parseTranscript(
        lines: [claudeToolA],
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude-project",
        activeKind: .running,
        startedAt: now.addingTimeInterval(-30),
        modificationDate: now
    )
    let claudeToolBItem = ClaudeTaskProgressReader.parseTranscript(
        lines: [claudeToolA, claudeToolB],
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude-project",
        activeKind: .running,
        startedAt: now.addingTimeInterval(-30),
        modificationDate: now
    )
    guard claudeToolAItem?.projection.currentToolStatus?.id
            != claudeToolBItem?.projection.currentToolStatus?.id,
          claudeToolBItem?.projection.currentToolStatus?.id.stableSourceKey
            == "active-tool-tool-b"
    else {
        fputs("Claude active tool must keep a stable per-call event ID\n", stderr)
        exit(1)
    }

    let claudeCredentialSnapshot = ClaudeTaskProgressReader.parseTranscript(
        lines: [claudeCredentialText, claudeRawJSONText],
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude-project",
        activeKind: .running,
        startedAt: now.addingTimeInterval(-30),
        modificationDate: now
    )
    let claudeCredentialSurface = ([
        claudeCredentialSnapshot?.activityText,
    ] + (claudeCredentialSnapshot?.events.map(\.text) ?? []))
        .compactMap { $0 }
        .joined(separator: " ")
    guard claudeCredentialSurface.contains("[已隐藏]"),
          !claudeCredentialSurface.contains("claude-client-secret-123456"),
          !claudeCredentialSurface.contains(claudeGitHubTestCredential),
          !claudeCredentialSurface.contains("claude-json-secret-123456")
    else {
        fputs("Claude public text credential filtering failed\n", stderr)
        exit(1)
    }

    // Append-only reducer regression: public message behind >200 tool records
    // must survive a tool-only append (AC-15: tool-only updates don't clear
    // publicMessages; reducer retains state, doesn't truncate at 200 lines).
    var claudeReducer = ClaudeTaskProgressReader.ClaudeReducerState(modificationDate: now)
    // Public message at the head
    claudeReducer.apply(
        #"{"type":"assistant","timestamp":"2026-07-25T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"这是必须保留的公开消息"}]}}"#,
        modificationDate: now
    )
    for i in 0..<205 {
        let secs = i % 60
        let mins = (i / 60) % 60
        let hours = 10 + (i / 3600)
        let ts = "2026-07-25T\(String(format: "%02d", hours)):\(String(format: "%02d", mins)):\(String(format: "%02d", secs)).000Z"
        claudeReducer.apply(
            #"{"type":"assistant","timestamp":"\#(ts)","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-\#(i)","name":"Bash","input":{}}],"stop_reason":"tool_use"}}"#,
            modificationDate: now
        )
    }
    // Append a final tool-only record (simulating incremental append)
    claudeReducer.apply(
        #"{"type":"assistant","timestamp":"2026-07-25T11:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-append","name":"Bash","input":{}}],"stop_reason":"tool_use"}}"#,
        modificationDate: now
    )
    let appendItem = claudeReducer.buildItem(
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude-project",
        processID: nil,
        processStartIdentity: nil,
        activeKind: .running,
        startedAt: now.addingTimeInterval(-30),
        modificationDate: now,
        now: now,
        statusOverride: nil,
        allowsAgentOpen: true
    )
    guard appendItem?.projection.publicMessages.contains(where: {
        $0.text == "这是必须保留的公开消息"
    }) == true,
    appendItem?.projection.currentToolStatus?.id.stableSourceKey
        == "active-tool-tool-append"
    else {
        fputs("Claude append-only reducer must retain public message behind 200+ tool records\n", stderr)
        exit(1)
    }

    let toolActive = CodexTaskProgressReader.parse(
        lines: [timestampedStarted, publicCommentary, commandStarted, hiddenReasoning],
        modificationDate: now,
        now: now
    )
    let expectedToolUpdate = ISO8601DateFormatter().date(from: "2026-07-25T10:03:00Z")
    guard toolActive.items.first?.updatedAt == expectedToolUpdate,
          toolActive.items.first?.activityText
            == "正在运行命令 · 第一行会被后续输出覆盖。 第二行。 第三行。 第四行覆盖第一行。",
          toolActive.items.first?.activityText?.contains("secret") == false,
          toolActive.items.first?.activityText?.contains("隐藏推理") == false
    else {
        fputs("safe active tool summary or updatedAt failed\n", stderr)
        exit(1)
    }

    let commentaryFallback = CodexTaskProgressReader.parse(
        lines: [
            timestampedStarted,
            publicCommentary,
            commandStarted,
            commandFinished,
            hiddenReasoning,
        ],
        modificationDate: now,
        now: now
    )
    let expectedCommentaryUpdate = ISO8601DateFormatter().date(from: "2026-07-25T10:04:00Z")
    guard commentaryFallback.items.first?.updatedAt == expectedCommentaryUpdate,
          commentaryFallback.items.first?.activityText
            == "第一行会被后续输出覆盖。 第二行。 第三行。 第四行覆盖第一行。",
          commentaryFallback.items.first?.activityText?.contains("secret") == false,
          commentaryFallback.items.first?.activityText?.contains("隐藏推理") == false
    else {
        fputs("public commentary fallback or privacy filtering failed\n", stderr)
        exit(1)
    }

    let rollingCommentary = CodexTaskProgressReader.parse(
        lines: [
            timestampedStarted,
            publicCommentary,
            commandStarted,
            commandFinished,
            continuedCommentary,
            continuedCommentary,
            hiddenReasoning,
        ],
        modificationDate: now,
        now: now
    )
    let expectedAccumulatedUpdate = ISO8601DateFormatter().date(
        from: "2026-07-25T10:06:00Z"
    )
    guard rollingCommentary.items.first?.updatedAt == expectedAccumulatedUpdate,
          rollingCommentary.items.first?.activityText
            == "第一行会被后续输出覆盖。 第二行。 第三行。 第四行覆盖第一行。 继续检查最终构建与安装状态。"
    else {
        fputs("single-paragraph public commentary accumulation failed\n", stderr)
        exit(1)
    }

    let sortingBase = Date(timeIntervalSince1970: 10_000)
    let scrollingPresentation = TaskProgressSnapshot.displaying((0..<7).map { index in
        TaskProgressItem(
            title: "活跃任务 \(index + 1)",
            kind: index == 1 ? .waitingForInput : .running,
            startedAt: sortingBase.addingTimeInterval(Double(index)),
            updatedAt: sortingBase.addingTimeInterval(Double(index))
        )
    })
    guard scrollingPresentation.isScrollable,
          scrollingPresentation.items.count == 7,
          scrollingPresentation.items.first?.title == "活跃任务 7",
          scrollingPresentation.items.last?.title == "活跃任务 1",
          scrollingPresentation.items.contains(where: { $0.kind == .waitingForInput })
    else {
        fputs("active task scrolling selection or updatedAt sorting failed\n", stderr)
        exit(1)
    }

    let mixedPresentation = TaskProgressSnapshot.displaying([
        TaskProgressItem(
            title: "运行任务",
            kind: .running,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(60)
        ),
        TaskProgressItem(
            title: "等待输入",
            kind: .waitingForInput,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(50)
        ),
        TaskProgressItem(
            title: "完成 A",
            kind: .completed,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(40)
        ),
        TaskProgressItem(
            title: "失败 B",
            kind: .failed,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(30)
        ),
        TaskProgressItem(
            title: "完成 C",
            kind: .completed,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(20)
        ),
        TaskProgressItem(
            title: "完成 D",
            kind: .completed,
            startedAt: sortingBase,
            updatedAt: sortingBase.addingTimeInterval(10)
        ),
    ])
    guard !mixedPresentation.isScrollable,
          mixedPresentation.items.map(\.title)
            == ["运行任务", "等待输入", "完成 A", "失败 B", "完成 C"]
    else {
        fputs("active-first terminal backfill failed\n", stderr)
        exit(1)
    }

    let titledUserMessage = ##"{"type":"event_msg","payload":{"type":"user_message","message":"# Files mentioned by the user:\n/a.png\n## My request for Codex:\n列出具体任务名称"}}"##
    let titled = CodexTaskProgressReader.parse(
        lines: [titledUserMessage, started],
        modificationDate: now,
        now: now
    )
    guard titled.items.first?.title == "列出具体任务名称" else {
        fputs("task title extraction failed\n", stderr)
        exit(1)
    }

    let indexedThreadID = "12345678-1234-4abc-8def-1234567890ab"
    let indexedRollout = URL(fileURLWithPath:
        "/tmp/rollout-2026-07-16T16-52-47-\(indexedThreadID).jsonl"
    )
    let indexedTitle = CodexTaskProgressReader.resolvedTitle(
        for: indexedRollout,
        indexedTitles: [indexedThreadID: "正式任务名称"],
        fallback: "Codex 任务"
    )
    guard indexedTitle == "正式任务名称" else {
        fputs("task index title mapping failed\n", stderr)
        exit(1)
    }

    guard codexThreadURL(threadID: indexedThreadID)?.absoluteString
            == "codex://threads/\(indexedThreadID)",
          codexThreadURL(threadID: "not-a-thread") == nil
    else {
        fputs("Codex thread deep-link validation failed\n", stderr)
        exit(1)
    }

    let unreadState = CodexTaskProgressReader.UnreadThreadState(
        ids: [indexedThreadID],
        isAvailable: true
    )
    let readState = CodexTaskProgressReader.UnreadThreadState(
        ids: [],
        isAvailable: true
    )
    let unavailableState = CodexTaskProgressReader.UnreadThreadState(
        ids: [],
        isAvailable: false
    )
    // 未读信号定格：集合里全是旧 thread，此后创建的会话从未被它记录。
    // thread id 是 UUIDv7，字典序即时间序。
    let staleSignalState = CodexTaskProgressReader.UnreadThreadState(
        ids: ["019ecbd4-4be0-7362-adb5-fcce435d88fe"],
        isAvailable: true
    )
    let threadNewerThanSignal = "01a03cdd-decc-76b1-91d4-e782100a9ced"
    let threadOlderThanSignal = "019eb000-0000-7000-8000-000000000000"
    let completedVisibilityCases = [
        CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(-3600),
            now: now,
            unreadState: unreadState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: readState
        ),
        CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: unavailableState,
            fallbackVisibility: 120
        ),
        CodexTaskProgressReader.shouldDisplay(
            kind: .failed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(-3600),
            now: now,
            unreadState: unreadState
        ),
        // 信号定格之后创建的会话：不在集合里不代表已读，必须显示。
        CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: threadNewerThanSignal,
            modificationDate: now,
            now: now,
            unreadState: staleSignalState
        ),
        // 信号覆盖得到的旧会话：不在集合里就是真的已读，仍要隐藏，
        // 否则等于废掉「已读不再占位」这个产品意图。
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: threadOlderThanSignal,
            modificationDate: now,
            now: now,
            unreadState: staleSignalState
        ),
        // 空集合语义不变：无从分辨读没读时，保持「不在集合里即已读」。
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: threadNewerThanSignal,
            modificationDate: now,
            now: now,
            unreadState: readState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(
                -(completedTaskPanelRetention + 1)
            ),
            now: now,
            unreadState: unreadState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .failed,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: readState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(-180),
            now: now,
            unreadState: unavailableState,
            fallbackVisibility: 120
        ),
        CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(
                -(completedTaskPanelRetention - 1)
            ),
            now: now,
            unreadState: unavailableState
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now.addingTimeInterval(
                -(completedTaskPanelRetention + 1)
            ),
            now: now,
            unreadState: unavailableState
        ),
        CodexTaskProgressReader.shouldDisplay(
            kind: .running,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: readState,
            terminalDate: now.addingTimeInterval(
                -(completedTaskPanelRetention + 1)
            )
        ),
        !CodexTaskProgressReader.shouldDisplay(
            kind: .completed,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: unreadState,
            terminalDate: now.addingTimeInterval(
                -(completedTaskPanelRetention + 1)
            )
        ),
    ]
    guard completedVisibilityCases.allSatisfy({ $0 }),
          CodexTaskProgressReader.shouldDisplay(
            kind: .running,
            threadID: indexedThreadID,
            modificationDate: now,
            now: now,
            unreadState: readState
          )
    else {
        fputs("completed task filtering failed\n", stderr)
        exit(1)
    }
}
