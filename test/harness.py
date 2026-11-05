"""The mock Director lives in its own repo, control4-test-harness (c4mock.py), checked out next
to this one or wherever C4_TEST_HARNESS points."""

import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
_path = os.environ.get("C4_TEST_HARNESS") or os.path.join(_here, "..", "..", "control4-test-harness")
if not os.path.exists(os.path.join(_path, "c4mock.py")):
    sys.exit(f"control4-test-harness not found at {os.path.abspath(_path)}: clone it there or set C4_TEST_HARNESS")
sys.path.insert(0, _path)

from c4mock import Director, Harness  # noqa: E402,F401
