#!/usr/bin/env python3
"""Run the complete Swift Testing inventory sequentially in bounded host processes."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


def records(path):
    with path.open(encoding="utf-8") as source:
        result = [json.loads(line) for line in source if line.strip()]
    if any(item.get("version") != 0 for item in result):
        raise ValueError("Unsupported Swift Testing event stream version")
    return result


def inventory(items):
    tests = {}
    for item in items:
        payload = item.get("payload", {})
        if item.get("kind") == "test" and payload.get("kind") == "function":
            identity = payload["id"]
            if identity in tests:
                raise ValueError(f"Duplicate test identity: {identity}")
            tests[identity] = payload
    return tests


def audit(expected, items, returncode):
    discovered = set(inventory(items))
    ended, skipped, issues = set(), set(), []
    runs_started = runs_ended = 0
    for item in items:
        if item.get("kind") != "event":
            continue
        event = item["payload"]
        kind, identity = event["kind"], event.get("testID")
        runs_started += kind == "runStarted"
        runs_ended += kind == "runEnded"
        if kind == "testEnded" and identity in expected:
            ended.add(identity)
        if kind == "testSkipped" and identity in expected:
            skipped.add(identity)
        if kind == "issueRecorded":
            issues.append(event)
    missing = expected - ended - skipped
    errors = []
    if returncode != 0:
        errors.append(f"Host exit status {returncode}")
    if runs_started != 1 or runs_ended != 1:
        errors.append("Missing or duplicate run boundary")
    if discovered != expected:
        errors.append("Discovered inventory differs from assigned batch")
    if any(not item.get("issue", {}).get("isKnown", False)
           and item.get("issue", {}).get("_severity", "error") == "error" for item in issues):
        errors.append("Unresolved error recorded in event stream")
    if missing:
        errors.append(f"{len(missing)} tests did not complete or report a skip")
    return {"errors": errors, "completed": sorted(ended), "skipped": sorted(skipped),
            "missing": sorted(missing), "issues": issues}


def selector(identity):
    # Source coordinates disambiguate events, but the runner's filter uses the name.
    name = re.sub(r"/[^/]+\.swift:\d+:\d+$", "", identity)
    return re.escape(name)


def run(command, output):
    with output.open("w", encoding="utf-8") as log:
        return subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=False).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=2)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not 1 <= args.batch_size <= 100:
        parser.error("batch-size must be between 1 and 100")
    forwarded = args.arguments
    if forwarded[:1] == ["--"]:
        forwarded = forwarded[1:]
    # Listing is a separate operation, not an empty successful test run.
    reserved = {"--list-tests", "--event-stream-output-path", "--event-stream-version", "--xunit-output",
                "--filter", "--skip", "--repetitions", "--repeat-until"}
    if any(value.split("=", 1)[0] in reserved for value in forwarded):
        parser.error("filter/list/event-stream/repetition options require the single-host runner")
    args.output.mkdir(parents=True, exist_ok=False)
    base = [args.host, "--test-bundle-path", args.bundle]
    discovery = args.output / "inventory.jsonl"
    code = run(base + forwarded + ["--list-tests", "--event-stream-output-path", str(discovery)],
               args.output / "discovery.log")
    if code:
        raise RuntimeError(f"Discovery failed ({code}); see {args.output / 'discovery.log'}")
    tests = inventory(records(discovery))
    if not tests:
        raise RuntimeError("No tests selected; refusing an empty successful run")
    identities = sorted(tests)
    execution_args = forwarded
    batches = [identities[i:i + args.batch_size] for i in range(0, len(identities), args.batch_size)]
    manifest = {"selected": identities, "batchSize": args.batch_size, "batches": []}
    manifest_path = args.output / "result.json"
    print(f"Discovered {len(identities)} tests; {len(batches)} sequential batches. Evidence: {args.output}", flush=True)
    failed = False
    for number, assigned in enumerate(batches, 1):
        event_path = args.output / f"batch-{number:03}.jsonl"
        output = args.output / f"batch-{number:03}.log"
        pattern = "^(?:" + "|".join(selector(item) for item in assigned) + r")(?:/[^/]+\.swift:\d+:\d+)?$"
        code = run(base + execution_args + ["--no-parallel", "--filter", pattern,
                   "--event-stream-output-path", str(event_path)], output)
        try:
            result = audit(set(assigned), records(event_path), code)
        except (OSError, ValueError, KeyError) as error:
            result = {"errors": [str(error)], "completed": [], "skipped": [], "missing": assigned}
        failed |= bool(result["errors"])
        manifest["batches"].append({"number": number, "assigned": assigned, "exitCode": code, **result})
        manifest["status"] = "running"
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"Batch {number}/{len(batches)}: {len(result['completed'])} completed, "
              f"{len(result['skipped'])} skipped, {len(result['errors'])} errors; {output}", flush=True)
    manifest["status"] = "failed" if failed else "passed"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Full selected inventory: {manifest['status']}. {manifest_path}", flush=True)
    return int(failed)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        print(f"Test batch runner failed: {error}", file=sys.stderr)
        sys.exit(2)
