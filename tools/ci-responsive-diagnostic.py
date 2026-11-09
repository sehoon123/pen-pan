#!/usr/bin/env python3
"""One bounded responsive-scrolling diagnostic; never a required-suite replacement."""
import argparse
import datetime
import difflib
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

BASE = "fd38445f638b3bb73ce650672497b399205b8885"
TREE = "8182081b5ff843ac43bb294d90bc64147973eb3d"
HASHES = {
    "pen-pan.swift": "a420b7fa1e9f6847e0c9db998ca76bbc620be27e7720344ce6ec5b5f86e2f0ad",
    "pen-pan-tests.swift": "aaee264735f2d8959bcc75d3c59b3095771ac909440c6a962d0de3a2eaba3720",
    "Makefile": "611a362e54de5d88efc3c1e04e7636c03f6a63bfeb4dfc37d96590b6f18a140e",
}
# These are proposed public diagnostic paths, not authorization to create/push them.
PUBLIC_PATHS = {"tools/ci-responsive-diagnostic.py", ".github/workflows/ci-responsive-diagnostic.yml"}
FLAGS = ["-O", "-warnings-as-errors", "-D", "TESTING", "-parse-as-library"]
NAME = "native NSScrollView observes explicit axes in both directions with reversal and no blocked motion"
SEAM = b"    private static func nativeAxisTest() {\n"
END = b"    static func main() {\n"
CTOR = b"let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))"
ALT_CTOR = CTOR.replace(b"NSScrollView(", b"NonResponsiveScrollView(")
SUBCLASS = (b"private final class NonResponsiveScrollView: NSScrollView {\n"
            b"    override class var isCompatibleWithResponsiveScrolling: Bool { false }\n"
            b"}\n\n")
CASES = [(a, r, s) for a in ("both", "vertical", "horizontal")
         for r in (False, True) for s in (-1.0, 1.0)]
MARKER = "NATIVE axis-context "


def check(ok, message):
    if not ok:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True, allow_nan=False) + "\n")


def native_body(source):
    check(source.count(SEAM) == source.count(END) == 1, "nonunique native/main seam")
    return source.split(SEAM)[1].split(END)[0]


def alternative(source):
    check(sha(source) == HASHES["pen-pan-tests.swift"], "test source hash drift")
    body = native_body(source)
    check(body.count(CTOR) == 1, "nonunique native constructor")
    anchor = b"@main\nstruct PenPanTests {\n"
    check(source.count(anchor) == 1 and SUBCLASS not in source, "subclass anchor drift")
    variant = source.replace(SEAM + body, SEAM + body.replace(CTOR, ALT_CTOR))
    variant = variant.replace(anchor, SUBCLASS + anchor)
    check(native_body(variant).replace(ALT_CTOR, CTOR) == body, "native body changed")
    restored = variant.replace(SUBCLASS, b"")
    before, tail = restored.split(SEAM)
    changed_body, after = tail.split(END)
    check(before + SEAM + changed_body.replace(ALT_CTOR, CTOR) + END + after == source,
          "nonminimal source delta")
    return variant


def field(pattern, text):
    matches = list(re.finditer(pattern, text))
    check(len(matches) == 1, "missing/duplicate field: " + pattern)
    return matches[0]


def pair(pattern, text):
    values = tuple(float(x) for x in field(pattern, text).groups())
    check(all(math.isfinite(x) for x in values), "nonfinite pair")
    return values


