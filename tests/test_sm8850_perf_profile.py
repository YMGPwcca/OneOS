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

    def test_cpu_profile_combines_with_thermal_and_perf_tokens(self):
        body = 'MODE=$1\nFW_CPU_PROFILE=default\nFW_PERF_PROFILE=off\n' + block("FRAMEWORK_CPU_PROFILE_ARGS") + block("FRAMEWORK_PERF_PROFILE_ARGS")
        body += '\nprintf "%s\\n" "$FW_CPU_PROFILE" "$FW_PERF_PROFILE" "$@"'
        for mode, original in (("--framework-check", ["run", "180"]),
                               ("--framework-session", ["run", "ACK", "SESSION", "RISK", "180"])):
            for thermal in ([], ["I_ACCEPT_SOFT_GUARD_OFF_180S"]):
                for perf in ([], ["perf-frame-task"]):
                    for cpu in ([], ["cpu-prime-first"]):
                        args = [mode, *original, *thermal]
                        p = subprocess.run(["sh", "-c", body, "test", *args, *perf, *cpu],
                                           check=True, capture_output=True, text=True)
                        self.assertEqual(["prime-first" if cpu else "default",
                                          "frame-task" if perf else "off", *args], p.stdout.splitlines())
        self.assertIn('prime-first) set -- "$@" --set sm8850-prime-first=1', SOURCE)
        self.assertLess(SOURCE.index("grep -Fq 'SM8850_CPU_PROFILE=PRIME_FIRST_ACTIVE'"),
                        SOURCE.index('APFS_DATA_CLONE=CONSUMED_ONE_SHOT_BEFORE_FRAMEWORK_STOP'))

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
        # Archive the previous session and persist the new profile before
        # the late one-shot claim. A pre-stop wake/setup refusal must not
        # consume Data; after claim, all paths remain one-shot.
        early = SOURCE.index('framework_block "isolated APFS Data clone was already consumed"')
        claim = SOURCE.index('APFS_DATA_CLONE=CONSUMED_ONE_SHOT_BEFORE_FRAMEWORK_STOP')
        archive = SOURCE.index('archive=$(mktemp -d "$STAGE/logs/session.XXXXXX")', early)
        create = SOURCE.index('mkdir -p "$CTL/base" "$CTL/keys" "$SESSION/tmp"', archive)
        launch = SOURCE.index('> "$CTL/framework.launch"', create)
        perf = SOURCE.index('> "$CTL/framework.perf-profile"', launch)
        cpu = SOURCE.index('> "$CTL/framework.cpu-profile"', perf)
        stop = SOURCE.index('if ! stop_android_framework; then', claim)
        inner = SOURCE.index('--inner 8>&- </dev/null >>"$SESSION/xnuhost.log"', stop)
        self.assertLess(early, archive)
        self.assertLess(archive, create)
        self.assertLess(create, launch)
        self.assertLess(launch, perf)
        self.assertLess(perf, cpu)
        self.assertLess(cpu, claim)
        self.assertLess(claim, stop)
        self.assertLess(stop, inner)
        # The profile token and native capabilities must be checked before
        # Data is claimed; a metadata write failure aborts before stop.
        for anchor in ('# END FRAMEWORK_CPU_PROFILE_ARGS',
                       '# END FRAMEWORK_PERF_PROFILE_ARGS',
                       "grep -Fq 'SM8850_CPU_PROFILE=PRIME_FIRST_ACTIVE'",
                       "grep -Fq 'frame-trace'",
                       "grep -Fq 'perf-task: enabled'"):
            self.assertLess(SOURCE.index(anchor), claim)
        self.assertIn('framework_setup_failed "could not record CPU placement profile"', SOURCE)
        self.assertIn('printf "failed\\n" > "$CTL/state"\n    exit 4', SOURCE)
        self.assertIn('--hz 60 "$@"', SOURCE)
        self.assertIn('framework_setup_failed "could not record performance instrumentation profile"', SOURCE)

if __name__ == "__main__":
    unittest.main()
