"""Synthetic Mach-O fixtures only: no vendor executable is used or stored."""
import hashlib
import struct
import tempfile
import unittest
from pathlib import Path

from build import neutral_background, validate_paths
from patcher import DYLIB_NAME, PATCHES, UnsupportedBinary, patch_binary, verify_original


def synthetic_binary():
    data = bytearray(0x16000)
    struct.pack_into('<IIIIIIII', data, 0, 0xFEEDFACF, 0x01000007, 3, 2, 1, 152, 0, 0)
    # One segment plus one synthetic section, with empty load-command padding.
    struct.pack_into('<II16sQQQQIIII', data, 32, 0x19, 152, b'__TEXT',
                     0x100000000, len(data), 0, len(data), 7, 5, 1, 0)
    struct.pack_into('<16s16sQQIIIIIIII', data, 104, b'__text', b'__TEXT',
                     0x100002000, len(data) - 0x2000, 0x2000, 4, 0, 0, 0, 0, 0, 0)
    for offset, expected, _, _ in PATCHES:
        data[offset:offset + len(expected)] = expected
    return bytes(data)


class PatchTests(unittest.TestCase):
    def test_exact_changes_and_original_preserved(self):
        original = synthetic_binary()
        digest = hashlib.sha256(original).hexdigest()
        self.assertEqual(verify_original(original, expected_sha256=digest), digest)
        patched = patch_binary(original)
        self.assertEqual(original, synthetic_binary())
        expected = bytearray(original)
        for offset, _, replacement, _ in PATCHES:
            expected[offset:offset + len(replacement)] = replacement
        size = (24 + len(DYLIB_NAME) + 7) & ~7
        command = struct.pack('<IIIIII', 0xC, size, 24, 0, 0x10000, 0x10000) + DYLIB_NAME
        expected[184:184 + size] = command.ljust(size, b'\0')
        struct.pack_into('<II', expected, 16, 2, 152 + size)
        self.assertEqual(patched, expected)

    def test_unknown_original_fingerprint_refused(self):
        with self.assertRaises(UnsupportedBinary):
            verify_original(synthetic_binary())

    def test_every_patch_site_checked(self):
        for offset, _, _, _ in PATCHES:
            with self.subTest(offset=offset):
                data = bytearray(synthetic_binary())
                data[offset] ^= 1
                with self.assertRaises(UnsupportedBinary):
                    patch_binary(data)

    def test_padding_collision_refused(self):
        data = bytearray(synthetic_binary())
        data[184] = 1
        with self.assertRaises(UnsupportedBinary):
            patch_binary(data)

    def test_corrupt_or_truncated_headers_refused(self):
        variants = [b'', synthetic_binary()[:100]]
        for offset, value in ((0, 0), (4, 0), (20, 0xFFFFFFFF), (36, 0), (96, 0xFFFFFFFF)):
            data = bytearray(synthetic_binary())
            struct.pack_into('<I', data, offset, value)
            variants.append(data)
        for data in variants:
            with self.subTest(length=len(data)):
                with self.assertRaises(UnsupportedBinary):
                    patch_binary(data)

    def test_patch_cannot_be_applied_twice(self):
        with self.assertRaises(UnsupportedBinary):
            patch_binary(patch_binary(synthetic_binary()))


class BuildSafetyTests(unittest.TestCase):
    def test_output_and_input_separation(self):
        with tempfile.TemporaryDirectory() as folder:
            original = Path(folder) / 'Original.app'
            original.mkdir()
            validate_paths(original, Path(folder) / 'Repaired.app', None)
            for output in (original, original / 'Nested.app', Path(folder) / 'not-an-app'):
                with self.subTest(output=output):
                    with self.assertRaises(ValueError):
                        validate_paths(original, output, None)
            link = Path(folder) / 'Dangling.app'
            link.symlink_to(Path(folder) / 'missing.app')
            with self.assertRaises(ValueError):
                validate_paths(original, link, None)

    def test_missing_image_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / 'Original.app'
            original.mkdir()
            with self.assertRaises(ValueError):
                validate_paths(original, root / 'Output.app', root / 'missing.jpg')

    def test_generated_backdrop_is_a_deterministic_png(self):
        with tempfile.TemporaryDirectory() as folder:
            first, second = Path(folder) / 'a.png', Path(folder) / 'b.png'
            neutral_background(first)
            neutral_background(second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertTrue(first.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'))
            self.assertEqual(struct.unpack_from('>II', first.read_bytes(), 16), (512, 512))


if __name__ == '__main__':
    unittest.main()