def parse_sample(stdout, returncode):
    text = stdout.decode("utf-8", errors="strict")
    records = [line[line.index(MARKER):] for line in text.splitlines() if MARKER in line]
    check(0 < len(records) <= 12, "missing/excess result records")
    parsed = []
    for index, raw in enumerate(records):
        m = field(r"^NATIVE axis-context stage=post-result mode=raw axes=(\w+) reversed=(true|false) sign=(\S+) sensitivity=(\S+)", raw)
        key = (m[1], m[2] == "true", float(m[3]))
        check(key == CASES[index] and float(m[4]) == 0.3, "axis/order/settings mismatch")
        axes, reversed_, sign = key
        delta = sign * (-6 if reversed_ else 6)
        pixels = (0 if axes == "vertical" else delta, 0 if axes == "horizontal" else delta)
        expected = tuple(400 - x for x in pixels)
        check(pair(r" expected=\(([^,]+), ([^)]+)\)", raw) == expected, "wrong expected origin")
        origin = pair(r" frozenOrigin=\(([^,]+), ([^)]+)\)", raw)
        matches = all(abs(x - y) < 0.01 for x, y in zip(origin, expected))
        check((field(r" matches=(true|false) ", raw)[1] == "true") == matches,
              "frozen match inconsistent with origin")
        cg = field(r" CG=\{([^}]+)\}", raw)[1]
        ns = field(r" NS=\{([^}]+)\}", raw)[1]
        check(pair(r"pointDelta=\(([^,]+),([^)]+)\)", cg) == pixels, "CG pixel mismatch")
        check(pair(r"scrollingDelta=\(([^,]+),([^)]+)\)", ns) == pixels, "NS pixel mismatch")
        check(re.match(r"type=22 timestamp=0 flags=0 targetPID=0 targetPSN=0 windowUnderPointer=0 windowCanHandle=0 continuous=1 ", cg), "CG raw metadata changed")
        check(re.match(r"type=22 timestamp=0\.0 flags=0 window=nil windowNumber=0 ", ns), "NS raw metadata changed")
        check("phase=0 momentum=0 " in ns and " precise=true " in ns, "NS precision/phase changed")
        elapsed = float(field(r" observerElapsed=(\S+) ", raw)[1])
        pumps = int(field(r" pumpCount=(\d+) ", raw)[1])
        check(math.isfinite(elapsed) and elapsed >= 0, "invalid elapsed")
        parsed.append({"axes": axes, "reversed": reversed_, "sign": sign, "pixels": pixels,
                       "expected": expected, "frozenOrigin": origin, "matches": matches,
                       "observerElapsed": elapsed, "pumpCount": pumps, "raw": raw})
    failed = [i for i, case in enumerate(parsed) if not case["matches"]]
    if returncode == 0:
        check(len(parsed) == 12 and not failed, "incomplete/failed success")
        check(text.count("PASS " + NAME + "\n") == 1 and "FAIL " not in text,
              "missing/conflicting success label")
        check(text.count("1/1 checks passed.") == 1 and "0/1 checks passed." not in text,
              "missing/conflicting success summary")
        status = "fixture-pass"
    else:
        check(returncode == 1 and failed == [len(parsed) - 1], "unexpected failure/exit shape")
        check(text.count("FAIL " + NAME + ": native axis output differs:") == 1 and "PASS " not in text,
              "missing/conflicting failure label")
        check(text.count("0/1 checks passed.") == 1 and "1/1 checks passed." not in text,
              "missing/conflicting failure summary")
        status = "behavior-failure"
    return {"status": status, "casesReached": len(parsed), "casesMissing": CASES[len(parsed):],
            "cases": parsed}


def schedule(mode):
    return [{"pair": i + 1, "order": order, "position": j + 1, "variant": v}
            for i, order in enumerate(["AB"] if mode == "local-smoke" else ["AB", "BA"] * 9)
            for j, v in enumerate(order)]


def decision(mode, samples):
    if any(s["status"] == "behavior-failure" and s["variant"] == "B" for s in samples):
        return "NOT_A_STABILITY_FIX"
    if mode != "hosted-batch" or len(samples) != 36:
        return "INCONCLUSIVE"
    a_fail = [s for s in samples if s["variant"] == "A" and s["status"] == "behavior-failure"]
    b = [s for s in samples if s["variant"] == "B"]
    if (len(a_fail) >= 2 and {s["position"] for s in a_fail} == {1, 2}
            and len(b) == 18 and all(s["status"] == "fixture-pass" and s["casesReached"] == 12 for s in b)):
        return "SUPPORTS_FIXTURE_PATH_IN_THIS_BATCH_ONLY"
    return "INCONCLUSIVE"


