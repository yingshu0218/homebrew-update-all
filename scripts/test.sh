#!/bin/zsh
# ============================================================
#  brew-ua 冒烟测试 — stub brew + 伪终端 + 断言
#  用法: zsh scripts/test.sh
#  覆盖: 速度显示 / 包大小 / 两阶段顺序 / 失败隔离 / 超时 / 非TTY
# ============================================================

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/brew-ua-test.XXXXXX)"
PASS=0
FAIL=0

# ---------- stub brew ----------
cat > "$WORK/brew" <<'EOF'
#!/bin/zsh
echo "$(date +%s%3N) $*" >> "$HOME/call.log"
case "$1" in
  update) sleep 0.2; exit 0 ;;
  outdated) echo -e "fake-a\nfake-b"; exit 0 ;;
  fetch)
    if [ -n "$STUB_HANG_NAME" ] && [ "$3" = "$STUB_HANG_NAME" ]; then
      echo "hang start"; while true; do sleep 1; done
    fi
    if [ -n "$STUB_FAIL_NAME" ] && [ "$3" = "$STUB_FAIL_NAME" ]; then
      echo "fail start"; sleep 0.4; exit 1
    fi
    local i pct mb frac
    for i in {1..30}; do
      pct=$((i * 3)); mb=$((pct * 10 / 100)); frac=$(( (pct * 10 * 10 / 100) % 10 ))
      printf '\rCask %s (1.0)                    Downloading   %d.%dMB/ 10.0MB' "$3" "$mb" "$frac"
      sleep 0.06
    done
    printf '\rCask %s (1.0)                    Downloading  10.0MB/ 10.0MB\n' "$3"
    exit 0 ;;
  reinstall) sleep 0.3; exit 0 ;;
  upgrade) sleep 0.3; exit 0 ;;
  cleanup) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/brew"

# ---------- 工具 ----------
run_ua() { # run_ua <logfile> [env vars...]
  local log=$1; shift
  env "$@" HOME="$WORK/home" PATH="$WORK:/opt/homebrew/bin:/usr/bin:/bin" \
    /usr/bin/script -q /dev/null zsh "$ROOT/brew-ua" c auto > "$log" 2>&1
}

run_ua_notty() { # 非 TTY：直接管道，无 script 伪终端
  local log=$1; shift
  env "$@" HOME="$WORK/home" PATH="$WORK:/opt/homebrew/bin:/usr/bin:/bin" \
    zsh "$ROOT/brew-ua" c auto > "$log" 2>&1
}

check() { # check <desc> <cond...>
  if eval "$2"; then
    echo "  ✓ $1"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $1"
    FAIL=$((FAIL + 1))
  fi
}

mkdir -p "$WORK/home"

# ========== 场景 1：两阶段正常流程 ==========
echo "[场景 1] 两阶段正常流程（速度/大小/顺序/完成）"
rm -f "$WORK/home/call.log"
run_ua "$WORK/s1.log"
RC=$?
OUT=$(tr -d '\r' < "$WORK/s1.log")
STRIP=$(echo "$OUT" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')
check "速度显示 (MB/s)" "echo \"\$OUT\" | grep -qE '下载中[^|]*[0-9.]+(MB|KB)/s'"
check "包大小解析 (· 10.0MB)" "echo \"\$OUT\" | grep -q '· 10.0MB'"
check "两阶段顺序 (fetch 全在 reinstall 前)" \
  "F=\$(grep -n ' fetch ' \"\$WORK/home/call.log\" | tail -1 | cut -d: -f1); R=\$(grep -n ' reinstall ' \"\$WORK/home/call.log\" | head -1 | cut -d: -f1); [ -n \"\$F\" ] && [ -n \"\$R\" ] && [ \"\$F\" -lt \"\$R\" ]"
check "2 个包升级完成" "echo \"\$OUT\" | grep -c '升级完成' | grep -q '^2$'"
check "阶段1 汇总帧" "echo \"\$OUT\" | grep -q '下载完成'"
check "退出码 0" "[ \"\$RC\" -eq 0 ]"
check "统计摘要 (成功2/失败0)" "echo \"\$STRIP\" | grep -q '成功:  2 个' && echo \"\$STRIP\" | grep -q '失败:  0 个'"

# ========== 场景 2：超时机制 ==========
echo "[场景 2] 下载超时（BUO 卡死缺陷的防护）"
rm -f "$WORK/home/call.log"
run_ua "$WORK/s2.log" STUB_HANG_NAME=fake-a BREW_UA_FETCH_TIMEOUT=2
RC=$?
OUT=$(tr -d '\r' < "$WORK/s2.log")
check "卡住的包标记下载超时" "echo \"\$OUT\" | grep -q '下载超时'"
check "其余包正常完成" "echo \"\$OUT\" | grep -c '升级完成' | grep -q '^1$'"
check "失败使退出码为 1" "[ \"\$RC\" -eq 1 ]"

# ========== 场景 3：失败隔离 ==========
echo "[场景 3] 下载失败隔离（失败包跳过安装，其余继续）"
rm -f "$WORK/home/call.log"
run_ua "$WORK/s3.log" STUB_FAIL_NAME=fake-a
OUT=$(tr -d '\r' < "$WORK/s3.log")
check "失败的包无安装调用" "! grep -q 'reinstall --cask fake-a' \"\$WORK/home/call.log\""
check "成功包正常安装" "grep -q 'reinstall --cask fake-b' \"\$WORK/home/call.log\""
check "失败计入统计" "echo \"\$OUT\" | grep -q '下载失败'"

# ========== 场景 4：formula 两阶段 ==========
echo "[场景 4] formula 走 --formula fetch（非 cask 分支）"
rm -f "$WORK/home/call.log"
env "$@" HOME="$WORK/home" PATH="$WORK:/opt/homebrew/bin:/usr/bin:/bin" \
  /usr/bin/script -q /dev/null zsh "$ROOT/brew-ua" f auto > "$WORK/s4.log" 2>&1
check "fetch 使用 --formula" "grep -q 'fetch --formula fake-a' \"\$WORK/home/call.log\""

# ========== 场景 5：非 TTY 无 ANSI ==========
echo "[场景 5] 非 TTY 输出无 ANSI 控制符"
rm -f "$WORK/home/call.log"
run_ua_notty "$WORK/s5.log"
check "无 \\x1b 控制符" "! grep -q $'\x1b' \"\$WORK/s5.log\""

echo ""
echo "===== 结果: $PASS 通过 / $FAIL 失败 ====="
rm -rf "$WORK"
(( FAIL == 0 )) && exit 0 || exit 1
