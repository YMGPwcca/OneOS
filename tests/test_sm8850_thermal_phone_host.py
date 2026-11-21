#!/usr/bin/env python3
"""Offline fake-ADB regression for the ONE UI-only 3-sample host collector.

No real phone can be reached: HOME points to a private fake adb executable.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / "scripts/phone/run-sm8850-thermal-shadow-oneui.sh"
BOOT = "123e4567-e89b-12d3-a456-426614174000"
FAKE_ADB = r'''#!/usr/bin/env python3
import hashlib
import os
from pathlib import Path
import shutil
import sys

args=sys.argv[1:]
root=Path(os.environ["MOCK_ADB_ROOT"])
with (root/"calls.log").open("a") as f:
    f.write(repr(args)+"\n")
if args == ["devices"]:
    print("List of devices attached\nMOCK123\tdevice")
    sys.exit(0)
if len(args)<3 or args[:2] != ["-s", "MOCK123"]:
    sys.exit(9)
a=args[2:]
remote=root/"remote"
def mapping(p):
    return remote/p.lstrip("/")
if a[0]=="push" and len(a)==3:
    p=mapping(a[2]);p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(a[1],p)
    print("1 file pushed")
    sys.exit(0)
if a[0]!="shell":
    sys.exit(9)
s=a[1:]
if s[0]=="getprop":
    values={"ro.product.model":"SM-S948B",
        "ro.product.device":"m3q",
        "ro.build.version.incremental":"S948BXXS4BZIG",
        "sys.boot_completed":"1"}
    key=s[1]
    if os.environ.get("MOCK_BAD_MODEL") and key=="ro.product.model":
        print("UNKNOWN")
    else: print(values.get(key,""))
elif s == ["getenforce"]:
    print("Enforcing")
elif s == ["pidof", "system_server"]:
    print("222")
elif s == ["cat", "/proc/sys/kernel/random/boot_id"]:
    print("123e4567-e89b-12d3-a456-426614174000")
elif s[0]=="mkdir":
    mapping(s[1]).mkdir(parents=True)
elif s[0]=="chmod":
    pass
elif s[0]=="sha256sum":
    p=mapping(s[1])
    print(hashlib.sha256(p.read_bytes()).hexdigest()+"  "+s[1])
elif s[:1]==["rm"] and s[1]=="-f":
    for name in s[2:]:
        mapping(name).unlink(missing_ok=True)
elif s[0]=="rmdir":
    mapping(s[1]).rmdir()
elif s[0]=="-T" and s[1].startswith("su -c '"):
    if os.environ.get("MOCK_SU_FAIL"):
        print("mock su access denied",file=sys.stderr)
        sys.exit(1)
    count=int(os.environ.get("MOCK_SAMPLES","3"))
    for i in range(1,count+1):
        print(f"THERMAL_SHADOW=OBSERVED_NOT_GUARD tick={i} boot_id=123e4567-e89b-12d3-a456-426614174000 physical_action=NO")
        print("battery_deci_c=285")
        print("lrp_deci_c=303")
        print("board_ap_deci_c=297")
    print("THERMAL_SHADOW=COMPLETE_UNQUALIFIED samples=3 physical_action=NO")
else:
    print("mock adb unexpected "+repr(s), file=sys.stderr)
    sys.exit(9)
'''


class HostShadowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="p0-shadow-host-mock-")
        self.addCleanup(self.tmp.cleanup)
        self.mock = Path(self.tmp.name)
        adb = self.mock / "Android/Sdk/platform-tools/adb"
        adb.parent.mkdir(parents=True)
        adb.write_text(FAKE_ADB)
        adb.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.mock), MOCK_ADB_ROOT=str(self.mock))

    def call(self, flag, **env):
        config = dict(self.env, **env)
        return subprocess.run(["bash", str(HOST), flag],
                              capture_output=True, text=True, env=config, timeout=12)

    def calls(self):
        file = self.mock / "calls.log"
        return file.read_text() if file.exists() else ""

    def test_audit_is_no_adb_contact(self):
        r=self.call("--audit-only")
        self.assertEqual(0,r.returncode,r.stderr)
        self.assertIn("THERMAL_SHADOW_AUDIT=NO_ADB_CONTACT",r.stdout)
        self.assertEqual("",self.calls())

    def test_wrong_model_blocked_before_staging(self):
        r=self.call("--run-readonly",MOCK_BAD_MODEL="1")
        self.assertNotEqual(0,r.returncode)
        self.assertIn("ro.product.model mismatch",r.stderr)
        self.assertNotIn("push",self.calls())
        self.assertNotIn("P0_SHADOW_ONEUI=PASS",r.stdout)

    def test_three_readings_with_integrity_checks_and_clean_up(self):
        r=self.call("--run-readonly")
        self.assertEqual(0,r.returncode,r.stderr)
        self.assertIn("P0_SHADOW_ONEUI=PASS_READ_ONLY_EVIDENCE_NOT_GUARD",r.stdout)
        self.assertEqual(3,r.stdout.count("THERMAL_SHADOW=OBSERVED_NOT_GUARD"))
        log=self.calls()
        self.assertEqual(2,log.count("'push'"))
        self.assertEqual(2,log.count("'sha256sum'"))
        self.assertIn("'rmdir'",log)
        for forbidden in ("--framework-session", "sys.powerctl", "/dev/watchdog",
                          "'setprop'", "'reboot'", "'kill'"):
            self.assertNotIn(forbidden,log)

    def test_root_refusal_cannot_be_reported_success(self):
        r=self.call("--run-readonly",MOCK_SU_FAIL="1")
        self.assertNotEqual(0,r.returncode)
        self.assertNotIn("P0_SHADOW_ONEUI=PASS",r.stdout)

    def test_short_output_cannot_be_reported_success(self):
        r=self.call("--run-readonly",MOCK_SAMPLES="2")
        self.assertNotEqual(0,r.returncode)
        self.assertIn("missing sample 3",r.stderr)
        self.assertNotIn("P0_SHADOW_ONEUI=PASS",r.stdout)


if __name__=="__main__":
    unittest.main()