def capture(argv, timeout):
    with subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
            return stdout, stderr, process.returncode, False
        except subprocess.TimeoutExpired:
            # The compiler driver may have children; kill only our private process group.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
            return stdout, stderr, process.returncode, True


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("mode", choices=["local-smoke", "hosted-batch"])
    cli.add_argument("--expected-head", required=True)
    cli.add_argument("--out", required=True, type=Path)
    args = cli.parse_args()
    root = Path.cwd().resolve()
    out = args.out.resolve()
    check(out.is_relative_to(root / ".audit") or out.is_relative_to(root / ".build"), "out must be own ignored .audit/.build")
    out.mkdir(parents=True, exist_ok=False)
    start = time.monotonic()
    ledger, samples = [], []
    plan = {"baselineHead": BASE, "baselineTree": TREE, "expectedHead": args.expected_head,
            "mode": args.mode, "schedule": schedule(args.mode), "compileSecondsEach": 120,
            "sampleSecondsEach": 5, "runnerWallSeconds": 540, "hostedJobSeconds": 600,
            "retries": 0, "fixtureInvocationsPerSample": 1, "sourceHashes": HASHES,
            "compileFlags": FLAGS, "argv": sys.argv, "leverSha256": sha(Path(__file__).read_bytes()),
            "decisions": ["No reproduced A failure => INCONCLUSIVE; no change.",
                          "Any B behavior failure => NOT_A_STABILITY_FIX.",
                          "18 pairs complete, >=2 A failures spanning both positions, B18/18 all12 => fixture-path support in this batch only.",
                          "All lesser/no-data/setup results inconclusive; no performance, global root, production fix or shipping inference."]}
    write_json(out / "plan.json", plan)

    def run(label, argv, limit):
        remaining = 540 - (time.monotonic() - start)
        check(remaining > 0, "runner wall budget exhausted")
        record = {"label": label, "argv": argv, "cwd": str(root), "timeoutSeconds": min(limit, remaining),
                  "startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(), "attempt": 1}
        write_json(out / (label + ".started.json"), record)
        began = time.monotonic()
        try:
            stdout, stderr, rc, timed_out = capture(argv, record["timeoutSeconds"])
        except OSError as error:
            stdout, stderr, rc, timed_out = b"", str(error).encode(), None, False
        # Raw bytes, actual status and ordered ledger precede parsing or interpretation.
        (out / (label + ".stdout.log")).write_bytes(stdout)
        (out / (label + ".stderr.log")).write_bytes(stderr)
        record.update(returncode=rc, timedOut=timed_out, elapsed=time.monotonic() - began,
                      stdoutSha256=sha(stdout), stderrSha256=sha(stderr))
        ledger.append(record)
        write_json(out / "ledger.json", ledger)
        write_json(out / (label + ".result.json"), record)
        return stdout, rc

    def must(label, argv, limit=10):
        stdout, rc = run(label, argv, limit)
        check(rc == 0 and not ledger[-1]["timedOut"], label + " failed; inspect retained raw logs")
        return stdout

    summary = {"decision": "INCONCLUSIVE", "samples": samples, "setupError": None}
    exitcode = 2
    try:
        check(re.fullmatch(r"[0-9a-f]{40}", args.expected_head), "full explicit expected-head required")
        check(must("head", ["git", "rev-parse", "HEAD"]).decode().strip() == args.expected_head, "HEAD drift")
        actual_tree = must("tree", ["git", "rev-parse", "HEAD^{tree}"]).decode().strip()
        expected_tree = must("expected-tree", ["git", "rev-parse", args.expected_head + "^{tree}"]).decode().strip()
        check(actual_tree == expected_tree, "tree drift")
        check(must("baseline-tree", ["git", "rev-parse", BASE + "^{tree}"]).decode().strip() == TREE, "baseline missing/drift")
        must("ancestry", ["git", "merge-base", "--is-ancestor", BASE, "HEAD"])
        check(not must("status", ["git", "--no-optional-locks", "status", "--porcelain"]), "unclean worktree/index")
        changed = set(must("paths", ["git", "diff", "--name-only", BASE, "HEAD"]).decode().splitlines())
        check(changed <= PUBLIC_PATHS, "unreviewed diagnostic paths")
        for name, digest in HASHES.items():
            check(sha((root / name).read_bytes()) == digest, "source drift: " + name)
            check(sha(must("baseline-" + name, ["git", "show", BASE + ":" + name])) == digest, "baseline blob drift")
        source = (root / "pen-pan-tests.swift").read_bytes()
        variant = alternative(source)
        variant_path = out / "pen-pan-tests-optout.swift"
        variant_path.write_bytes(variant)
        (out / "variant.diff").write_text("".join(difflib.unified_diff(
            source.decode().splitlines(True), variant.decode().splitlines(True), fromfile="baseline-tests", tofile="private-optout-tests")))
        write_json(out / "sources.json", {"actualHead": args.expected_head, "actualTree": actual_tree,
                   "baselineHead": BASE, "baselineTree": TREE, "sourceHashes": HASHES,
                   "variantSha256": sha(variant), "nativeBodySha256": sha(native_body(source)),
                   "normalizedVariantBodySha256": sha(native_body(variant).replace(ALT_CTOR, CTOR)),
                   "declarations": re.findall(r'\btest\("([^"]+)"', source.decode())})
        for label, argv in [("compiler", ["xcrun", "swiftc", "--version"]),
                            ("sdk", ["xcrun", "--show-sdk-path"]), ("os", ["sw_vers"]),
                            ("arch", ["uname", "-m"]), ("python", [sys.executable, "--version"])]:
            must(label, argv)
        binaries = {}
        for v, tests in [("A", "pen-pan-tests.swift"), ("B", str(variant_path))]:
            (out / v).mkdir()
            binary = out / v / "pen-pan-tests"
            must("compile-" + v, ["xcrun", "swiftc"] + FLAGS + ["pen-pan.swift", tests, "-o", str(binary)], 120)
            binaries[v] = {"path": str(binary), "sha256": sha(binary.read_bytes())}
        write_json(out / "binaries.json", binaries)
        for item in plan["schedule"]:
            label = "sample-%02d-%d-%s" % (item["pair"], item["position"], item["variant"])
            stdout, rc = run(label, [binaries[item["variant"]]["path"], "--native-axis-probe"], 5)
            sample = dict(item, label=label, status="setup-error", casesReached=0, casesMissing=CASES)
            samples.append(sample)
            try:
                check(not ledger[-1]["timedOut"], "sample watchdog expired; inspect retained raw logs")
                sample.update(parse_sample(stdout, rc))
            finally:
                write_json(out / (label + ".parsed.json"), sample)
                write_json(out / "samples.json", samples)
        check(not must("final-status", ["git", "--no-optional-locks", "status", "--porcelain"]), "final state drift")
        check(must("final-head", ["git", "rev-parse", "HEAD"]).decode().strip() == args.expected_head, "final HEAD drift")
        check(must("final-tree", ["git", "rev-parse", "HEAD^{tree}"]).decode().strip() == expected_tree, "final tree drift")
        for name, digest in HASHES.items():
            check(sha((root / name).read_bytes()) == digest, "final source drift: " + name)
        summary["decision"] = decision(args.mode, samples)
        exitcode = int(any(s["status"] == "behavior-failure" for s in samples))
    except (ValueError, OSError, UnicodeError) as error:
        summary["setupError"] = str(error)
    finally:
        summary.update(exitcode=exitcode, elapsed=time.monotonic() - start,
                       scheduled=len(plan["schedule"]), executed=len(samples),
                       notExecuted=plan["schedule"][len(samples):])
        write_json(out / "summary.json", summary)
        print(json.dumps({k: v for k, v in summary.items() if k not in ("samples", "notExecuted")}, sort_keys=True))
    return exitcode


if __name__ == "__main__":
    sys.exit(main())
