import Foundation

// GitHub Actions runs and jobs are only in the REST API (GraphQL has check
// suites, not workflow runs with their attempts and timings), so this is
// the one place Gannin calls REST. It has its own budget, 5,000 requests an
// hour, reported to `onRESTRateLimit`.

extension GitHubAPI {
    /// Non-archived repos pushed to since `since`, most recent first, with
    /// their default branch. Scheduled workflows keep running in repos
    /// nobody pushes to, so callers reach back further than the window.
    func actionsRepositories(org: String, pushedSince since: Date) async throws -> [ActionsRepository] {
        struct Node: Decodable {
            struct Branch: Decodable { let name: String }
            let nameWithOwner: String
            let pushedAt: Date?
            let defaultBranchRef: Branch?
        }
        struct Response: Decodable {
            struct Org: Decodable { let repositories: PagedConnection<Node> }
            let organization: Org?
        }
        var reachedOlder = false
        let nodes: [Node] = try await paginate(limit: 2000) { cursor in
            guard !reachedOlder else { return nil }
            var variables = ["login": org]
            if let cursor { variables["cursor"] = cursor }
            let response: Response = try await query("""
                query($login: String!, $cursor: String) {
                  \(GitHubAccounts.ownerField(org)) {
                    repositories(first: 100, after: $cursor, isArchived: false, orderBy: { field: PUSHED_AT, direction: DESC }\(GitHubAccounts.repositoryArguments(org))) {
                      pageInfo { hasNextPage endCursor }
                      nodes { nameWithOwner pushedAt defaultBranchRef { name } }
                    }
                  }
                }
                """, variables: variables)
            if let last = response.organization?.repositories.nodes.last, (last.pushedAt ?? .distantPast) < since {
                reachedOlder = true
            }
            return response.organization?.repositories
        }
        return nodes
            .filter { ($0.pushedAt ?? .distantPast) >= since }
            .map { ActionsRepository(name: $0.nameWithOwner, defaultBranch: $0.defaultBranchRef?.name, coveredFrom: .distantFuture, syncedAt: .distantPast) }
    }

    /// Runs created in `[from, to)` in one repo. The runs list stops at
    /// 1,000 results for a filtered query, so a range holding more is split
    /// in half until each part fits.
    func workflowRuns(
        repo: String,
        from: Date,
        to: Date,
        onPage: (_ fetched: Int) -> Void = { _ in }
    ) async throws -> [WorkflowRun] {
        var fetched = 0
        return try await runsSplitting(repo: repo, from: from, to: to) { count in
            fetched += count
            onPage(fetched)
        }
    }

    private func runsSplitting(repo: String, from: Date, to: Date, added: (Int) -> Void) async throws -> [WorkflowRun] {
        let created = "\(Self.restTimestamp(from))..\(Self.restTimestamp(to.addingTimeInterval(-1)))"
        var page = 1
        var runs: [WorkflowRun] = []
        while true {
            let response: RawRunsPage = try await rest(
                "repos/\(repo)/actions/runs",
                query: ["created": created, "per_page": "100", "page": "\(page)", "exclude_pull_requests": "true"]
            )
            if page == 1, response.totalCount > 1000, to.timeIntervalSince(from) > 60 * 60 {
                let middle = from.addingTimeInterval(to.timeIntervalSince(from) / 2)
                let first = try await runsSplitting(repo: repo, from: from, to: middle, added: added)
                let second = try await runsSplitting(repo: repo, from: middle, to: to, added: added)
                return first + second
            }
            let models = response.workflowRuns.compactMap { $0.value?.model(repo: repo) }
            runs += models
            added(models.count)
            guard response.workflowRuns.count == 100, runs.count < min(response.totalCount, 1000) else { break }
            page += 1
        }
        return runs
    }

    /// Jobs in every attempt of a run, so a job that failed and passed on
    /// a re-run shows as both.
    func workflowJobs(repo: String, runID: Int) async throws -> [WorkflowJob] {
        var jobs: [WorkflowJob] = []
        var page = 1
        while true {
            let response: RawJobsPage = try await rest(
                "repos/\(repo)/actions/runs/\(runID)/jobs",
                query: ["filter": "all", "per_page": "100", "page": "\(page)"]
            )
            jobs += response.jobs.compactMap { $0.value?.model }
            guard response.jobs.count == 100, jobs.count < response.totalCount, page < 5 else { break }
            page += 1
        }
        return jobs
    }

