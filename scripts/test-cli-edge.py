"""Regression checks for CLI failure, signal, logging, diagnostics, and ignore edges.

All brew/curl commands are local stubs. The script never contacts Homebrew or
the network and each run gets an isolated HOME and TMPDIR.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "brew-ua"


BREW_STUB = r'''#!/usr/bin/env python3
import json, os, subprocess, sys, time
from pathlib import Path

args = sys.argv[1:]
case = os.environ.get("BREW_UA_TEST_CASE", "")
home = Path(os.environ["HOME"])
state = Path(os.environ["BREW_UA_TEST_STATE"])
state.mkdir(parents=True, exist_ok=True)
with (state / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps(args) + "\n")

def output(name, default=""):
    value = os.environ.get(name, default)
    if value:
        print(value)

if not args:
    sys.exit(0)
if args[0] == "update":
    if case == "update-fail":
        print("stub update failed", file=sys.stderr)
        sys.exit(23)
    sys.exit(0)
if args[0] == "outdated":
    if case == "formula-query-fail" and "--formula" in args:
        print("stub formula query failed", file=sys.stderr)
        sys.exit(42)
    if case == "cask-query-fail" and "--cask" in args:
        print("stub cask query failed", file=sys.stderr)
        sys.exit(43)
    if "--formula" in args:
        output("BREW_UA_TEST_FORMULAE", "fake-a\nfake-b")
    elif "--cask" in args:
        output("BREW_UA_TEST_CASKS", "fake-a\nfake-b")
    sys.exit(0)
if args[0] == "--cache":
    print(str(home / "cache" / "stub-cache.tar.gz"))
    sys.exit(0)
if args[0] == "--version":
    print("Homebrew TEST")
    sys.exit(0)
if args[0] == "fetch":
    if case == "tap-fetch-fail" and args[-1] == "owner/tap/tool":
        print("stub tapped formula fetch failed", file=sys.stderr)
        sys.exit(9)
    if case == "cancel-download":
        (state / "fetch-started").write_text(str(os.getpid()))
        code = (
            "import os,signal,time; from pathlib import Path; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "signal.signal(signal.SIGHUP, signal.SIG_IGN); time.sleep(1.2); "
            f"Path({str(state / 'fetch-finished')!r}).write_text('descendant survived cancellation')"
        )
        child = subprocess.Popen([sys.executable, "-c", code])
        (state / "fetch-child.pid").write_text(str(child.pid))
        time.sleep(30)
    sys.exit(0)
if args[0] == "upgrade":
    name = args[-1]
    if case == "cancel-install" and name == "first":
        time.sleep(0.2)
        (state / "install-started").write_text(str(os.getpid()))
        time.sleep(0.8)
        (state / "install-finished").write_text(name)
    if case == "install-fail":
        print("stub install failed", file=sys.stderr)
        sys.exit(7)
    sys.exit(0)
if args[0] == "reinstall":
    sys.exit(0)
if args[0] == "cleanup":
    if case == "cleanup-fail" and len(args) == 1:
        print("stub cleanup failed", file=sys.stderr)
        sys.exit(8)
    sys.exit(0)
if args[0] == "tap":
    sys.exit(0)
sys.exit(0)
'''


CURL_STUB = r'''#!/usr/bin/env python3
import sys
args = sys.argv[1:]
if "https://ipinfo.io/country" in args:
    print("US")
elif "--write-out" in args or "-w" in args:
    print("0.10,200", end="")
sys.exit(0)
'''


class CLIRegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="brew-ua-edge-")
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.tempdir = self.base / "tmp"
        self.bin = self.base / "bin"
        self.state = self.base / "state"
        for path in (self.home, self.tempdir, self.bin, self.state):
            path.mkdir()
        self._write_executable(self.bin / "brew", BREW_STUB)
        self._write_executable(self.bin / "curl", CURL_STUB)

    def tearDown(self):
        child_pid_file = self.state / "fetch-child.pid"
        if child_pid_file.exists():
            try:
                os.kill(int(child_pid_file.read_text()), signal.SIGKILL)
            except (ProcessLookupError, ValueError):
                pass
        self.temp.cleanup()

    @staticmethod
    def _write_executable(path: Path, contents: str):
        path.write_text(contents)
        path.chmod(0o755)

    def env(self, case="", **extra):
        env = {
            "PATH": f"{self.bin}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home),
            "TMPDIR": str(self.tempdir),
            "BREW_UA_TEST_CASE": case,
            "BREW_UA_TEST_STATE": str(self.state),
            "BREW_UA_FETCH_TIMEOUT": "3",
            "LANG": "C.UTF-8",
        }
        env.update({key: str(value) for key, value in extra.items()})
        return env

    def run_cli(self, args, *, case="", input_text=None, extra=None, env=None):
        merged = self.env(case, **(extra or {})) if env is None else env
        return subprocess.run(
            ["zsh", str(CLI), *args],
            input=input_text,
            text=True,
            capture_output=True,
            timeout=15,
            env=merged,
        )

    def calls(self):
        path = self.state / "calls.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]

    def test_temp_directory_failure_stops_without_fallback_cleanup_or_brew(self):
        self._write_executable(self.bin / "mktemp", "#!/bin/sh\nexit 1\n")
        result = self.run_cli(["f", "auto"])
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("无法创建本次运行的临时目录", result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertEqual(list(self.tempdir.iterdir()), [])

    def test_update_failure_stops_before_queries_and_package_operations(self):
        result = self.run_cli(["f", "auto"], case="update-fail")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("brew update 失败，已停止升级流程", result.stderr)
        self.assertEqual(self.calls(), [["update"]])

    def test_formula_query_failure_is_not_reported_as_empty(self):
        result = self.run_cli(["f", "auto"], case="formula-query-fail")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("查询过期 formula 失败", result.stderr)
        self.assertNotIn("所有包已是最新", result.stdout)
        self.assertEqual(self.calls(), [["update"], ["outdated", "--formula", "--quiet"]])

    def test_cask_query_failure_is_not_reported_as_empty(self):
        result = self.run_cli(["c", "auto"], case="cask-query-fail")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("查询过期 cask 失败", result.stderr)
        self.assertNotIn("所有包已是最新", result.stdout)
        self.assertEqual(self.calls(), [["update"], ["outdated", "--cask", "--quiet"]])

    def test_full_tap_formula_uses_safe_log_path_and_fetches_dependencies(self):
        result = self.run_cli(
            ["f", "auto"],
            extra={"BREW_UA_TEST_FORMULAE": "owner/tap/tool"},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertIn(["fetch", "--formula", "--deps", "owner/tap/tool"], calls)
        self.assertIn(["upgrade", "--formula", "owner/tap/tool"], calls)
        index = next(self.tempdir.glob("brew-ua.*/log-index.tsv")).read_text().splitlines()
        self.assertTrue(any(line.startswith("formula\towner/tap/tool\t") for line in index))
        logged_path = Path(index[0].split("\t", 2)[2])
        self.assertEqual(logged_path.parent.name.startswith("brew-ua."), True)
        self.assertNotIn("/owner/tap/", str(logged_path))

    def test_full_tap_fetch_failure_reports_the_safe_kind_specific_log(self):
        result = self.run_cli(
            ["f", "auto"],
            case="tap-fetch-fail",
            extra={"BREW_UA_TEST_FORMULAE": "owner/tap/tool"},
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("formula: owner/tap/tool", result.stdout)
        index = next(self.tempdir.glob("brew-ua.*/log-index.tsv"))
        row = index.read_text().strip().split("\t", 2)
        self.assertEqual(row[:2], ["formula", "owner/tap/tool"])
        self.assertTrue(Path(row[2]).is_file())
        self.assertNotIn("/owner/tap/", row[2])
        self.assertIn(row[2], result.stdout)

    def test_cask_fetch_never_receives_formula_dependency_flag(self):
        result = self.run_cli(["c", "auto"], extra={"BREW_UA_TEST_CASKS": "owner/tap/app"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertIn(["fetch", "--cask", "owner/tap/app"], calls)
        self.assertFalse(any(call[0] == "fetch" and "--deps" in call for call in calls))

    def test_same_name_formula_and_cask_keep_distinct_logs_and_operations(self):
        result = self.run_cli(
            ["auto"],
            extra={"BREW_UA_TEST_FORMULAE": "dual", "BREW_UA_TEST_CASKS": "dual"},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertIn(["fetch", "--formula", "--deps", "dual"], calls)
        self.assertIn(["fetch", "--cask", "dual"], calls)
        self.assertIn(["upgrade", "--formula", "dual"], calls)
        self.assertIn(["reinstall", "--cask", "dual"], calls)
        index = next(self.tempdir.glob("brew-ua.*/log-index.tsv"))
        rows = [line.split("\t", 2) for line in index.read_text().splitlines()]
        self.assertEqual({row[0] for row in rows}, {"formula", "cask"})
        self.assertEqual(len({Path(row[2]).name for row in rows}), 2)

    def test_eof_cancels_instead_of_selecting_everything(self):
        result = self.run_cli(["f"], input_text="")
        self.assertEqual(result.returncode, 130, result.stdout + result.stderr)
        self.assertIn("输入已关闭，已取消升级", result.stdout)
        self.assertFalse(any(call[0] in {"fetch", "upgrade", "reinstall"} for call in self.calls()))

    def test_signal_cancels_fetch_process_group(self):
        output_path = self.base / "cancel-download.log"
        with output_path.open("w") as output:
            process = subprocess.Popen(
                ["zsh", str(CLI), "f", "auto"],
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.STDOUT,
                env=self.env("cancel-download", BREW_UA_TEST_FORMULAE="fake-a"),
                start_new_session=True,
            )
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline and not (self.state / "fetch-started").exists():
                if process.poll() is not None:
                    break
                time.sleep(0.05)
            self.assertTrue((self.state / "fetch-started").exists(), output_path.read_text())
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=5), 130, output_path.read_text())
        time.sleep(1.3)
        self.assertFalse((self.state / "fetch-finished").exists(), "TERM/HUP-ignoring fetch descendant survived cancellation")
        self.assertFalse(any(call[0] in {"upgrade", "reinstall"} for call in self.calls()))

    def test_signal_waits_for_current_install_then_stops_queue(self):
        output_path = self.base / "cancel-install.log"
        with output_path.open("w") as output:
            process = subprocess.Popen(
                ["zsh", str(CLI), "f", "auto"],
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.STDOUT,
                env=self.env("cancel-install", BREW_UA_TEST_FORMULAE="first\nsecond"),
                start_new_session=True,
            )
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline and not (self.state / "install-started").exists():
                if process.poll() is not None:
                    break
                time.sleep(0.05)
            self.assertTrue((self.state / "install-started").exists(), output_path.read_text())
            os.killpg(process.pid, signal.SIGINT)
            self.assertEqual(process.wait(timeout=5), 130, output_path.read_text())
        self.assertTrue((self.state / "install-finished").exists(), "current installation was interrupted")
        upgrades = [call[-1] for call in self.calls() if call and call[0] == "upgrade"]
        self.assertEqual(upgrades, ["first"])
        self.assertIn("等待当前包安全完成", output_path.read_text())

    def test_ignore_format_type_matching_and_atomic_write(self):
        result = self.run_cli(["ig", "shared"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_cli(["ig", "--formula", "shared"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_cli(["ig", "owner/tap/exact"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_cli(["ig", "--formula", "owner/tap/exact"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        config = self.home / ".config/brew-ua/ignored_casks"
        self.assertEqual(
            set(config.read_text().splitlines()),
            {"shared", "formula:shared", "owner/tap/exact", "formula:owner/tap/exact"},
        )
        self.assertFalse(list(config.parent.glob(".ignored_casks.*")))

        result = self.run_cli(
            ["f", "auto"],
            extra={"BREW_UA_TEST_FORMULAE": "owner/one/shared\nowner/tap/exact\nother/tap/exact"},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        formula_fetches = [call[-1] for call in self.calls() if call and call[0] == "fetch"]
        self.assertEqual(formula_fetches, ["other/tap/exact"])

        # The same untyped legacy rule applies to casks only; formula rules stay type scoped.
        self.setUp_cask_only_state(config)
        self.state.joinpath("calls.jsonl").unlink(missing_ok=True)
        result = self.run_cli(
            ["c", "auto"],
            extra={"BREW_UA_TEST_CASKS": "owner/one/shared\nowner/tap/exact\nother/tap/exact"},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        cask_fetches = [call[-1] for call in self.calls() if call and call[0] == "fetch"]
        self.assertEqual(cask_fetches, ["other/tap/exact"])

        result = self.run_cli(["uig", "--formula", "shared"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = config.read_text().splitlines()
        self.assertIn("shared", lines)
        self.assertNotIn("formula:shared", lines)

    def setUp_cask_only_state(self, config):
        config.write_text("shared\nowner/tap/exact\nformula:shared\nformula:owner/tap/exact\n")

    def test_diagnostics_work_without_optional_environment_variables(self):
        env = self.env()
        for key in (
            "http_proxy", "https_proxy", "ALL_PROXY", "HOMEBREW_NO_AUTO_UPDATE",
            "HOMEBREW_BOTTLE_DOMAIN", "HOMEBREW_CORE_GIT_REMOTE",
        ):
            env.pop(key, None)
        network = self.run_cli(["ck", "-n"], env=env)
        local = self.run_cli(["ck", "-l"], env=env)
        self.assertEqual(network.returncode, 0, network.stdout + network.stderr)
        self.assertEqual(local.returncode, 0, local.stdout + local.stderr)
        self.assertIn("代理设置", network.stdout)
        self.assertIn("本地配置检测", local.stdout)

    def test_cleanup_failure_is_reported_and_returns_nonzero(self):
        result = self.run_cli(["f", "auto"], case="cleanup-fail", extra={"BREW_UA_TEST_FORMULAE": "fake-a"})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("brew cleanup 失败", result.stderr)
        self.assertNotIn("全部完成！", result.stdout)

    def test_ignore_write_failures_are_nonzero_and_not_reported_as_duplicate_or_absent(self):
        ignore_file = self.home / ".config/brew-ua/ignored_casks"
        ignore_file.parent.mkdir(parents=True)
        ignore_file.mkdir()
        result = self.run_cli(["ig", "new-cask"])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("无法写入屏蔽列表", result.stderr)
        self.assertNotIn("已经在屏蔽列表中", result.stdout)
        result = self.run_cli(["uig", "old-cask"])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("无法更新屏蔽列表", result.stderr)
        self.assertNotIn("不在屏蔽列表中", result.stdout)

    def test_atomic_ignore_temp_creation_failure_preserves_existing_file(self):
        config = self.home / ".config/brew-ua/ignored_casks"
        config.parent.mkdir(parents=True)
        config.write_text("existing-cask\n")
        real_mktemp = "/usr/bin/mktemp"
        wrapper = "#!/bin/sh\ncase \"$1\" in *ignored_casks*) exit 1;; esac\nexec " + real_mktemp + " \"$@\"\n"
        self._write_executable(self.bin / "mktemp", wrapper)
        result = self.run_cli(["ig", "new-cask"])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("无法写入屏蔽列表", result.stderr)
        self.assertEqual(config.read_text(), "existing-cask\n")
        self.assertFalse(list(config.parent.glob(".ignored_casks.*")))

    def test_release_tag_fixture_selects_highest_valid_semver_and_refuses_downgrade(self):
        selector = ROOT / "scripts/release-tags.py"
        fixture = ROOT / "scripts/fixtures/release-tags.txt"
        selected = subprocess.run(
            ["python3", str(selector), "select"],
            input=fixture.read_text(),
            text=True,
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(selected.returncode, 0, selected.stderr)
        self.assertEqual(selected.stdout.strip(), "v1.10.0")
        compare = subprocess.run(
            ["python3", str(selector), "compare", "v1.10.0-beta.10", "v1.10.0-beta.2"],
            text=True,
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(compare.returncode, 0, compare.stderr)
        self.assertEqual(compare.stdout.strip(), "1")
        build_tag = subprocess.run(
            ["python3", str(selector), "compare", "v1.10.0+build.5", "v1.10.0"],
            text=True,
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(build_tag.returncode, 0, build_tag.stderr)
        self.assertEqual(build_tag.stdout.strip(), "0")
        older = subprocess.run(
            ["python3", str(selector), "require-not-older", "v1.9.0", "v1.10.0"],
            text=True,
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(older.returncode, 1)
        self.assertIn("refusing Formula downgrade", older.stderr)

    def test_sync_workflow_checks_out_selector_and_targets_real_github_main(self):
        sync_workflow = (ROOT / ".github/workflows/sync-from-cnb.yml").read_text()
        bump_workflow = (ROOT / ".github/workflows/bump-formula-on-tag.yml").read_text()
        checkout = sync_workflow.index("uses: actions/checkout@v4")
        selector = sync_workflow.index("RELEASE_TAG_SELECTOR: ${{ github.workspace }}/scripts/release-tags.py")
        self.assertLess(checkout, selector)
        self.assertTrue((ROOT / "scripts/release-tags.py").is_file())
        self.assertIn("git ls-remote github refs/heads/main", sync_workflow)
        self.assertIn("latest_version_tag=", sync_workflow)
        self.assertIn("dispatch_workflow bump-formula-on-tag.yml", sync_workflow)
        self.assertIn("actions: write", sync_workflow)
        self.assertIn("ref: main", bump_workflow)
        self.assertIn("RELEASE_TAG_SELECTOR: ${{ github.workspace }}/scripts/release-tags.py", bump_workflow)
        self.assertIn('compare "$TAG" "$TAG"', bump_workflow)
        self.assertIn('require-not-older "$TAG" "$CURRENT_TAG"', bump_workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
