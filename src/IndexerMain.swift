import Foundation

private let daemonIdleLimit: TimeInterval = 15 * 60

/// Headless Lumos engine.
///
///   lumos-index --serve [--root PATH ...]
///     Background indexer for the `lumos` CLI: owns the index, answers queries on
///     the support folder's socket, exits after `daemonIdleLimit` without queries
///     or when the app takes over. Roots default to the app's configured folders.
///
///   lumos-index --root PATH [--root PATH ...]   (stress harness)
///     Commands on stdin, one per line:
///     status | count QUERY | list N QUERY | wait-idle SECONDS | save | reindex | quit
///
/// The index folder is $LUMOS_HOME or ~/Library/Application Support/Lumos.
@main
struct IndexerMain {
    static func main() {
        let roots = parseRoots(CommandLine.arguments)
        if CommandLine.arguments.contains("--serve") {
            serve(roots: roots)
        }
        if roots.isEmpty {
            fputs("usage: lumos-index --serve [--root PATH ...] | lumos-index --root PATH [--root PATH ...]\n", stderr)
            exit(2)
        }
        let service: IndexService
        do {
            service = IndexService(folder: try lumosSupportFolder(), roots: roots)
            try service.start()
        } catch {
            fputs("lumos-index: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let command = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let argument = trimmed.count > command.count ? String(trimmed.dropFirst(command.count + 1)) : ""
            switch command {
            case "status":
                print(describe(service.status(), idle: service.isIdle()))
            case "count":
                let started = DispatchTime.now()
                let ids = service.store.readForSearch { data, _, trigrams in
                    searchIndex(data, query: parseQuery(argument), showHidden: true, sortColumn: .name, ascending: true, trigrams: trigrams)
                }
                print("count \(ids.count) \(elapsedMs(started))")
            case "list":
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                let limit = Int(parts.first ?? "") ?? 10
                let query = parts.count > 1 ? parts[1] : ""
                let paths = service.store.readForSearch { data, _, trigrams -> [String] in
                    let ids = searchIndex(data, query: parseQuery(query), showHidden: true, sortColumn: .name, ascending: true, trigrams: trigrams)
                    return ids.prefix(limit).map { data.fullPath($0) }
                }
                for path in paths {
                    print("path \(path)")
                }
                print("end \(paths.count)")
            case "wait-idle":
                let started = DispatchTime.now()
                let timeout = Double(argument) ?? 600
                print(waitForIdle(service, timeout: timeout) ? "idle \(elapsedMs(started))" : "timeout \(elapsedMs(started))")
            case "save":
                let started = DispatchTime.now()
                service.saveNow()
                print("saved \(elapsedMs(started))")
            case "reindex":
                service.reindex()
                print("ok")
            case "quit":
                let started = DispatchTime.now()
                service.stop()
                print("bye \(elapsedMs(started))")
                exit(0)
            case "":
                continue
            default:
                print("error unknown command \(command)")
            }
        }
        service.stop()
    }

    private static func serve(roots: [String]) -> Never {
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        let chosenRoots: [String]
        if roots.isEmpty {
            guard let defaults = UserDefaults(suiteName: appDefaultsDomain) else {
                fputs("lumos-index: cannot read the Lumos settings domain \(appDefaultsDomain)\n", stderr)
                exit(1)
            }
            chosenRoots = configuredIndexRoots(defaults)
        } else {
            chosenRoots = roots
        }
        let control = DispatchQueue(label: "lumos.daemon.control")
        var lastRequest = Date()
        var stopping = false
        var service: IndexService?
        var server: QueryServer?
        func shutdown(_ reason: String) {
            // Delay lets a "stopping" reply reach the client before the socket closes.
            control.asyncAfter(deadline: .now() + 0.1) {
                if stopping {
                    return
                }
                stopping = true
                fputs("lumos-index: stopping (\(reason))\n", stderr)
                server?.stop()
                service?.stop()
                exit(0)
            }
        }
        do {
            let started = IndexService(folder: try lumosSupportFolder(), roots: chosenRoots)
            try started.start()
            service = started
            server = try startQueryServer(
                started,
                owner: .daemon,
                onRequest: {
                    control.async {
                        lastRequest = Date()
                    }
                },
                shutdown: {
                    shutdown("asked to stop")
                }
            )
        } catch {
            fputs("lumos-index: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        fputs("lumos-index: serving \(chosenRoots.joined(separator: ", ")) (pid \(getpid()))\n", stderr)

        var signalSources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: control)
            source.setEventHandler {
                shutdown("signal \(number)")
            }
            source.resume()
            signalSources.append(source)
        }
        let activity = DispatchSource.makeTimerSource(queue: control)
        activity.schedule(deadline: .now() + 30, repeating: 30)
        activity.setEventHandler {
            if Date().timeIntervalSince(lastRequest) >= daemonIdleLimit {
                shutdown("idle for \(Int(daemonIdleLimit / 60)) minutes")
            }
        }
        activity.resume()
        withExtendedLifetime((signalSources, activity)) {
            dispatchMain()
        }
    }

    private static func parseRoots(_ arguments: [String]) -> [String] {
        var roots: [String] = []
        var index = 1
        while index < arguments.count {
            if arguments[index] == "--root" && index + 1 < arguments.count {
                roots.append(arguments[index + 1])
                index += 2
                continue
            }
            index += 1
        }
        return roots
    }

    private static func describe(_ status: IndexStatus, idle: Bool) -> String {
        return "status phase=\(status.phase.rawValue) objects=\(status.objectCount) idle=\(idle) message=\(status.message)"
            + (status.problem.map { " problem=\($0)" } ?? "")
    }

    private static func elapsedMs(_ started: DispatchTime) -> Int {
        return Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
    }

    /// Idle means no queued work, FSEvents flushed, and still nothing queued
    /// after the watcher latency has passed.
    private static func waitForIdle(_ service: IndexService, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if service.isIdle() {
                service.flushEvents()
                Thread.sleep(forTimeInterval: 0.8)
                if service.isIdle() {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
