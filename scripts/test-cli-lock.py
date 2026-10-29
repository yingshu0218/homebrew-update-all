"""Exercise the CLI's actual lock block without running Homebrew."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class CLILockTests(unittest.TestCase):
    def test_concurrent_start_and_crash_release(self):
        source = (Path(__file__).resolve().parent.parent / "brew-ua").read_text()
        start = source.index('LOCK_FILE="$HOME/.config/brew-ua/brew-ua.lock"')
        block = source[start:source.index("\ntotal_start=", start)]
        with tempfile.TemporaryDirectory(prefix="brewua-lock-test-") as directory:
            env = dict(os.environ, HOME=directory)
            holder = subprocess.Popen(
                ["zsh", "-fc", block + '\necho LOCKED\nread -r reply'],
                env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
            )
            try:
                self.assertEqual(holder.stdout.readline().strip(), "LOCKED")
                competitors = [subprocess.Popen(
                    ["zsh", "-fc", block], env=env,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                ) for _ in range(8)]
                for process in competitors:
                    out, err = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 1, out + err)
                    self.assertIn("已有 brew-ua 实例", out)
                holder.kill()
                holder.wait(timeout=5)
                result = subprocess.run(["zsh", "-fc", block], env=env,
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            finally:
                if holder.poll() is None:
                    holder.kill()
                    holder.wait(timeout=5)
                holder.stdin.close()
                holder.stdout.close()


if __name__ == "__main__":
    unittest.main()
