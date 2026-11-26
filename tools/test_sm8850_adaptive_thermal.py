"""Host-only policy regressions: never open sysfs, adb or a phone."""
import unittest
from sm8850_adaptive_thermal import State, Sample, step


def sample(seq, temp, ms=None, **kwargs):
    data = dict(seq=seq, ms=seq*1000 if ms is None else ms,
                cpu_mc=temp, gpu_mc=40000, ddr_mc=40000,
                battery_dc=300, lrp_dc=300, board_ap_dc=400)
    data.update(kwargs)
    return Sample(**data)


class Policy(unittest.TestCase):
    def test_cool_ramps_both_above_40(self):
        s = State(40, 40, 20)
        for i in range(1, 51):
            s, action = step(s, sample(i, 44000))
        self.assertEqual((100, 100), (s.frequency_pct, s.cpu_pct))

    def test_soft_thresholds(self):
        s, a = step(State(90, 90, 20), sample(1, 70000))
        self.assertEqual(("SOFT", 80, 80), (a, s.frequency_pct, s.cpu_pct))
        s, a = step(s, sample(2, 75000))
        self.assertEqual(("SOFT", 60, 60), (a, s.frequency_pct, s.cpu_pct))

    def test_hard_latch_and_release(self):
        s, a = step(State(90, 90, 20), sample(1, 80000))
        self.assertEqual(("HARD", True, 20, 10),
                         (a, s.hard, s.frequency_pct, s.cpu_pct))
        s, a = step(s, sample(2, 70001))
        self.assertEqual("HARD", a)
        s, a = step(s, sample(3, 70000))
        self.assertEqual(("RECOVERY_MINIMUM", False, 20, 10),
                         (a, s.hard, s.frequency_pct, s.cpu_pct))

    def test_gpu_and_ddr_can_trigger_hard(self):
        for key in ("gpu_mc", "ddr_mc"):
            s, a = step(State(100, 100, 20), sample(1, 44000, **{key: 80000}))
            self.assertEqual(("HARD", 10), (a, s.cpu_pct))

    def test_emergency_quiesce_not_return_and_cool_resume(self):
        for key, value in (("cpu_mc", 90000), ("gpu_mc", 95000),
                           ("ddr_mc", 95000), ("battery_dc", 480),
                           ("lrp_dc", 500), ("board_ap_dc", 700)):
            s, a = step(State(100, 100, 20), sample(1, 44000, **{key: value}))
            self.assertEqual(("QUIESCE_TEMPERATURE", "temperature", 10),
                             (a, s.pause, s.cpu_pct))
            for i in range(2, 7):
                s, a = step(s, sample(i, 65000))
            self.assertEqual(("RESUME_MINIMUM", "", 20, 10),
                             (a, s.pause, s.frequency_pct, s.cpu_pct))

    def test_auxiliary_sensor_limits(self):
        s, a = step(State(100, 100, 20), sample(1, 44000, battery_dc=440))
        self.assertEqual((20, 10), (s.frequency_pct, s.cpu_pct))

    def test_fault_latches_missing_invalid_or_reordered(self):
        initial = State(80, 80, 20)
        good, _ = step(initial, sample(5, 44000))
        for bad in (None, sample(4, 44000), sample(6, 0),
                    sample(6, 44000, ms=1)):
            s, a = step(good, bad)
            self.assertEqual(("QUIESCE_FAULT", "fault", 10), (a, s.pause, s.cpu_pct))
            s, a = step(s, sample(9, 44000))
            self.assertEqual("QUIESCE_FAULT", a)

    def test_duplicate_cannot_ramp_and_fast_samples_respect_dwell(self):
        s, _ = step(State(40, 40, 20), sample(1, 44000))
        same = sample(1, 44000)
        for _ in range(20):
            s, a = step(s, same)
            self.assertEqual("NO_NEW_SAMPLE", a)
        for i in range(2, 30):
            s, _ = step(s, sample(i, 44000, ms=1000+i))
        self.assertEqual((40, 40), (s.frequency_pct, s.cpu_pct))

    def test_no_forced_warming_and_no_fixed_frequency(self):
        s, a = step(State(100, 100, 20), sample(1, 20000))
        self.assertEqual((100, 100), (s.frequency_pct, s.cpu_pct))
        self.assertEqual("COOL", a)


if __name__ == "__main__":
    unittest.main()
