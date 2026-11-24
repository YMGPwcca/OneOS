#!/usr/bin/env python3
"""Offline shell contract for full takeover telemetry; never contacts a device."""
from pathlib import Path
import os
import subprocess
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "switcher/assets/oneios_switch.sh").read_text()


def block(name):
    return SOURCE.split("# BEGIN " + name, 1)[1].split("# END " + name, 1)[0]


class PerfProfile(unittest.TestCase):
    def test_positional_tokens_preserve_original_thermal_args(self):
        body = 'MODE=$1\nFW_PERF_PROFILE=off\n' + block("FRAMEWORK_PERF_PROFILE_ARGS")
        body += '\nprintf "%s\\n" "$FW_PERF_PROFILE" "$@"'
        for mode, original in (("--framework-check", ["run", "180"]),
                               ("--framework-session", ["run", "ACK", "SESSION", "RISK", "180"])):
            for thermal in ([], ["I_ACCEPT_SOFT_GUARD_OFF_180S"]):
                for token, profile in (("", "off"), ("perf-off", "off"),
                                       ("perf-frame", "frame"), ("perf-task", "task"),
                                       ("perf-frame-task", "frame-task")):
                    with self.subTest(mode=mode, thermal=thermal, token=token):
                        args = [mode, *original, *thermal]
                        p = subprocess.run(["sh", "-c", body, "test", *args, *([token] if token else [])],
                                           check=True, capture_output=True, text=True)
                        self.assertEqual([profile, *args], p.stdout.splitlines())

    def test_unknown_token_is_not_stripped(self):
        body = 'MODE=$1\nFW_PERF_PROFILE=off\n' + block("FRAMEWORK_PERF_PROFILE_ARGS")
        body += '\nprintf "%s\\n" "$FW_PERF_PROFILE" "$@"'
        p = subprocess.run(["sh", "-c", body, "test", "--framework-check", "run", "180", "perf-unknown"],
                           check=True, capture_output=True, text=True)
        self.assertEqual(["off", "--framework-check", "run", "180", "perf-unknown"], p.stdout.splitlines())

    def test_runtime_arguments_and_verbose_trace(self):
        # Replace only the root-owned file read; execute the actual case and
        # argument expansion, with no Android shell or real control directory.
        body = block("FRAMEWORK_PERF_RUNTIME_ARGS").replace(
            'perf_profile=$(cat /data/control/framework.perf-profile 2>/dev/null) ||',
            'perf_profile=$1 ||')
        body = 'die_inner() { exit 71; }\n' + body
        body += '\nprintf "ARG=%s\\n" "$@"\nprintf "VERBOSE=%s\\n" "${ONEIOS_GPU_TRACE-unset}"'
        for profile, expected in (("off", ["ARG="]), ("frame", ["ARG=--set", "ARG=frame-trace=1"]),
                                  ("task", ["ARG=--set", "ARG=perf-task=1"]),
                                  ("frame-task", ["ARG=--set", "ARG=frame-trace=1", "ARG=--set", "ARG=perf-task=1"])):
            with self.subTest(profile=profile):
                p = subprocess.run(["sh", "-c", body, "test", profile],
                                   env={**os.environ, "ONEIOS_GPU_TRACE": "1"}, check=True,
                                   capture_output=True, text=True)
                self.assertEqual(expected, [line for line in p.stdout.splitlines() if line.startswith("ARG=")])
                self.assertIn("VERBOSE=" + ("1" if profile == "off" else "unset"), p.stdout.splitlines())
        p = subprocess.run(["sh", "-c", body, "test", "invalid"], capture_output=True, text=True)
        self.assertEqual(71, p.returncode)

    def test_metadata_and_exec_are_wired(self):
        self.assertIn('printf \'%s\\n\' "$FW_PERF_PROFILE" > "$CTL/framework.perf-profile"', SOURCE)
        self.assertLess(SOURCE.index('> "$CTL/framework.perf-profile"'),
                        SOURCE.index('APFS_DATA_CLONE=CONSUMED_ONE_SHOT_BEFORE_FRAMEWORK_STOP'))
        self.assertIn('--hz 60 "$@"', SOURCE)
        self.assertIn('framework_setup_failed "could not record performance instrumentation profile"', SOURCE)

if __name__ == "__main__":
    unittest.main()
