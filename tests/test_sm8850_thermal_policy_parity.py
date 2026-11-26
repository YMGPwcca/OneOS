"""Compare the native pure policy to the existing Python reference.

Usage: python3 tests/test_sm8850_thermal_policy_parity.py /tmp/test-controller
Host fixture executable only. Never invokes adb, sysfs or a live controller.
"""
from pathlib import Path
import random
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from sm8850_adaptive_thermal import Sample, State, step


def run(exe):
    rng = random.Random(8850)
    total = 0
    for trajectory in range(24):
        floor = rng.choice((10, 20, 30, 50))
        state = State(rng.randint(floor, 100), rng.randint(10, 100), floor)
        rows = [f"{state.frequency_pct} {state.cpu_pct} {state.frequency_floor_pct}"]
        expected = []
        now = 0
        seq = 0
        previous = None
        for i in range(360):
            if previous is not None and i % 31 == 0:
                s = previous
            else:
                now += rng.choice((250, 1000, 2000))
                seq += 1
                # Include long cool and hot runs to exercise dwell and latches,
                # mixed auxiliary limits, and exact junction boundaries.
                if i % 90 < 28:
                    v = (44000, 40000, 40000, 300, 300, 400)
                elif i % 90 < 40:
                    v = (80000, 40000, 40000, 300, 300, 400)
                elif i % 90 < 49:
                    v = (90000, 40000, 40000, 300, 300, 400)
                elif i % 90 < 70:
                    v = (65000, 40000, 40000, 300, 300, 400)
                else:
                    v = (
                        rng.choice((44999, 45000, 64999, 65000, 69999, 70000, 70001, 75000, 79999, 80000, 89999, 90000)),
                        rng.choice((40000, 70000, 80000, 95000)),
                        rng.choice((40000, 80000, 95000)),
                        rng.choice((300, 340, 370, 400, 420, 440, 480)),
                        rng.choice((300, 370, 400, 430, 450, 470, 500)),
                        rng.choice((400, 450, 500, 550, 600, 650, 700)),
                    )
                s = Sample(seq, now, *v)
                previous = s
            rows.append(" ".join(str(x) for x in vars(s).values()))
            state, action = step(state, s)
            expected.append(
                f"{action} {state.frequency_pct} {state.cpu_pct} "
                f"{int(state.hard)} {int(state.pause == 'temperature')} "
                f"{state.cool_samples} {state.last_seq} {state.last_ms} {state.last_change_ms}"
            )
        p = subprocess.run([exe, "--policy"], input="\n".join(rows) + "\n",
                           text=True, capture_output=True, check=True, timeout=10)
        actual = p.stdout.splitlines()
        if actual != expected:
            for i, (got, want) in enumerate(zip(actual, expected)):
                if got != want:
                    raise AssertionError(f"trajectory {trajectory}, sample {i}: {got!r} != {want!r}")
            raise AssertionError(f"trajectory {trajectory}: {len(actual)} != {len(expected)}")
        total += len(expected)
    print(f"THERMAL_POLICY_PARITY=PASS samples={total} DEVICE_ACCESS=NONE")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_sm8850_thermal_policy_parity.py HOST_FIXTURE_EXECUTABLE")
    run(str(Path(sys.argv[1]).resolve(strict=True)))