    /// GitHub's search date syntax, to the second in UTC.
    private static func restTimestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    // MARK: REST transport

    private static let restBase = URL(string: "https://api.github.com/")!

    private static let restDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// A GET against the REST API. Timeouts are retried twice, and a
    /// secondary rate limit is waited out once when GitHub says how long.
    func rest<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var components = URLComponents(url: Self.restBase.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        var attempt = 0
        while true {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                try Task.checkCancellation()
                throw APIError.network(error.localizedDescription)
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if let http, let budget = Self.restRateLimit(http) { onRESTRateLimit?(budget) }
            if status == 401 { throw APIError.unauthorized }
            if (502...504).contains(status), attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .seconds(attempt * 2))
                continue
            }
            if status == 403 || status == 429, attempt == 0,
               let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init), wait <= 60 {
                attempt += 1
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            guard (200..<300).contains(status) else {
                throw APIError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
            }
            do {
                return try Self.restDecoder.decode(T.self, from: data)
            } catch {
                throw APIError.decoding(String(describing: error))
            }
        }
    }

    /// A write through the REST API (creating a repo), with a JSON body. Not
    /// retried, since it may have gone through.
    func restWrite<T: Decodable>(_ method: String, _ path: String, body: [String: Any]) async throws -> T {
        var request = URLRequest(url: Self.restBase.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if let http, let budget = Self.restRateLimit(http) { onRESTRateLimit?(budget) }
        if status == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try Self.restDecoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private static func restRateLimit(_ response: HTTPURLResponse) -> RateLimit? {
        guard let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
              let limit = response.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init),
              let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) else {
            return nil
        }
        return RateLimit(cost: 1, remaining: remaining, limit: limit, resetAt: Date(timeIntervalSince1970: reset))
    }
}

// MARK: - Raw shapes

private struct RawRunsPage: Decodable {
    let totalCount: Int
    let workflowRuns: [Lossy<RawRun>]
}

private struct RawRun: Decodable {
    struct Actor: Decodable { let login: String }

    let id: Int
    let name: String?
    let path: String?
    let workflowId: Int
    let event: String
    let headBranch: String?
    let headSha: String
    let runNumber: Int
    let runAttempt: Int?
    let status: String?
    let conclusion: String?
    let createdAt: Date
    let runStartedAt: Date?
    let updatedAt: Date
    let actor: Actor?
    let htmlUrl: URL

    func model(repo: String) -> WorkflowRun {
        WorkflowRun(
            id: id,
            repo: repo,
            workflowID: workflowId,
            name: name ?? path.map { ($0 as NSString).lastPathComponent } ?? "Workflow \(workflowId)",
            // Dynamic workflows (Dependabot, Pages) report a path with a
            // ref after an @; the file is what identifies them.
            path: path.map { String($0.split(separator: "@").first ?? Substring($0)) } ?? "",
            event: event,
            branch: headBranch,
            headSha: headSha,
            runNumber: runNumber,
            attempt: runAttempt ?? 1,
            status: status ?? "completed",
            conclusion: conclusion,
            createdAt: createdAt,
            startedAt: runStartedAt,
            updatedAt: updatedAt,
            actor: actor?.login,
            url: htmlUrl
        )
    }
}

private struct RawJobsPage: Decodable {
    let totalCount: Int
    let jobs: [Lossy<RawJob>]
}

private struct RawJob: Decodable {
    struct Step: Decodable {
        let name: String
        let number: Int
        let conclusion: String?
        let startedAt: Date?
        let completedAt: Date?
    }

    let id: Int
    let runId: Int
    let runAttempt: Int?
    let name: String
    let status: String
    let conclusion: String?
    let createdAt: Date?
    let startedAt: Date?
    let completedAt: Date?
    let labels: [String]?
    let runnerName: String?
    let steps: [Step]?
    let htmlUrl: URL?

    var model: WorkflowJob {
        WorkflowJob(
            id: id,
            runID: runId,
            runAttempt: runAttempt ?? 1,
            name: name,
            status: status,
            conclusion: conclusion,
            createdAt: createdAt,
            startedAt: startedAt,
            completedAt: completedAt,
            labels: labels ?? [],
            runnerName: runnerName,
            steps: (steps ?? []).map {
                WorkflowStep(name: $0.name, number: $0.number, conclusion: $0.conclusion, startedAt: $0.startedAt, completedAt: $0.completedAt)
            },
            url: htmlUrl
        )
    }
}
