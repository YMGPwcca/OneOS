#!/usr/bin/env python3
"""Exercise the actual stop-loop body with inert shell functions.
No ADB, real Android properties, process signals or device access.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWITCH = ROOT / "switcher/assets/oneios_switch.sh"
RETURN = ROOT / "switcher/assets/oneios_return.sh"


class BootAnimationStopLoop(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = SWITCH.read_text()
        case = source[source.index("    --stop-loop)"):source.index("    --feed)", source.index("    --stop-loop)"))]
        # Execute only the loop after its existing live admission checks.
        start = case.index("        bootanim_tick=0\n")
        end = case.index("        exit 0\n", start)
        cls.loop = case[start:end]

    def run_loop(self, profile, scenario="normal"):
        with tempfile.TemporaryDirectory(prefix="oneos-bootanim-test.") as directory:
            root = Path(directory)
            env = dict(os.environ, CTL=directory, SESSION=directory,
                       FRAMEWORK=str(profile), SCENARIO=scenario)
            stub = r"""
tick=0
getprop() {
    printf '%s %s\n' "$tick" "$1" >> "$CTL/reads"
    case "$1" in
        init.svc.zygote|init.svc.zygote_secondary|init.svc.zygote_next)
            echo running ;;
        init.svc.bootanim)
            case "$SCENARIO" in
                stop_race) : > "$CTL/stop-loop.off"; echo running ;;
                return_race) : > "$SESSION/return.request"; echo running ;;
                stopped) echo stopped ;;
                unknown) echo unknown ;;
                *)
                    case "$tick" in
                        0) echo running ;;
                        5) echo restarting ;;
                        10) echo stopped ;;
                        *) echo running ;;
                    esac ;;
            esac ;;
        *) echo unexpected_property; exit 5 ;;
    esac
}
setprop() {
    printf '%s %s %s\n' "$tick" "$1" "$2" >> "$CTL/writes"
}
sleep() {
    [ "$1" = 0.2 ] || exit 6
    tick=$((tick+1))
    if [ "$tick" -ge 12 ]; then : > "$CTL/stop-loop.off"; fi
}
"""
            run = subprocess.run(["sh", "-c", stub + "\n" + self.loop],
                                 env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stderr)
            return ((root / "reads").read_text().splitlines(),
                    (root / "writes").read_text().splitlines())

    def test_framework_stops_stock_animation_immediately_and_after_restart(self):
        reads, writes = self.run_loop(1)
        self.assertEqual([x for x in reads if x.endswith(".bootanim")],
                         ["0 init.svc.bootanim", "5 init.svc.bootanim", "10 init.svc.bootanim"])
        self.assertEqual([x for x in writes if x.endswith(" bootanim")],
                         ["0 ctl.stop bootanim", "5 ctl.stop bootanim"])
        for name in ("zygote", "zygote_secondary", "zygote_next"):
            self.assertEqual(len([x for x in reads if x.endswith("." + name)]), 12)
            self.assertEqual(len([x for x in writes if x.endswith(" " + name)]), 12)
        self.assertTrue(all(x.split()[-1] in
                            ("zygote", "zygote_secondary", "zygote_next", "bootanim")
                            and x.split()[1] == "ctl.stop" for x in writes))

    def test_stopped_or_unknown_service_does_not_get_writes(self):
        for scenario in ("stopped", "unknown"):
            with self.subTest(scenario=scenario):
                _, writes = self.run_loop(1, scenario)
                self.assertFalse(any(x.endswith(" bootanim") for x in writes))

    def test_return_race_does_not_stop_boot_animation(self):
        for scenario in ("stop_race", "return_race"):
            with self.subTest(scenario=scenario):
                _, writes = self.run_loop(1, scenario)
                self.assertFalse(any(x.endswith(" bootanim") for x in writes))

    def test_legacy_branch_is_unchanged(self):
        reads, writes = self.run_loop(0)
        self.assertEqual(len([x for x in reads if x.endswith(".bootanim")]), 12)
        self.assertFalse(any(x.endswith(".zygote_next") for x in reads))
        self.assertEqual([x for x in writes if x.endswith(" bootanim")],
                         [f"{i} ctl.stop bootanim" for i in range(12) if i not in (5, 10)])

    def test_return_retires_loop_before_restoring_boot_animation(self):
        s = RETURN.read_text()
        gate = s.index('step "[3/5] Gate B:')
        stop = s.index('true > "$CTL/stop-loop.off"', gate)
        retired = s.index('[ $alive = 0 ] || failsafe', stop)
        start = s.index('setprop ctl.start bootanim', retired)
        self.assertLess(stop, retired)
        self.assertLess(retired, start)


if __name__ == "__main__":
    unittest.main(verbosity=2)
