"""Offline cache framing/provenance regression; no Godot, Metal or network.

Synthetic MTLB payloads test framing, not Apple's opaque native library format.
Real baker acceptance additionally requires a native cold-start measurement.
"""

import ctypes
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "packaging" / "metal_shader_cache.py"
SPEC = importlib.util.spec_from_file_location("metal_shader_cache", MODULE_PATH)
cache = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cache)

SHADER = "FixtureShaderRD"
RELATIVE = SHADER + "/" + "a" * 64 + "/" + "b" * 40 + ".metal.cache"
PROVENANCE = dict(engine_version=cache.ENGINE_VERSION, settings_sha256="c" * 64, target_min_os="11.0")


def compress(data):
    library = cache.zstd_library()
    library.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
    library.ZSTD_compressBound.restype = ctypes.c_size_t
    library.ZSTD_compress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                                     ctypes.c_size_t, ctypes.c_int]
    library.ZSTD_compress.restype = ctypes.c_size_t
    capacity = library.ZSTD_compressBound(len(data))
    output = ctypes.create_string_buffer(capacity)
    source = ctypes.create_string_buffer(data)
    size = library.ZSTD_compress(output, capacity, source, len(data), 3)
    assert not library.ZSTD_isError(size)
    return output.raw[:size]


def variant(*, name=SHADER, source=b"kernel void main() {}", library=b"MTLB" + b"fixture" * 8,
            invalid=False, compressed=False, gpu=1007, minimum_os=110000,
            uniform_count=0, specialization_count=0):
    data = bytearray(struct.pack("<5I", 0x43535247, 2, 0x42424242, 2, 1))
    data += struct.pack("<Q13I4x", 0, 0, specialization_count, 1, 0, 0, 8, 8, 1,
                        int(uniform_count > 0), 0, 0, 1, len(name.encode()))
    data += struct.pack("<4I2B2x4I", 0, gpu, minimum_os, 20300, 0, 1, 20300,
                        minimum_os if library else 0xFFFFFFFF,
                        0xFFFFFFFF if invalid else 0, 0)
    if invalid:
        return bytes(data)  # Intentionally missing invalid-container extras.
    data += name.encode()
    data += b"\0" * (-len(data) % 4)
    if uniform_count:
        data += struct.pack("<I", uniform_count) + bytes(uniform_count * 80)
    data += bytes(specialization_count * 16)
    data += struct.pack("<I", 4)
    payload = source + library
    encoded = compress(payload) if compressed else payload
    data += struct.pack("<4I", 4, len(encoded), int(compressed), len(payload))
    data += encoded
    data += b"\0" * (-len(data) % 4)
    data += struct.pack("<3I32s2I", 0, 0, 1, hashlib.sha256(source).digest(), len(source), len(library))
    return bytes(data)


def group(*variants):
    if not variants:
        variants = (variant(),)
    return b"GDSC" + struct.pack("<II", 4, len(variants)) + b"".join(
        struct.pack("<I", len(item)) + item for item in variants)


