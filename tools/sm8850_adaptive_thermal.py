"""SM8850 adaptive thermal policy reference; pure offline logic, NO device I/O.

Inputs are independently validated, generation-pinned sensor snapshots.
Outputs are requests to a future qualified owned actuator, NOT sysfs writes.
No action returned by this module requests a reboot or return to Android.
"""
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    frequency_pct: int
    cpu_pct: int
    frequency_floor_pct: int
    hard: bool = False
    pause: str = ""
    cool_samples: int = 0
    last_seq: int = 0
    last_ms: int = -1
    last_change_ms: int = -1

    def __post_init__(self):
        if not (10 <= self.frequency_floor_pct <= self.frequency_pct <= 100
                and 10 <= self.cpu_pct <= 100):
            raise ValueError("initial budgets must be explicit qualified values")
        if self.pause not in ("", "temperature", "fault"):
            raise ValueError("invalid pause latch")


@dataclass(frozen=True)
class Sample:
    seq: int
    ms: int
    cpu_mc: int
    gpu_mc: int
    ddr_mc: int
    battery_dc: int
    lrp_dc: int
    board_ap_dc: int


def valid(sample):
    if not isinstance(sample, Sample):
        return False
    if any(type(x) is not int for x in vars(sample).values()):
        return False
    return (sample.seq > 0 and sample.ms >= 0
            and all(0 < x <= 200000 for x in
                    (sample.cpu_mc, sample.gpu_mc, sample.ddr_mc))
            and all(0 < x <= 1500 for x in
                    (sample.battery_dc, sample.lrp_dc, sample.board_ap_dc)))


def step(state, sample):
    """Return (new state, action). QUIESCE is a request, not a proof of pause.

    Duplicate/replayed, out-of-order and missing samples cannot authorize
    an increase. A fault latch requires a new explicitly validated session;
    a temperature latch may recover only after five cool samples and 5 s.
    The caller must separately reject stale heartbeats using its own clock.
    """
    if state.pause == "fault" or not valid(sample):
        return replace(state, frequency_pct=state.frequency_floor_pct,
                       cpu_pct=10, hard=True, pause="fault",
                       cool_samples=0), "QUIESCE_FAULT"
    if sample.seq < state.last_seq or sample.ms < state.last_ms:
        return replace(state, frequency_pct=state.frequency_floor_pct,
                       cpu_pct=10, hard=True, pause="fault",
                       cool_samples=0), "QUIESCE_FAULT"
    if sample.seq == state.last_seq:
        return state, "NO_NEW_SAMPLE"
    s = replace(state, last_seq=sample.seq, last_ms=sample.ms)
    if s.last_change_ms < 0:
        s = replace(s, last_change_ms=sample.ms)
    peak = max(sample.cpu_mc, sample.gpu_mc, sample.ddr_mc)
    emergency = (sample.cpu_mc >= 90000 or sample.gpu_mc >= 95000
                 or sample.ddr_mc >= 95000 or sample.battery_dc >= 480
                 or sample.lrp_dc >= 500 or sample.board_ap_dc >= 700)
    # Preserve conservative auxiliary sensor limits from the former guard.
    aux = 100
    for battery, lrp, board, limit in ((340, 370, 450, 40),
                                      (370, 400, 500, 28),
                                      (400, 430, 550, 18),
                                      (420, 450, 600, 12),
                                      (440, 470, 650, 10)):
        if (sample.battery_dc >= battery or sample.lrp_dc >= lrp
                or sample.board_ap_dc >= board):
            aux = min(aux, limit)
    if emergency:
        return replace(s, frequency_pct=s.frequency_floor_pct, cpu_pct=10,
                       hard=True, pause="temperature", cool_samples=0,
                       last_change_ms=sample.ms), "QUIESCE_TEMPERATURE"
    if s.pause == "temperature":
        cool = peak <= 70000 and aux == 100
        count = min(s.cool_samples + 1, 5) if cool else 0
        if not cool:
            s = replace(s, last_change_ms=sample.ms)
        if count >= 5 and sample.ms - s.last_change_ms >= 5000:
            return replace(s, pause="", hard=False, cool_samples=0,
                           last_change_ms=sample.ms), "RESUME_MINIMUM"
        return replace(s, cool_samples=count), "QUIESCE_TEMPERATURE"
    if peak >= 80000 or (s.hard and peak > 70000):
        return replace(s, frequency_pct=s.frequency_floor_pct, cpu_pct=10,
                       hard=True, cool_samples=0,
                       last_change_ms=sample.ms), "HARD"
    if s.hard:
        return replace(s, hard=False, cool_samples=0,
                       last_change_ms=sample.ms), "RECOVERY_MINIMUM"
    f, q = s.frequency_pct, s.cpu_pct
    count = 0
    if peak >= 70000:
        reduction = 20 if peak >= 75000 else 10
        f, q = max(s.frequency_floor_pct, f-reduction), max(10, q-reduction)
        action = "SOFT"
    elif peak >= 65000:
        action = "HOLD"
    else:
        action = "COOL"
        count = min(s.cool_samples+1, 5)
        if count >= 5 and sample.ms - s.last_change_ms >= 5000:
            increase = 10 if peak < 45000 else 5
            f, q = min(100, f+increase), min(100, q+increase)
            count = 0
    f, q = min(f, max(s.frequency_floor_pct, aux)), min(q, aux)
    changed = (f, q) != (s.frequency_pct, s.cpu_pct)
    # A decrease/hold/hot observation starts a new cool dwell.
    if action != "COOL" or changed:
        s = replace(s, last_change_ms=sample.ms)
        count = 0
    return replace(s, frequency_pct=f, cpu_pct=q, cool_samples=count), action
