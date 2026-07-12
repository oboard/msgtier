#!/usr/bin/env python3
"""
Generate MoonBit conformance tests from Unicode IdnaTestV2.txt.

This script downloads the official IDNA test vectors and generates
MoonBit test cases for the idna package.
"""

import re
import urllib.request
from pathlib import Path


UNICODE_VERSION = "16.0.0"
TEST_URL = f"https://www.unicode.org/Public/idna/{UNICODE_VERSION}/IdnaTestV2.txt"

# Map status codes to the validation flag that must be enabled to trigger them
STATUS_CODE_TO_FLAG = {
    'B1': 'check_bidi', 'B2': 'check_bidi', 'B3': 'check_bidi',
    'B4': 'check_bidi', 'B5': 'check_bidi', 'B6': 'check_bidi',
    'C1': 'check_joiners', 'C2': 'check_joiners',
    'V2': 'check_hyphens', 'V3': 'check_hyphens',
    'V4': 'use_std3_ascii_rules', 'U1': 'use_std3_ascii_rules',
    'A4_1': 'verify_dns_length', 'A4_2': 'verify_dns_length',
}


def download_file(url: str, cache_dir: Path) -> str:
    """Download a file and cache it locally."""
    filename = url.split("/")[-1]
    cache_path = cache_dir / filename

    if cache_path.exists():
        print(f"Using cached {filename}")
        return cache_path.read_text(encoding="utf-8")

    print(f"Downloading {filename}...")
    with urllib.request.urlopen(url) as response:
        content = response.read().decode("utf-8")

    cache_path.write_text(content, encoding="utf-8")
    return content


def parse_escape_sequences(s: str) -> str:
    r"""
    Convert Unicode escape sequences to actual characters.
    Handles both \uXXXX and \x{XXXX} formats.
    Also handles "" convention for empty strings.
    """
    # Handle "" meaning empty string (per UTS #46 test format)
    if s == '""':
        return ""

    # Handle \x{XXXX} format (variable length hex)
    def replace_x_escape(m):
        return chr(int(m.group(1), 16))

    s = re.sub(r"\\x\{([0-9A-Fa-f]+)\}", replace_x_escape, s)

    # Handle \uXXXX format (4-digit hex)
    def replace_u_escape(m):
        return chr(int(m.group(1), 16))

    s = re.sub(r"\\u([0-9A-Fa-f]{4})", replace_u_escape, s)

    return s


def parse_status(status_str: str) -> list[str] | None:
    """Parse status codes from string like '[]' or '[B5, B6]'.

    Returns:
        - None if the string is blank (inherit from previous column)
        - [] if the string is '[]' (explicit no errors)
        - list of codes if the string is '[B5, B6]', etc.
    """
    status_str = status_str.strip()
    if not status_str:
        return None  # Blank means inherit
    if status_str == "[]":
        return []  # Explicit empty
    # Extract codes from brackets
    match = re.match(r"\[([^\]]*)\]", status_str)
    if match:
        codes = match.group(1).strip()
        if codes:
            # Split by comma and/or whitespace, strip each code
            return [c.strip() for c in re.split(r'[,\s]+', codes) if c.strip()]
        return []
    return None


def parse_test_line(line: str, line_num: int) -> dict | None:
    """
    Parse one test line from IdnaTestV2.txt.

    Format: source; toUnicode; toUnicodeStatus; toAsciiN; reserved; toAsciiT

    Returns dict with parsed fields or None for comments/empty lines.
    """
    # Skip comments and empty lines
    line = line.strip()
    if not line or line.startswith("#"):
        return None

    # Split by semicolon
    parts = line.split(";")
    if len(parts) < 6:
        return None

    source = parse_escape_sequences(parts[0].strip())
    to_unicode = parse_escape_sequences(parts[1].strip())
    to_unicode_status = parse_status(parts[2].strip())
    to_ascii_n = parse_escape_sequences(parts[3].strip())
    to_ascii_n_status = parse_status(parts[4].strip()) if len(parts) > 4 else None
    to_ascii_t = parse_escape_sequences(parts[5].strip()) if len(parts) > 5 else ""

    # If toUnicode is empty, use source
    if not to_unicode:
        to_unicode = source

    # If toAsciiN is empty, use toUnicode (which may already be source)
    if not to_ascii_n:
        to_ascii_n = to_unicode

    # If toUnicodeStatus is None (blank), it means no errors
    if to_unicode_status is None:
        to_unicode_status = []

    # If toAsciiNStatus is None (blank), inherit from toUnicodeStatus
    # If toAsciiNStatus is [] (explicit empty), it means no errors
    if to_ascii_n_status is None:
        to_ascii_n_status = to_unicode_status.copy()

    return {
        "line_num": line_num,
        "source": source,
        "to_unicode": to_unicode,
        "to_unicode_status": to_unicode_status,
        "to_ascii_n": to_ascii_n,
        "to_ascii_n_status": to_ascii_n_status,
        "to_ascii_t": to_ascii_t,
    }


