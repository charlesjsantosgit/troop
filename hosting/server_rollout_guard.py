#!/usr/bin/env python3
"""Bound a one-authority Fly rollout without deploying or replacing any volume.

Run prepare AFTER building/pushing the uniquely tagged candidate image; run verify
after deploying that image. The only remote mutation here schedules one snapshot.
No token, environment, complete Machine config, or persistent file is written to
evidence. This is a persisted-filesystem backup, not a live-memory/checkpoint save.

Verified flyctl contracts: machine/volumes/snapshot list return JSON arrays;
snapshot create may print text even with --json. Snapshot status advances through
waiting/running to created. Source: superfly/flyctl internal/command/volumes/
snapshots/{create,list}.go and superfly/fly-go {machine,volume}_types.go.
https://fly.io/docs/volumes/snapshots/
"""

import argparse
import copy
import datetime as dt
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time


class GuardError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise GuardError(message)


def stamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def safe(value, pattern, label):
    require(isinstance(value, str) and re.fullmatch(pattern, value),
            "Missing or invalid " + label)
    return value


def rows(value, label):
    require(isinstance(value, list) and len(value) <= 10000
            and all(isinstance(row, dict) for row in value),
            "Unexpected JSON schema for " + label)
    return value


def identity(machines, volumes):
    # Fail closed on stopped spares as well: they could become a second authority.
    live = [row for row in rows(machines, "machines")
            if row.get("state") != "destroyed"]
    require(len(live) == 1, "Expected exactly one existing application Machine")
    machine = live[0]
    require(machine.get("state") == "started", "Sole Machine is not started")
    require(machine.get("host_status", "ok") == "ok",
            "Machine host is unavailable or its config is incomplete")
    mid = safe(machine.get("id"), r"[a-zA-Z0-9_-]{6,80}", "Machine ID")
    config = machine.get("config")
    require(isinstance(config, dict), "Machine config is unavailable")
    services = config.get("services", [])
    require(isinstance(services, list) and any(
        isinstance(service, dict) and service.get("protocol") == "udp"
        and service.get("internal_port") == 30623 for service in services),
        "Sole Machine does not expose the expected UDP game service")
    mounts = rows(config.get("mounts", []), "Machine mounts")
    require(len(mounts) == 1 and mounts[0].get("path") == "/data",
            "Expected exactly one persistent mount at /data")
    vid = safe(mounts[0].get("volume"), r"vol_[a-zA-Z0-9]{6,80}", "volume ID")
    matching = [row for row in rows(volumes, "volumes") if row.get("id") == vid]
    require(len(matching) == 1, "Original mounted volume is absent or ambiguous")
    volume = matching[0]
    require(volume.get("state") == "created", "Mounted volume is not ready")
    require(volume.get("attached_machine_id") == mid,
            "Volume attachment does not match the game Machine")
    require(volume.get("name") == "troop_society_state",
            "Unexpected persistent volume name")
    require(isinstance(volume.get("size_gb"), int) and volume["size_gb"] > 0,
            "Missing volume size for restoration")
    region = safe(machine.get("region"), r"[a-z0-9]{3,12}", "Machine region")
    require(volume.get("region") == region, "Machine/volume regions differ")
    config_image = safe(config.get("image"), r"[a-zA-Z0-9][a-zA-Z0-9._/@:+-]{1,511}",
                        "configured image")
    ref = machine.get("image_ref")
    require(isinstance(ref, dict), "Resolved Machine image reference is absent")
    registry = safe(ref.get("registry"), r"[a-zA-Z0-9][a-zA-Z0-9.:-]{0,200}",
                    "image registry")
    repository = safe(ref.get("repository"), r"[a-zA-Z0-9][a-zA-Z0-9._/-]{0,200}",
                      "image repository")
    digest = safe(ref.get("digest"), r"sha256:[a-fA-F0-9]{64}", "immutable image digest")
    tag = ref.get("tag", "")
    require(isinstance(tag, str) and (not tag or re.fullmatch(r"[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}", tag)),
            "Invalid resolved image tag")
    return {
        "machine_id": mid, "machine_state": "started", "region": region,
        "config_image": config_image,
        "image": {"registry": registry, "repository": repository,
                  "tag": tag, "digest": digest},
        "immutable_image": registry + "/" + repository + "@" + digest,
        "volume": {"id": vid, "name": volume["name"], "path": "/data",
                   "size_gb": volume["size_gb"], "region": region,
                   "attached_machine_id": mid},
    }


