"""Pure offline reference for OneOS P0 thermal-guard state semantics.

NOT deployed or used by the Android/OneOS switcher. Python is not the
production runtime. Limits in tests are HYPOTHETICAL FIXTURES, NOT firmware
limits. Do not use simulator results to authorize a physical takeover.
"""

from dataclasses import dataclass
from enum import Enum


class State(str, Enum):
    MONITORING = "MONITORING"
    WARNING = "WARNING"
    RETURN_REQUESTED = "RETURN_REQUESTED"
    FAIL_CLOSED = "FAIL_CLOSED"


@dataclass(frozen=True)
class Limits:
    # Values in deci-degrees, must be calibrated by firmware evidence.
    lrp_warn: int
    lrp_critical: int
    battery_warn: int
    battery_critical: int
    board_ap_warn: int
    board_ap_critical: int
    hysteresis: int
    warning_dwell_ms: int
    max_sample_age_ms: int

    def __post_init__(self):
        for name in ("lrp", "battery", "board_ap"):
            warn = getattr(self, f"{name}_warn")
            critical = getattr(self, f"{name}_critical")
            if type(warn) is not int or type(critical) is not int or not (100 <= warn < critical <= 1200):
                raise ValueError(f"invalid {name} thresholds")
        if type(self.hysteresis) is not int or not (0 < self.hysteresis <= 100):
            raise ValueError("invalid hysteresis")
        if type(self.warning_dwell_ms) is not int or not (0 < self.warning_dwell_ms <= 120000):
            raise ValueError("invalid warning dwell")
        if type(self.max_sample_age_ms) is not int or not (0 < self.max_sample_age_ms <= 30000):
            raise ValueError("invalid age bound")


class Monitor:
    """Pure monotonic one-run state, with terminal fail-closed events."""

    def __init__(self, *, boot_id: str, generation: str, limits: Limits):
        if not boot_id or not generation or len(generation) > 160:
            raise ValueError("missing or invalid trusted session identity")
        self.boot_id = boot_id
        self.generation = generation
        self.limits = limits
        self.state = State.MONITORING
        self.reason = "initialized"
        self.warning_since_ms = None
        self.cool_since_ms = None
        self.last_now_ms = None
        self.last_sample_ms = None

    def _terminal(self, state, reason):
        self.state = state
        self.reason = reason
        return state

    def update(self, *, now_ms, sample, observed_boot_id, observed_generation,
               watcher_alive=True):
        if self.state in (State.RETURN_REQUESTED, State.FAIL_CLOSED):
            return self.state
        if observed_boot_id != self.boot_id or observed_generation != self.generation:
            return self._terminal(State.FAIL_CLOSED, "stale boot or run generation")
        if not watcher_alive:
            return self._terminal(State.FAIL_CLOSED, "independent return watcher missing")
        if type(now_ms) is not int or now_ms < 0:
            return self._terminal(State.FAIL_CLOSED, "invalid monotonic clock")
        if self.last_now_ms is not None and now_ms < self.last_now_ms:
            return self._terminal(State.FAIL_CLOSED, "monotonic time reversed")
        self.last_now_ms = now_ms
        if not isinstance(sample, dict):
            return self._terminal(State.FAIL_CLOSED, "missing sample")
        sampled_ms = sample.get("sampled_ms")
        if (type(sampled_ms) is not int or sampled_ms < 0 or sampled_ms > now_ms
                or now_ms - sampled_ms > self.limits.max_sample_age_ms):
            return self._terminal(State.FAIL_CLOSED, "stale, future or invalid sample time")
        if self.last_sample_ms is not None and sampled_ms <= self.last_sample_ms:
            return self._terminal(State.FAIL_CLOSED, "replayed sample time")
        self.last_sample_ms = sampled_ms
        fields = ("lrp", "battery", "board_ap")
        values = {}
        for name in fields:
            v = sample.get(name)
            if type(v) is not int or not (0 < v <= 1200):
                return self._terminal(State.FAIL_CLOSED, f"unknown or invalid {name}")
            values[name] = v
        for name in fields:
            if values[name] >= getattr(self.limits, name + "_critical"):
                return self._terminal(State.RETURN_REQUESTED, f"critical {name}")
        warning = any(values[name] >= getattr(self.limits, name + "_warn")
                      for name in fields)
        cooled = all(values[name] < getattr(self.limits, name + "_warn")
                     - self.limits.hysteresis for name in fields)
        if self.state is State.MONITORING:
            if warning:
                if self.warning_since_ms is None:
                    self.warning_since_ms = now_ms
                if now_ms - self.warning_since_ms >= self.limits.warning_dwell_ms:
                    self.state = State.WARNING
                    self.reason = "sustained warning"
                    self.cool_since_ms = None
            else:
                self.warning_since_ms = None
        elif self.state is State.WARNING:
            if cooled:
                if self.cool_since_ms is None:
                    self.cool_since_ms = now_ms
                if now_ms - self.cool_since_ms >= self.limits.warning_dwell_ms:
                    self.state = State.MONITORING
                    self.reason = "cooled with hysteresis"
                    self.warning_since_ms = None
            else:
                self.cool_since_ms = None
        return self.state
