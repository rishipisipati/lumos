#!/usr/bin/env python3
"""End-to-end stress test for the Lumos indexer.

Drives build/lumos-index (the same engine the app uses, without UI) against a
root folder and measures how long the index takes to become exactly right after:

  1. a cold scan of the root
  2. adding COUNT files while the engine runs
  3. deleting them while the engine runs
  4. adding them while the engine is stopped (journal replay on relaunch)
  5. deleting them while the engine is stopped
  6. kill -9 in the middle of a live add, then relaunch
  7. a drift check: the long-running index vs a fresh cold scan

Search latency is sampled throughout the live phases.

  make cli && python3 scripts/stress_index.py --root ~/Documents --count 1000000
"""

from __future__ import annotations

import argparse
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import stress_files  # noqa: E402

EXTRA_FILES = 10  # 6 special files + 4 large blobs created by stress_files.generate


class EngineError(RuntimeError):
    pass


class Engine:
    def __init__(self, binary: Path, home: Path, root: Path) -> None:
        self.binary = binary
        self.home = home
        self.root = root
        self.lock = threading.Lock()
        self.process: subprocess.Popen[str] | None = None

    def start(self) -> None:
        env = dict(os.environ)
        env["LUMOS_HOME"] = str(self.home)
        self.process = subprocess.Popen(
            [str(self.binary), "--root", str(self.root)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )

    def ask(self, command: str, terminators: tuple[str, ...]) -> list[str]:
        with self.lock:
            if self.process is None or self.process.stdin is None or self.process.stdout is None:
                raise EngineError("engine is not running")
            self.process.stdin.write(command + "\n")
            self.process.stdin.flush()
            lines: list[str] = []
            while True:
                line = self.process.stdout.readline()
                if line == "":
                    raise EngineError(f"engine exited while answering {command!r}")
                line = line.rstrip("\n")
                lines.append(line)
                if line.startswith(terminators):
                    return lines

    def count(self, query: str) -> tuple[int, int]:
        parts = self.ask(f"count {query}", ("count ", "error"))[-1].split()
        if parts[0] != "count":
            raise EngineError(" ".join(parts))
        return int(parts[1]), int(parts[2])

    def objects(self) -> int:
        line = self.ask("status", ("status ",))[-1]
        for part in line.split():
            if part.startswith("objects="):
                return int(part.split("=", 1)[1])
        raise EngineError(f"no object count in {line!r}")

    def status_line(self) -> str:
        return self.ask("status", ("status ",))[-1]

    def wait_loaded(self, timeout: float) -> float:
        """Waits until the saved index is loaded, so counts reflect it."""
        started = time.time()
        while time.time() - started < timeout:
            if " phase=starting " not in self.status_line():
                return time.time() - started
            time.sleep(0.05)
        raise EngineError(f"engine still loading after {timeout}s")

    def wait_idle(self, timeout: float) -> int:
        parts = self.ask(f"wait-idle {timeout}", ("idle ", "timeout "))[-1].split()
        if parts[0] != "idle":
            raise EngineError(f"engine not idle after {timeout}s: {self.status_line()}")
        return int(parts[1])

    def quit(self) -> None:
        self.ask("quit", ("bye",))
        if self.process is not None:
            self.process.wait(timeout=60)
        self.process = None

    def kill(self) -> None:
        if self.process is not None:
            self.process.kill()
            self.process.wait(timeout=60)
        self.process = None


class LatencySampler:
    """Runs a name search every interval to show search never blocks on indexing."""

    def __init__(self, engine: Engine, query: str, interval: float) -> None:
        self.engine = engine
        self.query = query
        self.interval = interval
        self.samples: list[int] = []
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self) -> None:
        while not self.stop_event.is_set():
            started = time.time()
            try:
                self.engine.count(self.query)
            except EngineError:
                return
            self.samples.append(int((time.time() - started) * 1000))
            self.stop_event.wait(self.interval)

    def __enter__(self) -> "LatencySampler":
        self.thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self.stop_event.set()
        self.thread.join(timeout=30)

    def summary(self) -> str:
        if not self.samples:
            return "no samples"
        ordered = sorted(self.samples)
        p95 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))]
        return f"search p50 {int(statistics.median(ordered))} ms, p95 {p95} ms, max {ordered[-1]} ms ({len(ordered)} samples)"


def folder_query(folder: Path) -> str:
    return f'path:"{folder}/" file:'


