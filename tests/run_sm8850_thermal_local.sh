#!/usr/bin/env bash
# OneOS SM8850 P0 local-only test runner. Does not invoke adb, root, or any
# physical/guest action. Fail on a missing file, a test failure, or count drift.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/switcher/assets"
TESTS="$ROOT/tests"
EXPECTED_TESTS=67

for name in \
  oneios_switch.sh \
  oneios_sm8850_thermal_reader.sh \
  oneios_sm8850_thermal_shadow.sh \
  oneios_sm8850_thermal_health.sh; do
  test -f "$SCRIPT/$name" || {
    echo "P0_LOCAL=FAIL_MISSING_FILE $name" >&2
    exit 3
  }
  sh -n "$SCRIPT/$name" || {
    echo "P0_LOCAL=FAIL_SHELL_SYNTAX $name" >&2
    exit 3
  }
done

LOG="$(mktemp /tmp/oneos-p0-thermal-tests.XXXXXX)"
trap 'rm -f "$LOG"' EXIT
echo "P0_LOCAL=RUNNING expected_tests=$EXPECTED_TESTS"
if ! python3 -m unittest discover -s "$TESTS" -p 'test_sm8850_thermal_*.py' -v \
    > "$LOG" 2>&1; then
  cat "$LOG" >&2
  echo "P0_LOCAL=FAIL_REGRESSION" >&2
  exit 4
fi
cat "$LOG"
ACTUAL_TESTS="$(awk '/^Ran [0-9]+ tests in / { count=$2 } END { print count+0 }' "$LOG")"
if [ "$ACTUAL_TESTS" != "$EXPECTED_TESTS" ]; then
  echo "P0_LOCAL=FAIL_TEST_COUNT expected=$EXPECTED_TESTS actual=$ACTUAL_TESTS" >&2
  exit 5
fi
grep -xq 'OK' "$LOG" || {
  echo "P0_LOCAL=FAIL_MISSING_TEST_OK" >&2
  exit 5
}
echo "ONEOS_P0_OFFLINE_67=PASS"
echo "P0_SAFETY_STATUS=OFFLINE_SIMULATION_ONLY_NO_PHYSICAL_GUARD"
