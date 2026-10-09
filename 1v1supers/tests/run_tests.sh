#!/usr/bin/env bash
# Runs every headless gameplay test. Usage:
#   GODOT=/path/to/godot tests/run_tests.sh          (from the 1v1supers folder)
# Exits non-zero if any test fails.
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
"$GODOT" --headless --import --path . > /dev/null 2>&1
failed=0
for t in tests/test_*.gd; do
	[ "$t" = "tests/test_case.gd" ] && continue
	out=$("$GODOT" --headless --path . -s "$t" 2>&1)
	code=$?
	echo "$out" | grep -E "^--|^  (ok|FAIL)|TEST RESULT|SCRIPT ERROR" | sed "s|^|[$(basename "$t" .gd)] |"
	if [ $code -ne 0 ]; then
		failed=1
	fi
done
if [ $failed -ne 0 ]; then
	echo "SOME TESTS FAILED"
	exit 1
fi
echo "ALL TESTS PASSED"