class CacheFramingTests(unittest.TestCase):
    def test_valid_uncompressed_library(self):
        report = cache.inspect_cache(group())
        self.assertEqual(report["variants"][0]["shader"], SHADER)
        self.assertGreater(report["variants"][0]["stages"][0]["library_bytes"], 4)

    def test_valid_uniforms_and_specialization(self):
        report = cache.inspect_cache(group(variant(uniform_count=3, specialization_count=2)))
        self.assertEqual(len(report["variants"]), 1)

    def test_zero_size_disabled_placeholders_are_preserved(self):
        report = cache.inspect_cache(group(variant(), b"", variant()))
        self.assertIsNone(report["variants"][1])

    def test_all_empty_group_rejected(self):
        with self.assertRaises(cache.CacheError):
            cache.inspect_cache(group(b"", b""))

    def test_marked_invalid_rejected_before_missing_extras(self):
        with self.assertRaisesRegex(cache.SkippedVariantError, "0xffffffff"):
            cache.inspect_cache(group(variant(invalid=True)))

    def test_source_only_rejected_even_when_source_contains_mtlb(self):
        data = group(variant(source=b"// MTLB is not a library", library=b""))
        with self.assertRaisesRegex(cache.CacheError, "missing baked Metal"):
            cache.inspect_cache(data)
        self.assertEqual(cache.inspect_cache(data, require_libraries=False)["variants"][0]
                         ["stages"][0]["library_bytes"], 0)

    def test_mtlb_must_start_at_declared_offset(self):
        with self.assertRaisesRegex(cache.CacheError, "does not begin with MTLB"):
            cache.inspect_cache(group(variant(library=b"xxxxMTLB")))

    def test_source_hash_tampering_rejected(self):
        data = bytearray(variant())
        data[-40] ^= 1
        with self.assertRaisesRegex(cache.CacheError, "SHA-256"):
            cache.inspect_cache(group(bytes(data)))

    def test_every_truncation_of_valid_variant_rejected(self):
        data = group()
        for size in range(len(data)):
            with self.subTest(size=size), self.assertRaises(cache.CacheError):
                cache.inspect_cache(data[:size])

    def test_trailing_bytes_rejected(self):
        for data in (group() + b"junk", group(variant() + b"junk")):
            with self.subTest(data=data), self.assertRaisesRegex(cache.CacheError, "trailing"):
                cache.inspect_cache(data)

    def test_wrong_format_versions_rejected(self):
        for offset, value in ((4, 3), (8, 5000), (16, 0), (20, 3), (24, 0), (28, 3)):
            data = bytearray(group())
            struct.pack_into("<I", data, offset, value)
            with self.subTest(offset=offset), self.assertRaises(cache.CacheError):
                cache.inspect_cache(data)

    def test_host_gpu_cache_rejected(self):
        with self.assertRaisesRegex(cache.CacheError, "Apple7"):
            cache.inspect_cache(group(variant(gpu=1009)))

    def test_msl_profile_corruption_rejected(self):
        data = bytearray(variant())
        struct.pack_into("<I", data, 104, 40000)
        with self.assertRaisesRegex(cache.CacheError, "language version"):
            cache.inspect_cache(group(bytes(data)))

    def test_mixed_shader_names_rejected(self):
        with self.assertRaisesRegex(cache.CacheError, "mixes shader names"):
            cache.inspect_cache(group(variant(), variant(name="OtherShaderRD")))

    def test_invalid_name_rejected(self):
        with self.assertRaisesRegex(cache.CacheError, "NUL"):
            cache.inspect_cache(group(variant(name="Wrong\0Name")))

    def test_unknown_compression_flags_rejected(self):
        with self.assertRaisesRegex(cache.CacheError, "compression flags"):
            cache.decompress_stage(b"abc", 2, 3)

    def test_output_bound_checked_before_decoder(self):
        with mock.patch.object(cache, "zstd_library") as decoder:
            with self.assertRaises(cache.CacheError):
                cache.decompress_stage(b"abc", 1, cache.MAX_STAGE_BYTES + 1)
            decoder.assert_not_called()

    def test_real_zstd_compression_and_damage(self):
        try:
            cache.zstd_library()
        except cache.CacheError as exc:
            self.skipTest(str(exc))
        report = cache.inspect_cache(group(variant(source=b"kernel code;" * 100, compressed=True)))
        self.assertGreater(report["expanded_bytes"], 1000)
        encoded = compress(b"test" * 100)
        for payload, size in ((encoded + b"junk", 400), (encoded, 401),
                              (encoded[:-2], 400), (encoded + encoded, 400)):
            with self.subTest(size=size, length=len(payload)), self.assertRaises(cache.CacheError):
                cache.decompress_stage(payload, 1, size)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="troop-cache-validator-test-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.source = self.root / "source"
        self.destination = self.root / "artifact"
        self.source.mkdir()
        self.write_cache(RELATIVE, group())

    def write_cache(self, relative, data):
        path = self.source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def extract(self, **kwargs):
        return cache.extract_tree(self.source, self.destination, **PROVENANCE, **kwargs)

    def verify(self):
        return cache.verify_tree(self.destination, **PROVENANCE)

    def test_extract_verify_preserves_exact_bytes_and_schema(self):
        original = (self.source / RELATIVE).read_bytes()
        manifest = self.extract()
        self.assertEqual((self.destination / "files" / RELATIVE).read_bytes(), original)
        self.assertEqual(manifest["files"], [{"path": RELATIVE, "size": len(original),
                                           "sha256": hashlib.sha256(original).hexdigest()}])
        self.assertEqual(self.verify(), manifest)

    def test_invalid_group_omitted_whole_only_when_explicit(self):
        bad = RELATIVE.replace("b" * 40, "d" * 40)
        self.write_cache(bad, group(variant(), variant(invalid=True)))
        with self.assertRaises(cache.SkippedVariantError):
            self.extract()
        self.assertFalse(self.destination.exists())
        manifest = self.extract(omit_invalid=True)
        self.assertEqual([r["path"] for r in manifest["omitted"]], [bad])
        self.assertFalse((self.destination / "files" / bad).exists())
        self.verify()

    def test_malformed_group_never_silently_omitted(self):
        self.write_cache(RELATIVE, b"GDSC" + bytes(20))
        with self.assertRaises(cache.CacheError):
            self.extract(omit_invalid=True)
        self.assertFalse(self.destination.exists())

    def test_source_only_and_host_cache_never_silently_omitted(self):
        for item in (variant(library=b""), variant(gpu=1009)):
            self.write_cache(RELATIVE, group(item))
            with self.assertRaises(cache.CacheError):
                self.extract(omit_invalid=True)
            self.assertFalse(self.destination.exists())

    def test_no_valid_groups_rejected(self):
        self.write_cache(RELATIVE, group(variant(invalid=True)))
        with self.assertRaisesRegex(cache.CacheError, "no fully baked"):
            self.extract(omit_invalid=True)

    def test_existing_destination_not_overwritten(self):
        self.destination.mkdir()
        marker = self.destination / "save.txt"
        marker.write_text("untouched")
        with self.assertRaises(cache.CacheError):
            self.extract()
        self.assertEqual(marker.read_text(), "untouched")

    def test_unexpected_path_and_symlink_rejected(self):
        other = self.source / "other.txt"
        other.write_bytes(b"not a cache")
        with self.assertRaises(cache.CacheError):
            self.extract()
        other.unlink()
        other.symlink_to(self.source / RELATIVE)
        with self.assertRaisesRegex(cache.CacheError, "symlink"):
            self.extract()

    def test_engine_and_settings_pins(self):
        for key, value in (("engine_version", "4.7.2.stable.official.ed1daf0bf"),
                           ("settings_sha256", "bad"), ("target_min_os", "26"),
                           ("target_min_os", "14.0")):
            options = {**PROVENANCE, key: value}
            with self.subTest(key=key), self.assertRaises(cache.CacheError):
                cache.extract_tree(self.source, self.destination, **options)

    def test_wrong_shader_name_for_path_rejected(self):
        self.write_cache(RELATIVE, group(variant(name="OtherShaderRD")))
        with self.assertRaisesRegex(cache.CacheError, "name/path"):
            self.extract()

    def test_byte_tamper_after_extraction_rejected(self):
        self.extract()
        path = self.destination / "files" / RELATIVE
        path.write_bytes(group(variant(source=b"different valid code")))
        with self.assertRaisesRegex(cache.CacheError, "manifest bytes"):
            self.verify()

    def test_manifest_duplicate_path_and_provenance_tampering(self):
        manifest = self.extract()
        path = self.destination / cache.MANIFEST_NAME
        for update in ({"files": manifest["files"] * 2}, {"engine_version": "wrong"},
                       {"settings_sha256": "d" * 64}, {"target_min_os": "14.0"}):
            path.write_text(json.dumps({**manifest, **update}))
            with self.subTest(update=update), self.assertRaises(cache.CacheError):
                self.verify()

    def test_missing_extra_and_unsafe_files_rejected(self):
        self.extract()
        path = self.destination / "files" / RELATIVE
        original = path.read_bytes()
        path.unlink()
        with self.assertRaises(cache.CacheError):
            self.verify()
        path.write_bytes(original)
        extra = self.destination / "other.txt"
        extra.write_text("unlisted")
        with self.assertRaises(cache.CacheError):
            self.verify()

    def test_unsorted_manifest_rejected(self):
        self.write_cache(RELATIVE.replace("b" * 40, "d" * 40), group())
        manifest = self.extract()
        manifest["files"].reverse()
        (self.destination / cache.MANIFEST_NAME).write_text(json.dumps(manifest))
        with self.assertRaisesRegex(cache.CacheError, "not sorted"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
