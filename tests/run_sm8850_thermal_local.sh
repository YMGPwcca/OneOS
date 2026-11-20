#!/usr/bin/env bash
# OneOS SM8850 P0 local-only test runner. Does not invoke adb, root, or any
# physical/guest action. Fail on a missing file, a test failure, or count drift.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/switcher/assets"
TESTS="$ROOT/tests"
EXPECTED_TESTS=178

for name in \
  oneios_switch.sh \
  oneios_sm8850_thermal_reader.sh \
  oneios_sm8850_thermal_shadow.sh \
  oneios_sm8850_thermal_health.sh \
  oneios_sm8850_thermal_pinned_reader.sh \
  oneios_sm8850_thermal_trial.sh \
  oneios_sm8850_thermal_takeover_guard.sh; do
  test -f "$SCRIPT/$name" || {
    echo "P0_LOCAL=FAIL_MISSING_FILE $name" >&2
    exit 3
  }
  sh -n "$SCRIPT/$name" || {
    echo "P0_LOCAL=FAIL_SHELL_SYNTAX $name" >&2
    exit 3
  }
done

test -f "$ROOT/scripts/phone/run-sm8850-thermal-shadow-oneui.sh" || {
  echo "P0_LOCAL=FAIL_MISSING_HOST_COLLECTOR" >&2
  exit 3
}
bash -n "$ROOT/scripts/phone/run-sm8850-thermal-shadow-oneui.sh" || exit 3
bash "$ROOT/scripts/phone/run-sm8850-thermal-shadow-oneui.sh" --audit-only || exit 3
test -f "$ROOT/scripts/phone/sm8850-soc-candidate-map.py" || {
  echo "P0_LOCAL=FAIL_MISSING_SOC_MAPPING_TOOL" >&2
  exit 3
}
python3 "$ROOT/scripts/phone/sm8850-soc-candidate-map.py" || exit 3
test -f "$ROOT/scripts/phone/sm8850-four-sensor-oneui.py" || {
  echo "P0_LOCAL=FAIL_MISSING_FOUR_SENSOR_HOST" >&2
  exit 3
}
python3 -m py_compile "$ROOT/scripts/phone/sm8850-four-sensor-oneui.py" || exit 3
python3 "$ROOT/scripts/phone/sm8850-four-sensor-oneui.py" || exit 3
test -f "$ROOT/scripts/phone/sm8850-thermal-junction-inventory.py" || {
  echo "P0_LOCAL=FAIL_MISSING_JUNCTION_INVENTORY" >&2
  exit 3
}
python3 -m py_compile "$ROOT/scripts/phone/sm8850-thermal-junction-inventory.py" || exit 3
python3 "$ROOT/scripts/phone/sm8850-thermal-junction-inventory.py" || exit 3
test -f "$ROOT/scripts/phone/sm8850-thermal-manifest.py" || {
  echo "P0_LOCAL=FAIL_MISSING_BOOT_MANIFEST_BUILDER" >&2
  exit 3
}
python3 -m py_compile "$ROOT/scripts/phone/sm8850-thermal-manifest.py" || exit 3
python3 "$ROOT/scripts/phone/sm8850-thermal-manifest.py" || exit 3
test -f "$ROOT/scripts/phone/sm8850-live-thermal-trial.py" || {
  echo "P0_LOCAL=FAIL_MISSING_LIVE_TRIAL_HOST" >&2
  exit 3
}
python3 -m py_compile "$ROOT/scripts/phone/sm8850-live-thermal-trial.py" || exit 3
python3 "$ROOT/scripts/phone/sm8850-live-thermal-trial.py" || exit 3
test -f "$ROOT/scripts/phone/sm8850-recovery-provenance.py" || {
  echo "P0_LOCAL=FAIL_MISSING_RECOVERY_PROVENANCE_INSPECTOR" >&2
  exit 3
}
python3 -m py_compile "$ROOT/scripts/phone/sm8850-recovery-provenance.py" || exit 3
python3 "$ROOT/scripts/phone/sm8850-recovery-provenance.py" || exit 3
test -f "$ROOT/scripts/phone/sm8850-reboot-witness.py" || {
  echo "P0_LOCAL=FAIL_MISSING_REBOOT_HOST_WITNESS" >&2
  exit 3
}
python3 -m py_compile "$ROOT/scripts/phone/sm8850-reboot-witness.py" || exit 3
python3 "$ROOT/scripts/phone/sm8850-reboot-witness.py" || exit 3
test -f "$ROOT/scripts/phone/sm8850-takeover-short-probe.py" || {
  echo "P0_LOCAL=FAIL_MISSING_SHORT_PROBE_ORCHESTRATOR" >&2
  exit 3
}
python3 -m py_compile "$ROOT/scripts/phone/sm8850-takeover-short-probe.py" || exit 3
python3 "$ROOT/scripts/phone/sm8850-takeover-short-probe.py" || exit 3

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
echo "ONEOS_P0_OFFLINE_178=PASS"
echo "P0_SAFETY_STATUS=OFFLINE_SIMULATION_ONLY_NO_PHYSICAL_GUARD"
