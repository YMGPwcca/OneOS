#!/usr/bin/env python3
"""Exercise the actual raw sampler + stock controller with fixture sysfs.
The binary must be compiled with ONEIOS_RAW_SOURCE_TEST.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="oneios-stock-source.") as directory:
    root = Path(directory)
    def put(rel, value):
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(value)
        p.chmod(0o600)
    boot = "51ca8a7b-7fe0-4075-be5f-6a9029b8d392"
    put("proc/sys/kernel/random/boot_id", boot + "\n")
    manifest = f"v1 {boot} 4\n"
    for idx, kind, group, temp in [(1,"cpu-0","cpu",41000),(2,"cpu-1","cpu",45000),
                                   (3,"gpuss-0","gpu",42000),(4,"ddr","ddr",40000)]:
        manifest += f"z {idx} {kind} {group}\n"
        put(f"sys/class/thermal/thermal_zone{idx}/type", kind + "\n")
        put(f"sys/class/thermal/thermal_zone{idx}/temp", str(temp) + "\n")
    put("data/adb/oneios-m3q-framework/thermal.guard.manifest", manifest)
    put("sys/class/power_supply/battery/temp","300\n")
    put("sys/class/power_supply/battery/lrp","300\n")
    put("sys/class/sec/sec-ap-thermistor/temperature","400\n")
    subprocess.run([str(Path(sys.argv[1]).resolve()),"--source-fixture",directory],
                   check=True,timeout=10,stdin=subprocess.DEVNULL)