def has_surrogate(s: str) -> bool:
    """Check if string contains surrogate code points (0xD800-0xDFFF)."""
    for ch in s:
        cp = ord(ch)
        if 0xD800 <= cp <= 0xDFFF:
            return True
    return False


def get_required_flags(codes: list[str]) -> dict[str, bool]:
    """Determine which validation flags need to be enabled based on status codes.

    Returns a dict of flag_name -> True for each flag that must be enabled
    to trigger the errors indicated by the status codes.
    """
    flags = {
        'check_bidi': False,
        'check_joiners': False,
        'check_hyphens': False,
        'use_std3_ascii_rules': False,
        'verify_dns_length': False,
    }
    for code in codes:
        if code in STATUS_CODE_TO_FLAG:
            flags[STATUS_CODE_TO_FLAG[code]] = True
    return flags


def has_flag_independent_errors(codes: list[str]) -> bool:
    """Check if any status codes are flag-independent (always trigger errors).

    Status codes not in STATUS_CODE_TO_FLAG (like V1, V5, V6, V7, P*, X*, A3)
    are errors that occur regardless of flag settings.
    """
    flag_dependent = set(STATUS_CODE_TO_FLAG.keys())
    return any(c not in flag_dependent for c in codes)


def escape_moonbit_string(s: str) -> str:
    """Escape a string for use in MoonBit source code."""
    result = []
    for ch in s:
        cp = ord(ch)
        if ch == "\\":
            result.append("\\\\")
        elif ch == '"':
            result.append('\\"')
        elif ch == "\n":
            result.append("\\n")
        elif ch == "\r":
            result.append("\\r")
        elif ch == "\t":
            result.append("\\t")
        elif 0x20 <= cp <= 0x7E:
            # Printable ASCII
            result.append(ch)
        elif 0xD800 <= cp <= 0xDFFF:
            # Surrogate - skip these (will be filtered out at test level)
            result.append(f"<SURROGATE:{cp:04X}>")
        elif cp <= 0xFFFF:
            # BMP character
            result.append(f"\\u{cp:04X}")
        else:
            # Supplementary character
            result.append(f"\\u{{{cp:X}}}")
    return "".join(result)


