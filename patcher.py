"""Checked, local-only patches for the supported original v1.9 x86_64 binary."""
import hashlib
import struct

SUPPORTED_SHA256 = 'c91d8a80eb75e23880da12fc2bc47c5c03efda9ff1e244ae126a8ce58500a15d'
DYLIB_NAME = b'@executable_path/AquariumCompatibility.dylib\0'
PATCHES = (
    (0x14EE7, bytes.fromhex('e828320000'), b'\x90' * 5, 'photo-textured top surface'),
    (0x4AAF, bytes.fromhex('767b'), b'\x90\x90', 'extra frame-rate gate'),
    (0x40D5, bytes.fromhex('4889c141b801000000'), bytes.fromhex('488d48016a01415890'),
     'fish-exclusion string terminator'),
)


class UnsupportedBinary(ValueError):
    pass


def verify_original(data, expected_sha256=SUPPORTED_SHA256):
    digest = hashlib.sha256(data).hexdigest()
    if digest != expected_sha256:
        raise UnsupportedBinary(
            f'Unsupported original x86_64 executable (SHA-256 {digest}). '
            'Only the tested, unmodified v1.9 build is supported. '
            'Do not use a previously repaired copy as the input.')
    return digest


def patch_binary(original):
    """Return a patched copy; never modify input. Caller verifies its fingerprint."""
    data = bytearray(original)
    if len(data) < 32:
        raise UnsupportedBinary('Truncated Mach-O header.')
    magic, cpu = struct.unpack_from('<II', data)
    if magic != 0xFEEDFACF or cpu != 0x01000007:
        raise UnsupportedBinary('Expected a little-endian x86_64 Mach-O executable.')
    ncmds, sizeofcmds = struct.unpack_from('<II', data, 16)
    end = 32 + sizeofcmds
    if not ncmds or end > len(data):
        raise UnsupportedBinary('Invalid Mach-O load-command bounds.')
    position, offsets = 32, []
    for _ in range(ncmds):
        if position + 8 > end:
            raise UnsupportedBinary('Truncated load command.')
        command, length = struct.unpack_from('<II', data, position)
        if length < 8 or length % 8 or position + length > end:
            raise UnsupportedBinary('Invalid load-command size.')
        if command == 0x19:  # LC_SEGMENT_64
            if length < 72:
                raise UnsupportedBinary('Truncated segment command.')
            sections = struct.unpack_from('<I', data, position + 64)[0]
            if 72 + sections * 80 > length:
                raise UnsupportedBinary('Truncated section table.')
            for section in range(sections):
                offset = struct.unpack_from('<I', data, position + 72 + section * 80 + 48)[0]
                if offset:
                    offsets.append(offset)
        position += length
    if position != end or not offsets:
        raise UnsupportedBinary('Invalid load-command table or missing sections.')
    size = (24 + len(DYLIB_NAME) + 7) & ~7
    if end + size > min(offsets) or end + size > len(data) or any(data[end:end + size]):
        raise UnsupportedBinary('Insufficient empty load-command padding.')
    for offset, expected, replacement, description in PATCHES:
        if data[offset:offset + len(expected)] != expected:
            raise UnsupportedBinary(f'Unexpected instruction at {description} patch site.')
        data[offset:offset + len(expected)] = replacement
    command = struct.pack('<IIIIII', 0xC, size, 24, 0, 0x10000, 0x10000) + DYLIB_NAME
    data[end:end + size] = command.ljust(size, b'\0')
    struct.pack_into('<II', data, 16, ncmds + 1, sizeofcmds + size)
    return bytes(data)
