"""Exercise the real helper with harmless native probes; no debugger required."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ExternalExecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory()
        cls.root = Path(cls.work.name)
        cls.helper = cls.root / "grape-trace-parent"
        cls.probe = cls.root / "Grape" / "probe"
        cls.probe.parent.mkdir()
        source = cls.root / "probe.c"
        source.write_text('#include <stdio.h>\n#include <stdlib.h>\n#include <unistd.h>\n'
            'int main(int argc,char **argv){char path[4096];if(!getcwd(path,sizeof(path)))return 2;'
            'printf("%d\\n%s\\n%s\\n",getpid(),path,getenv("JUICE_LAUNCH_CWD")?:"unset");'
            'for(int i=1;i<argc;i++)puts(argv[i]);return 0;}\n')
        cc = os.environ.get("CC", "clang")
        flags = ["-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror", "-O1"]
        subprocess.run([cc, *flags, str(ROOT / "launcher/grape-trace-parent.c"), "-o", str(cls.helper)], check=True)
        subprocess.run([cc, *flags, str(source), "-o", str(cls.probe)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def launch(self, external="1", jit="1", cwd=None, program=None):
        env = dict(os.environ, JUICE_EXTERNAL_DEBUG_EXEC=external, JUICE_STIKDEBUG_JIT=jit,
                   JUICE_LAUNCH_CWD=str(cwd or self.root))
        return subprocess.Popen([str(self.helper), str(program or self.probe), "space separated", "C:\\folder\\"],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def test_external_exec_preserves_owned_pid_cwd_and_argv(self):
        child = self.launch();out, err = child.communicate(timeout=5)
        self.assertEqual(child.returncode, 0, err)
        self.assertEqual(out.splitlines(), [str(child.pid), str(self.root), "unset", "space separated", "C:\\folder\\"])
        self.assertIn("JUICE_EXTERNAL_DEBUG_EXEC pid=", err)

    def test_default_path_still_owns_a_separate_child(self):
        for external,jit in [("0","1"),("1","0"),("true","1")]:
            child = self.launch(external,jit);out,err = child.communicate(timeout=5)
            self.assertEqual(child.returncode,0,err)
            self.assertNotEqual(int(out.splitlines()[0]),child.pid)
            self.assertNotIn("JUICE_EXTERNAL_DEBUG_EXEC pid=",err)

    def test_exec_failure_is_an_owned_exit(self):
        child=self.launch(program=self.root / "missing");_,err=child.communicate(timeout=5)
        self.assertEqual(child.returncode,71);self.assertIn("exec failed",err)

    def test_bad_cwd_exits_before_launch(self):
        child=self.launch(cwd=self.root / "missing");_,err=child.communicate(timeout=5)
        self.assertEqual(child.returncode,70);self.assertIn("launch cwd failed",err)

if __name__ == "__main__":
    unittest.main()