def same_authority(before, after):
    require(before["machine_id"] == after["machine_id"], "Rollout changed the Machine ID")
    require(before["volume"]["id"] == after["volume"]["id"],
            "Rollout changed the persistent volume ID")
    require(before["region"] == after["region"], "Rollout changed the Machine region")


def candidate_matches(current, app, candidate):
    prefix = "registry.fly.io/" + app + ":"
    require(candidate.startswith(prefix), "Candidate image must be tagged in this Fly app registry")
    tag = safe(candidate[len(prefix):], r"[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}", "candidate image tag")
    require(tag not in ("latest", "main", "production", "stable"),
            "Candidate image must have a unique rollout tag")
    if current is None:
        return
    ref = current["image"]
    require(ref["registry"] == "registry.fly.io" and ref["repository"] == app,
            "Running image is from a different registry or application")
    # Fly may canonicalize config.image to a digest. Accept its resolved tag then,
    # but never accept an unrelated config tag whose old image_ref happens to match.
    configured = current["config_image"]
    allowed = (candidate, candidate + "@" + ref["digest"], current["immutable_image"])
    require(configured in allowed, "Running configured image does not match candidate")
    require(ref["tag"] == tag or (not ref["tag"] and configured.startswith(candidate)),
            "Running resolved image tag does not match candidate")


def fresh_snapshot(values, old_ids, requested_at):
    eligible = []
    for row in rows(values, "snapshots"):
        sid = row.get("id", "")
        if not sid or sid in old_ids or row.get("status") != "created":
            continue
        safe(sid, r"vs_[a-zA-Z0-9]{6,100}", "snapshot ID")
        try:
            created = dt.datetime.fromisoformat(row.get("created_at", "").replace("Z", "+00:00"))
        except (AttributeError, TypeError, ValueError):
            continue
        if created.tzinfo is None or created < requested_at - dt.timedelta(seconds=5):
            continue
        eligible.append((created, {key: row[key] for key in (
            "id", "status", "created_at", "size", "volume_size", "retention_days") if key in row}))
    return max(eligible, key=lambda item: item[0])[1] if eligible else None


class Fly:
    def __init__(self, app, binary="flyctl", command_timeout=45):
        self.app, self.binary, self.command_timeout = app, binary, command_timeout

    def run(self, arguments, json_output=True, timeout=None):
        command = [self.binary, *arguments, "--app", self.app]
        if json_output:
            command.append("--json")
        try:
            result = subprocess.run(command, capture_output=True, text=True,
                                    timeout=min(self.command_timeout, timeout or self.command_timeout),
                                    check=False)
        except subprocess.TimeoutExpired:
            raise GuardError("flyctl command timed out; no raw output retained") from None
        except OSError:
            raise GuardError("Could not execute flyctl") from None
        # flyctl diagnostics may contain configuration values: never relay them.
        require(result.returncode == 0,
                "flyctl " + " ".join(arguments[:2]) + " failed (exit " + str(result.returncode) + "); raw output withheld")
        require(len(result.stdout) <= 8 * 1024 * 1024, "flyctl JSON output exceeds guard budget")
        if not json_output:
            return None
        try:
            return json.loads(result.stdout)
        except (ValueError, TypeError):
            raise GuardError("flyctl returned invalid JSON; no raw output retained") from None

    def current(self):
        return identity(self.run(["machine", "list"]), self.run(["volumes", "list"]))


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as stream:
        temp = Path(stream.name)
        os.chmod(temp, 0o600)
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
    temp.replace(path)