def wait_for_count(engine: Engine, query: str, expected: int, timeout: float) -> float:
    started = time.time()
    last = -1
    while time.time() - started < timeout:
        last, _ms = engine.count(query)
        if last == expected:
            return time.time() - started
        time.sleep(0.25)
    raise EngineError(f"expected {expected} matches for {query!r}, still {last} after {timeout}s")


def report(results: list[tuple[str, str]], label: str, detail: str) -> None:
    results.append((label, detail))
    print(f"[ok] {label}: {detail}", flush=True)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(Path.home() / "Documents"))
    parser.add_argument("--folder", default=None, help="Stress folder inside root (default: ROOT/Lumos Stress Live)")
    parser.add_argument("--count", type=int, default=stress_files.FILE_COUNT)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--binary", default=str(Path(__file__).resolve().parent.parent / "build" / "lumos-index"))
    parser.add_argument("--timeout", type=float, default=900)
    args = parser.parse_args(argv)

    root = Path(os.path.realpath(Path(args.root).expanduser()))
    folder = Path(args.folder).expanduser() if args.folder else root / "Lumos Stress Live"
    binary = Path(args.binary)
    if not binary.exists():
        print(f"missing {binary}; run `make cli` first", file=sys.stderr)
        return 2
    if folder.exists():
        print(f"{folder} already exists; remove it first", file=sys.stderr)
        return 2
    expected = args.count + EXTRA_FILES
    query = folder_query(folder)
    home = Path(tempfile.mkdtemp(prefix="lumos-stress-"))
    results: list[tuple[str, str]] = []
    engine = Engine(binary, home, root)
    try:
        started = time.time()
        engine.start()
        engine.wait_idle(args.timeout)
        report(results, "cold scan", f"{engine.objects():,} objects in {time.time() - started:.1f}s")

        with LatencySampler(engine, "report", 0.5) as sampler:
            started = time.time()
            stress_files.generate(folder, args.count, args.workers)
            generated = time.time() - started
            lag = wait_for_count(engine, query, expected, args.timeout)
        report(results, "live add", f"{expected:,} files written in {generated:.1f}s, index exact {lag:.1f}s later; {sampler.summary()}")

        with LatencySampler(engine, "report", 0.5) as sampler:
            started = time.time()
            stress_files.delete_folder(folder, args.workers)
            deleted = time.time() - started
            lag = wait_for_count(engine, query, 0, args.timeout)
        report(results, "live delete", f"deleted in {deleted:.1f}s, index exact {lag:.1f}s later; {sampler.summary()}")

        engine.quit()
        stress_files.generate(folder, args.count, args.workers)
        started = time.time()
        engine.start()
        loaded = engine.wait_loaded(args.timeout)
        wait_for_count(engine, query, expected, args.timeout)
        report(results, "add while stopped", f"index loaded in {loaded:.1f}s, exact {time.time() - started:.1f}s after relaunch")

        engine.quit()
        stress_files.delete_folder(folder, args.workers)
        started = time.time()
        engine.start()
        loaded = engine.wait_loaded(args.timeout)
        wait_for_count(engine, query, 0, args.timeout)
        report(results, "delete while stopped", f"index loaded in {loaded:.1f}s, exact {time.time() - started:.1f}s after relaunch")

        writer = threading.Thread(target=stress_files.generate, args=(folder, args.count, args.workers))
        writer.start()
        while stress_files.count_files(folder) < args.count // 2 if folder.exists() else True:
            time.sleep(0.5)
        engine.kill()
        engine.start()
        engine.wait_loaded(args.timeout)
        writer.join()
        lag = wait_for_count(engine, query, expected, args.timeout)
        report(results, "kill -9 mid add", f"index exact {lag:.1f}s after the writer finished")

        stress_files.delete_folder(folder, args.workers)
        wait_for_count(engine, query, 0, args.timeout)
        engine.wait_idle(args.timeout)
        long_running = engine.objects()
        fresh_home = Path(tempfile.mkdtemp(prefix="lumos-stress-fresh-"))
        fresh = Engine(binary, fresh_home, root)
        fresh.start()
        fresh.wait_idle(args.timeout)
        engine.wait_idle(args.timeout)
        long_running = engine.objects()
        cold = fresh.objects()
        fresh.quit()
        shutil.rmtree(fresh_home, ignore_errors=True)
        report(results, "drift", f"long-running index {long_running:,} vs fresh scan {cold:,} (difference {long_running - cold:+,})")
        engine.quit()
    except Exception:
        engine.kill()
        raise
    finally:
        if folder.exists():
            shutil.rmtree(folder, ignore_errors=True)
        shutil.rmtree(home, ignore_errors=True)
    print("\nsummary")
    for label, detail in results:
        print(f"  {label:<22} {detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