def generate_tests(test_cases: list[dict], output_path: Path):
    """Generate MoonBit conformance test file."""

    # Group tests by expected behavior
    success_tests = []          # No errors
    flag_error_tests = []       # Errors that need specific flags enabled
    always_error_tests = []     # Errors regardless of flags
    skipped = 0

    for tc in test_cases:
        # Skip tests with surrogate code points (MoonBit doesn't support them)
        if has_surrogate(tc["source"]) or has_surrogate(tc["to_ascii_n"]):
            skipped += 1
            continue

        status = tc["to_ascii_n_status"]

        if not status:
            # No errors - success test
            success_tests.append(tc)
        else:
            required_flags = get_required_flags(status)
            has_independent = has_flag_independent_errors(status)

            if any(required_flags.values()):
                # Has flag-dependent errors - enable those flags
                tc["required_flags"] = required_flags
                tc["status_codes"] = status
                flag_error_tests.append(tc)
            elif has_independent:
                # Only flag-independent errors
                tc["status_codes"] = status
                always_error_tests.append(tc)
            else:
                # Shouldn't happen, but treat as success
                success_tests.append(tc)

    print(f"  Skipped (surrogates): {skipped}")

    code = '''///|
/// IDNA Conformance Tests
/// Generated from IdnaTestV2.txt (Unicode {version})
///
/// These tests verify compliance with UTS #46 (Unicode IDNA Compatibility Processing).
/// Source: https://www.unicode.org/Public/idna/{version}/IdnaTestV2.txt

'''.format(version=UNICODE_VERSION)

    # Generate success tests
    code += "// Success tests (no error expected)\n\n"

    tests_per_segment = 500  # Split into segments to avoid line limit

    for i, tc in enumerate(success_tests):
        # Add segment marker every N tests
        if i > 0 and i % tests_per_segment == 0:
            code += "///|\n\n"

        source_escaped = escape_moonbit_string(tc["source"])
        expected_escaped = escape_moonbit_string(tc["to_ascii_n"])

        # Create a short label for the test name
        label = tc["source"][:20]
        if len(tc["source"]) > 20:
            label += "..."
        label_escaped = escape_moonbit_string(label)

        code += f'''test "conformance/{tc['line_num']:04d}: {label_escaped}" {{
  let result = @idna.to_ascii(
    "{source_escaped}",
    use_std3_ascii_rules=false,
    check_hyphens=false,
    check_bidi=false,
    check_joiners=false,
    verify_dns_length=false,
  )
  assert_eq(result, "{expected_escaped}")
}}

'''

    # Generate flag-dependent error tests (with appropriate flags enabled)
    code += "///|\n\n// Error tests with validation flags enabled\n\n"

    for i, tc in enumerate(flag_error_tests):
        # Add segment marker every N tests
        if i > 0 and i % tests_per_segment == 0:
            code += "///|\n\n"

        source_escaped = escape_moonbit_string(tc["source"])
        status_str = " ".join(tc["status_codes"])
        flags = tc["required_flags"]

        # Create a short label for the test name
        label = tc["source"][:20]
        if len(tc["source"]) > 20:
            label += "..."
        label_escaped = escape_moonbit_string(label)

        code += f'''test "conformance/{tc['line_num']:04d}: {label_escaped} [{status_str}]" {{
  let result = to_ascii_result(
    "{source_escaped}",
    use_std3_ascii_rules={str(flags['use_std3_ascii_rules']).lower()},
    check_hyphens={str(flags['check_hyphens']).lower()},
    check_bidi={str(flags['check_bidi']).lower()},
    check_joiners={str(flags['check_joiners']).lower()},
    verify_dns_length={str(flags['verify_dns_length']).lower()},
  )
  guard result is Err(_) else {{
    fail("Expected error for line {tc['line_num']}, got Ok")
  }}
}}

'''

    # Generate always-error tests (fail regardless of flags)
    if always_error_tests:
        code += "///|\n\n// Error tests (always fail regardless of flags)\n\n"

        for i, tc in enumerate(always_error_tests):
            # Add segment marker every N tests
            if i > 0 and i % tests_per_segment == 0:
                code += "///|\n\n"

            source_escaped = escape_moonbit_string(tc["source"])
            status_str = " ".join(tc["status_codes"])

            # Create a short label for the test name
            label = tc["source"][:20]
            if len(tc["source"]) > 20:
                label += "..."
            label_escaped = escape_moonbit_string(label)

            code += f'''test "conformance/{tc['line_num']:04d}: {label_escaped} [{status_str}]" {{
  let result = to_ascii_result(
    "{source_escaped}",
    use_std3_ascii_rules=false,
    check_hyphens=false,
    check_bidi=false,
    check_joiners=false,
    verify_dns_length=false,
  )
  guard result is Err(_) else {{
    fail("Expected error for line {tc['line_num']}, got Ok")
  }}
}}

'''

    output_path.write_text(code, encoding="utf-8")
    print(f"Generated {output_path}")
    print(f"  Success tests: {len(success_tests)}")
    print(f"  Flag-enabled error tests: {len(flag_error_tests)}")
    print(f"  Always-error tests: {len(always_error_tests)}")
    print(f"  Total: {len(test_cases)}")


def main():
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    cache_dir = script_dir / ".cache"
    output_path = project_root / "idna" / "conformance_test.mbt"

    cache_dir.mkdir(exist_ok=True)

    # Download test file
    content = download_file(TEST_URL, cache_dir)

    # Parse test cases
    print("Parsing IdnaTestV2.txt...")
    test_cases = []
    for line_num, line in enumerate(content.split("\n"), start=1):
        tc = parse_test_line(line, line_num)
        if tc:
            test_cases.append(tc)

    print(f"  Found {len(test_cases)} test cases")

    # Generate MoonBit tests
    print("\nGenerating MoonBit conformance tests...")
    generate_tests(test_cases, output_path)

    print("\nDone!")
    print("Run: moon test -p idna -f 'conformance'")


if __name__ == "__main__":
    main()