def rollback_pointers(app, before, snapshot):
    print("Retained Machine " + before["machine_id"] + "; /data volume " + before["volume"]["id"])
    print("Previous immutable image: " + before["immutable_image"])
    print("Confirmed predeploy snapshot: " + snapshot["id"])
    print("Image rollback command (manual; review state compatibility before running):")
    print(shlex.join(["flyctl", "machine", "update", before["machine_id"], "--app", app,
                      "--image", before["immutable_image"], "--yes", "--wait-timeout", "300"]))
    print("Snapshot restoration creates a NEW volume; preserve the current volume and any later player progress.")


def prepare(args, fly):
    path = args.evidence_dir / "predeploy.json"
    require(not path.exists(), "predeploy.json already exists; use a fresh evidence directory, do not overwrite rollback evidence")
    candidate_matches(None, args.app, args.candidate_image)
    before = fly.current()
    old = rows(fly.run(["volumes", "snapshots", "list", before["volume"]["id"]]), "snapshots")
    old_ids = {row.get("id") for row in old if isinstance(row.get("id"), str) and row["id"]}
    requested = dt.datetime.now(dt.timezone.utc)
    report = {"schema": 1, "phase": "snapshot_pending", "app": args.app,
              "candidate_image": args.candidate_image, "captured_at": stamp(),
              "snapshot_requested_at": requested.isoformat(), "previous": before}
    # Keep the prior image/mount pointers even if snapshot creation or polling fails.
    write_json(path, report)
    # This command's --json is ignored by some flyctl versions; never parse its text.
    fly.run(["volumes", "snapshots", "create", before["volume"]["id"]], json_output=False)
    deadline = time.monotonic() + args.snapshot_timeout
    snapshot = None
    while time.monotonic() < deadline:
        values = fly.run(["volumes", "snapshots", "list", before["volume"]["id"]],
                         timeout=max(1, deadline - time.monotonic()))
        snapshot = fresh_snapshot(values, old_ids, requested)
        if snapshot:
            break
        time.sleep(min(args.poll_interval, max(0, deadline - time.monotonic())))
    require(snapshot is not None, "A fresh completed volume snapshot was not confirmed before timeout; DO NOT DEPLOY")
    current = fly.current()
    same_authority(before, current)
    require(current["immutable_image"] == before["immutable_image"],
            "Server image changed while snapshot was being taken; DO NOT DEPLOY")
    report.update(phase="prepared", snapshot=snapshot, prepared_at=stamp())
    write_json(path, report)
    rollback_pointers(args.app, before, snapshot)
    print("SERVER_ROLLOUT_GUARD_PREPARED")


