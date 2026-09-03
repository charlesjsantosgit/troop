#!/usr/bin/env python3
"""Offline, fail-closed inspection/extraction of Godot 4.7 Metal shader caches.

The layout is pinned to godotengine/godot commit 5b4e0cb0f:
  servers/rendering/renderer_rd/shader_rd.cpp (GDSC v4)
  servers/rendering/rendering_shader_container.{h,cpp} (GRSC v2)
  drivers/metal/{rendering_shader_container_metal,metal_device_profile}.h

Godot's baker writes Metal container format v2, including a 64-byte native
ReflectionData and 36-byte Metal HeaderData on the supported 64-bit Mac ABI.
Invalid containers omit per-uniform/stage extras that the engine's reader still
expects. Never rewrite those containers: optionally omit their WHOLE cache file
so the engine sees an ordinary cache miss. All other malformed input is fatal.

This verifies framing, source hashes and an MTLB library at each declared library
offset, NOT Apple's opaque library internals or actual GPU/OS compatibility.
Engine provenance is supplied by a separately verified baker invocation; a cache
path's engine-dependent hash cannot be reversed into proof of its engine version.
The manifest pins that declared provenance, rendering settings and every byte.
No Godot process, GPU, installed app, user data, or network is accessed here.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import hashlib
import json
from pathlib import Path
import re
import struct
import sys


ENGINE_VERSION = "4.7.stable.official.5b4e0cb0f"
MANIFEST_NAME = "manifest.json"
MAX_GROUP_BYTES = 64 * 1024 * 1024
MAX_STAGE_BYTES = 32 * 1024 * 1024
MAX_EXPANDED_BYTES = 128 * 1024 * 1024
MAX_TREE_BYTES = 512 * 1024 * 1024
MAX_FILES = 1024
PATH_PATTERN = re.compile(r"[A-Za-z][A-Za-z0-9_]{0,127}/[0-9a-f]{64}/[0-9a-f]{40}\.metal\.cache")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


class CacheError(ValueError):
    """Malformed, incompatible, or insufficiently baked input."""


class SkippedVariantError(CacheError):
    """A whole group must be omitted because the baker skipped a variant."""


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.offset = 0

    def take(self, size: int) -> bytes:
        if size < 0 or size > len(self.data) - self.offset:
            raise CacheError(f"truncated data at byte {self.offset}, requested {size}")
        result = self.data[self.offset:self.offset + size]
        self.offset += size
        return result

    def unpack(self, fmt: str) -> tuple:
        return struct.unpack(fmt, self.take(struct.calcsize(fmt)))

    def u32(self) -> int:
        return self.unpack("<I")[0]

    def align(self) -> None:
        self.take((-self.offset) % 4)

    def finish(self) -> None:
        if self.offset != len(self.data):
            raise CacheError(f"unexpected trailing bytes at {self.offset}")


def bounded(value: int, maximum: int, label: str, minimum: int = 0) -> int:
    if not minimum <= value <= maximum:
        raise CacheError(f"{label} outside bounds: {value}")
    return value


_zstd = None


def zstd_library():
    """Load the installed decoder only; never download or execute a command."""
    global _zstd
    if _zstd is not None:
        return _zstd
    candidates = [ctypes.util.find_library("zstd"),
                  "/opt/homebrew/lib/libzstd.dylib", "/usr/local/lib/libzstd.dylib"]
    for candidate in candidates:
        if not candidate:
            continue
        try:
            library = ctypes.CDLL(candidate)
            for name, result, args in (
                ("ZSTD_getFrameContentSize", ctypes.c_ulonglong, [ctypes.c_void_p, ctypes.c_size_t]),
                ("ZSTD_findFrameCompressedSize", ctypes.c_size_t, [ctypes.c_void_p, ctypes.c_size_t]),
                ("ZSTD_decompress", ctypes.c_size_t,
                 [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]),
                ("ZSTD_isError", ctypes.c_uint, [ctypes.c_size_t]),
            ):
                function = getattr(library, name)
                function.restype = result
                function.argtypes = args
            _zstd = library
            return library
        except (OSError, AttributeError):
            continue
    raise CacheError("Zstd decoder unavailable; install libzstd before verifying baked caches")


def decompress_stage(data: bytes, flags: int, expected: int) -> bytes:
    bounded(expected, MAX_STAGE_BYTES, "expanded stage bytes", 1)
    if flags == 0:
        if len(data) != expected:
            raise CacheError("uncompressed stage length mismatch")
        return data
    if flags != 1:
        raise CacheError(f"unsupported compression flags: {flags}")
    library = zstd_library()
    source = ctypes.create_string_buffer(data)
    if library.ZSTD_getFrameContentSize(source, len(data)) != expected:
        raise CacheError("Zstd content size missing or mismatched")
    frame_size = library.ZSTD_findFrameCompressedSize(source, len(data))
    if library.ZSTD_isError(frame_size) or frame_size != len(data):
        raise CacheError("malformed, concatenated, or trailing Zstd frame")
    destination = ctypes.create_string_buffer(expected)
    size = library.ZSTD_decompress(destination, expected, source, len(data))
    if library.ZSTD_isError(size) or size != expected:
        raise CacheError("Zstd decompression failed or length mismatched")
    return destination.raw


def inspect_variant(data: bytes, *, require_libraries: bool = True,
                    expanded_budget: list[int] | None = None) -> dict:
    reader = Reader(data)
    magic, version, format_id, format_version, shader_count = reader.unpack("<5I")
    if (magic, version, format_id, format_version) != (0x43535247, 2, 0x42424242, 2):
        raise CacheError("expected GRSC v2 Metal format v2")
    reflection = reader.unpack("<Q13I4x")  # sizeof(ReflectionData) == 64.
    spec_count, pipeline = reflection[2:4]
    set_count, stage_count, name_size = reflection[9], reflection[12], reflection[13]
    metal = reader.unpack("<4I2B2x4I")  # sizeof(HeaderData) == 36.
    platform, gpu, profile_os, profile_msl, argument_buffers, simd, msl, minimum_os, flags, _ = metal
    # Test before consuming the deliberately missing invalid-container extras.
    if flags == 0xFFFFFFFF:
        raise SkippedVariantError("baker marked Metal variant invalid (0xffffffff)")
    bounded(shader_count, 2, "shader count", 1)
    bounded(set_count, 64, "uniform set count")
    bounded(spec_count, 65536, "specialization count")
    bounded(name_size, 1024, "shader name bytes", 1)
    if stage_count != shader_count or pipeline not in (0, 1):
        raise CacheError("inconsistent shader stages or unsupported pipeline")
    if platform != 0 or gpu != 1007 or argument_buffers not in (0, 1) or simd not in (0, 1):
        raise CacheError("expected a portable macOS/Apple7 baker profile")
    if flags & ~7 or profile_os == 0xFFFFFFFF or profile_msl == 0 or msl == 0xFFFFFFFF:
        raise CacheError("invalid Metal profile/version/flags")
    expected_profile_msl = (40000 if profile_os >= 260000 else 30200 if profile_os >= 150000
                            else 30100 if profile_os >= 140000 else 30000 if profile_os >= 130000
                            else 20400 if profile_os >= 120000 else 20300)
    if profile_os < 110000 or profile_msl != expected_profile_msl or msl != expected_profile_msl:
        raise CacheError("Metal language version differs from the pinned minimum-OS profile")
    try:
        raw_name = reader.take(name_size)
        if b"\0" in raw_name:
            raise CacheError("shader name must not contain NUL")
        name = raw_name.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CacheError("invalid shader name UTF-8") from exc
    reader.align()
    uniform_total = 0
    for _ in range(set_count):
        count = bounded(reader.u32(), 65536, "uniform count")
        uniform_total += count
        bounded(uniform_total, 65536, "total uniforms")
        reader.take(count * (20 + 60))  # ReflectionBindingData + Metal UniformData.
    reader.take(spec_count * 16)
    stage_ids = reader.unpack("<" + "I" * stage_count)
    if len(set(stage_ids)) != stage_count or any(stage not in (0, 1, 4) for stage in stage_ids):
        raise CacheError("invalid or duplicate stage IDs")
    if (pipeline == 1 and stage_ids != (4,)) or (pipeline == 0 and 4 in stage_ids):
        raise CacheError("stage IDs disagree with pipeline")
    stages = []
    budget = expanded_budget if expanded_budget is not None else [0]
    for expected_stage in stage_ids:
        stage, compressed_size, compression_flags, expanded_size = reader.unpack("<4I")
        if stage != expected_stage:
            raise CacheError("stage header disagrees with reflection")
        bounded(compressed_size, MAX_STAGE_BYTES, "compressed stage bytes", 1)
        bounded(expanded_size, MAX_STAGE_BYTES, "expanded stage bytes", 1)
        budget[0] += expanded_size
        bounded(budget[0], MAX_EXPANDED_BYTES, "group expanded bytes")
        compressed = reader.take(compressed_size)
        reader.align()
        _, invariant, fast_math, source_hash, source_size, library_size = reader.unpack("<3I32s2I")
        if invariant not in (0, 1) or fast_math not in (0, 1):
            raise CacheError("invalid stage booleans")
        if not source_size or source_size + library_size != expanded_size:
            raise CacheError("declared source/library sizes disagree with stage payload")
        if require_libraries and (library_size < 4 or minimum_os == 0xFFFFFFFF):
            raise CacheError("missing baked Metal library (source-only fallback is not acceptable)")
        payload = decompress_stage(compressed, compression_flags, expanded_size)
        source = payload[:source_size]
        if hashlib.sha256(source).digest() != source_hash:
            raise CacheError("Metal source SHA-256 mismatch")
        if library_size and payload[source_size:source_size + 4] != b"MTLB":
            raise CacheError("declared library does not begin with MTLB")
        stages.append({"stage": stage, "source_bytes": source_size,
                       "library_bytes": library_size, "source_sha256": source_hash.hex()})
    reader.finish()
    return {"shader": name, "gpu": gpu, "profile_min_os": profile_os,
            "profile_msl": profile_msl, "msl": msl, "library_min_os": minimum_os,
            "stages": stages}


def inspect_cache(data: bytes, *, require_libraries: bool = True) -> dict:
    bounded(len(data), MAX_GROUP_BYTES, "cache bytes", 16)
    reader = Reader(data)
    if reader.take(4) != b"GDSC" or reader.u32() != 4:
        raise CacheError("expected GDSC v4 cache")
    count = bounded(reader.u32(), 4096, "variant count", 1)
    variants = []
    budget = [0]
    for index in range(count):
        size = bounded(reader.u32(), MAX_GROUP_BYTES, "variant bytes")
        if size == 0:
            # Baker writes empty placeholders for disabled variants (e.g. XR).
            # ShaderRD::_load_from_cache skips disabled ones, or returns an
            # ordinary cache miss if such a variant is enabled on the client.
            # This is distinct from the malformed 0xffffffff Metal container.
            variants.append(None)
            continue
        try:
            variants.append(inspect_variant(reader.take(size), require_libraries=require_libraries,
                                            expanded_budget=budget))
        except CacheError as exc:
            raise type(exc)(f"variant {index}: {exc}") from exc
    reader.finish()
    if len({variant["shader"] for variant in variants if variant is not None}) != 1:
        raise CacheError("cache group is empty or mixes shader names")
    return {"variants": variants, "expanded_bytes": budget[0]}


def cache_files(root: Path) -> list[Path]:
    if root.is_symlink() or not root.is_dir():
        raise CacheError("cache root must be a real directory")
    files = []
    total = 0
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise CacheError(f"symlink is not allowed: {path}")
        if path.is_file():
            relative = path.relative_to(root).as_posix()
            if not PATH_PATTERN.fullmatch(relative):
                raise CacheError(f"unexpected cache path: {relative}")
            total += bounded(path.stat().st_size, MAX_GROUP_BYTES, "cache file bytes", 16)
            bounded(total, MAX_TREE_BYTES, "cache tree bytes")
            files.append(path)
            bounded(len(files), MAX_FILES, "cache file count", 1)
    if not files:
        raise CacheError("no cache files found")
    return files


def check_provenance(engine_version: str, settings_sha256: str) -> None:
    if engine_version != ENGINE_VERSION:
        raise CacheError(f"layout/provenance is pinned to {ENGINE_VERSION}")
    if not SHA256_PATTERN.fullmatch(settings_sha256):
        raise CacheError("settings SHA-256 must be 64 lowercase hexadecimal characters")


def os_version_number(version: str) -> int:
    if not re.fullmatch(r"[1-9][0-9]?\.[0-9]{1,2}", version):
        raise CacheError("target minimum OS must be major.minor")
    major, minor = map(int, version.split("."))
    return major * 10000 + minor * 100


def check_target(report: dict, target_min_os: str) -> None:
    target = os_version_number(target_min_os)
    if any(v["profile_min_os"] != target or v["library_min_os"] != target
           for v in report["variants"] if v is not None):
        raise CacheError("cache profile/library minimum OS differs from manifest target")


def extract_tree(source: Path, destination: Path, *, engine_version: str,
                 settings_sha256: str, target_min_os: str, omit_invalid: bool = False) -> dict:
    """Copy only fully validated groups to a NEW directory; never modify input."""
    check_provenance(engine_version, settings_sha256)
    os_version_number(target_min_os)
    if destination.exists() or destination.is_symlink():
        raise CacheError("destination must not already exist")
    accepted = []
    omitted = []
    for path in cache_files(source):
        data = path.read_bytes()
        relative = path.relative_to(source).as_posix()
        try:
            report = inspect_cache(data)
        except SkippedVariantError as exc:
            if not omit_invalid:
                raise
            omitted.append({"path": relative, "reason": str(exc),
                            "sha256": hashlib.sha256(data).hexdigest()})
            continue
        check_target(report, target_min_os)
        if any(variant["shader"] != relative.split("/")[0]
               for variant in report["variants"] if variant is not None):
            raise CacheError(f"shader name/path mismatch: {relative}")
        accepted.append((relative, data, report))
    if not accepted:
        raise CacheError("no fully baked valid groups remain")
    # Validate all inputs before creating any output. PCK/platform injection is
    # deliberately a separate step and must use these exact relative paths.
    destination.mkdir(parents=True, exist_ok=False)
    records = []
    for relative, data, report in accepted:
        output = destination / "files" / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(data)
        records.append({"path": relative, "size": len(data),
                        "sha256": hashlib.sha256(data).hexdigest()})
    manifest = {"schema": 1, "engine_version": engine_version,
                "settings_sha256": settings_sha256, "target_min_os": target_min_os,
                "files": records, "omitted": omitted}
    (destination / MANIFEST_NAME).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def verify_tree(root: Path, *, engine_version: str, settings_sha256: str,
                target_min_os: str) -> dict:
    check_provenance(engine_version, settings_sha256)
    os_version_number(target_min_os)
    if root.is_symlink() or not root.is_dir() or {p.name for p in root.iterdir()} != {"files", MANIFEST_NAME}:
        raise CacheError("artifact root must contain only files/ and manifest.json")
    manifest_path = root / MANIFEST_NAME
    if manifest_path.is_symlink() or manifest_path.stat().st_size > 16 * 1024 * 1024:
        raise CacheError("unsafe or oversized manifest")
    manifest = json.loads(manifest_path.read_text())
    if not isinstance(manifest, dict) or (
            manifest.get("schema"), manifest.get("engine_version"), manifest.get("settings_sha256"),
            manifest.get("target_min_os")) != (1, engine_version, settings_sha256, target_min_os):
        raise CacheError("manifest engine/settings/schema mismatch")
    records = manifest.get("files")
    if not isinstance(records, list) or not records or len(records) > MAX_FILES:
        raise CacheError("invalid manifest file inventory")
    indexed = {}
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            raise CacheError("invalid manifest record")
        relative = record["path"]
        if not PATH_PATTERN.fullmatch(relative) or relative in indexed:
            raise CacheError("unsafe or duplicate manifest path")
        indexed[relative] = record
    if list(indexed) != sorted(indexed):
        raise CacheError("manifest file inventory is not sorted")
    file_root = root / "files"
    actual = {path.relative_to(file_root).as_posix(): path for path in cache_files(file_root)}
    if set(actual) != set(indexed):
        raise CacheError("manifest and filesystem inventories differ")
    for relative, path in actual.items():
        data = path.read_bytes()
        report = inspect_cache(data)
        check_target(report, target_min_os)
        record = indexed[relative]
        expected = {"path": relative, "size": len(data),
                    "sha256": hashlib.sha256(data).hexdigest()}
        if record != expected or any(v["shader"] != relative.split("/")[0]
                                     for v in report["variants"] if v is not None):
            raise CacheError(f"manifest bytes/metadata mismatch: {relative}")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inspect = commands.add_parser("inspect", help="inspect a single GDSC .metal.cache file")
    inspect.add_argument("source", type=Path)
    inspect.add_argument("--allow-source-only", action="store_true", help="diagnostics only, never extraction")
    for command in ("extract", "verify"):
        subparser = commands.add_parser(command)
        subparser.add_argument("source", type=Path)
        subparser.add_argument("--engine-version", required=True)
        subparser.add_argument("--settings-sha256", required=True)
        subparser.add_argument("--target-min-os", required=True)
        if command == "extract":
            subparser.add_argument("destination", type=Path)
            subparser.add_argument("--omit-invalid", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "inspect":
            if args.source.is_symlink():
                raise CacheError("symlink input is not allowed")
            bounded(args.source.stat().st_size, MAX_GROUP_BYTES, "cache bytes", 16)
            result = inspect_cache(args.source.read_bytes(), require_libraries=not args.allow_source_only)
        elif args.command == "extract":
            result = extract_tree(args.source, args.destination, engine_version=args.engine_version,
                                  settings_sha256=args.settings_sha256, target_min_os=args.target_min_os,
                                  omit_invalid=args.omit_invalid)
        else:
            result = verify_tree(args.source, engine_version=args.engine_version,
                                 settings_sha256=args.settings_sha256, target_min_os=args.target_min_os)
        print(json.dumps(result, indent=2, sort_keys=True))
    except (CacheError, OSError, ValueError) as exc:
        print(f"METAL-CACHE FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