def verify(args, fly):
    try:
        report = json.loads((args.evidence_dir / "predeploy.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise GuardError("Cannot read valid predeploy evidence") from None
    require(report.get("schema") == 1 and report.get("phase") == "prepared"
            and report.get("app") == args.app, "Predeploy evidence is not prepared for this application")
    current = fly.current()
    same_authority(report["previous"], current)
    candidate_matches(current, args.app, report["candidate_image"])
    snapshots = rows(fly.run(["volumes", "snapshots", "list", current["volume"]["id"]]), "snapshots")
    require(any(row.get("id") == report["snapshot"]["id"] and row.get("status") == "created"
                for row in snapshots), "Predeploy snapshot is no longer available")
    write_json(args.evidence_dir / "postdeploy.json", {
        "schema": 1, "phase": "verified", "app": args.app, "verified_at": stamp(),
        "candidate_image": report["candidate_image"], "current": current,
        "predeploy_snapshot_id": report["snapshot"]["id"],
        "scope": "Machine, persistent mount, completed backup and candidate image identity; gameplay/network smoke is separate",
    })
    rollback_pointers(args.app, report["previous"], report["snapshot"])
    print("SERVER_ROLLOUT_GUARD_VERIFIED")


def self_test():
    digest = "sha256:" + "a" * 64
    machine = {"id": "abc123def456", "state": "started", "region": "sjc", "host_status": "ok",
               "config": {"image": "registry.fly.io/test-app:city-123", "env": {"SECRET": "MUST_NOT_LEAK"},
                          "mounts": [{"path": "/data", "volume": "vol_abcdef123"}],
                          "services": [{"protocol": "udp", "internal_port": 30623}]},
               "image_ref": {"registry": "registry.fly.io", "repository": "test-app", "tag": "city-123", "digest": digest}}
    volume = {"id": "vol_abcdef123", "name": "troop_society_state", "state": "created", "size_gb": 1,
              "region": "sjc", "attached_machine_id": "abc123def456"}
    current = identity([machine], [volume])
    require("MUST_NOT_LEAK" not in json.dumps(current), "Sanitization regression")
    candidate_matches(current, "test-app", "registry.fly.io/test-app:city-123")
    rejected = 0
    cases = []
    for field, value in (("state", "stopped"), ("host_status", "unreachable")):
        modified = copy.deepcopy(machine); modified[field] = value
        cases.append(lambda modified=modified: identity([modified], [volume]))
    cases += [lambda: identity([machine, machine], [volume]),
              lambda: identity([machine], []),
              lambda: identity([machine], [dict(volume, attached_machine_id="wrong")]),
              lambda: candidate_matches(current, "test-app", "registry.fly.io/test-app:wrong"),
              lambda: candidate_matches(None, "test-app", "registry.fly.io/test-app:latest"),
              lambda: same_authority(current, dict(current, machine_id="different"))]
    for case in cases:
        try:
            case()
        except GuardError:
            rejected += 1
    require(rejected == len(cases), "Guard failed to reject an unsafe fixture")
    now = dt.datetime.now(dt.timezone.utc)
    ready = {"id": "vs_abcdef123", "status": "created", "created_at": now.isoformat(), "size": 12}
    require(fresh_snapshot([ready], set(), now) is not None, "Fresh snapshot was rejected")
    require(fresh_snapshot([ready], {ready["id"]}, now) is None, "Old snapshot was accepted")
    require(fresh_snapshot([dict(ready, status="running")], set(), now) is None, "Pending snapshot was accepted")
    require(fresh_snapshot([dict(ready, created_at=(now - dt.timedelta(hours=1)).isoformat())], set(), now) is None,
            "Stale snapshot was accepted")
    print("SERVER_ROLLOUT_GUARD_SELF_TEST_PASS (14 checks; no remote calls)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "verify", "self-test"))
    parser.add_argument("--app", default=os.environ.get("FLY_APP_NAME", ""))
    parser.add_argument("--candidate-image")
    parser.add_argument("--evidence", "--evidence-dir", dest="evidence_dir", type=Path,
                        default=Path("artifacts/server-deployment"))
    parser.add_argument("--flyctl", default="flyctl")
    parser.add_argument("--snapshot-timeout", type=int, default=180)
    parser.add_argument("--poll-interval", type=int, default=5)
    args = parser.parse_args()
    try:
        if args.mode == "self-test":
            self_test()
            return 0
        safe(args.app, r"[a-zA-Z0-9][a-zA-Z0-9-]{0,62}", "application name")
        require(10 <= args.snapshot_timeout <= 600 and 1 <= args.poll_interval <= 15,
                "Snapshot timeout must be 10..600 seconds and poll interval 1..15 seconds")
        if args.mode == "prepare":
            require(isinstance(args.candidate_image, str), "prepare requires --candidate-image")
            prepare(args, Fly(args.app, args.flyctl))
        else:
            verify(args, Fly(args.app, args.flyctl))
        return 0
    except GuardError as exc:
        message = str(exc)
        print("SERVER_ROLLOUT_GUARD_FAILED: " + message, file=sys.stderr)
        if args.mode != "self-test":
            write_json(args.evidence_dir / (args.mode + "-failure.json"),
                       {"schema": 1, "phase": args.mode, "failed_at": stamp(), "error": message})
        return 1


if __name__ == "__main__":
    sys.exit(main())
