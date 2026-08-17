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
CACHE_DIR="$HOME/cache"
mkdir -p "$CACHE_DIR"
case "$1" in
  update) sleep 0.2; exit 0 ;;
  outdated) echo -e "fake-a\nfake-b"; exit 0 ;;
  --cache)
    # 输出 brew-ua 应轮询的缓存路径（下载中 +.incomplete）
    echo "$CACHE_DIR/$3-10.0MB.tmp"
    exit 0 ;;
  fetch)
    if [ -n "$STUB_HANG_NAME" ] && [ "$3" = "$STUB_HANG_NAME" ]; then
      echo "hang start"; while true; do sleep 1; done
    fi
    if [ -n "$STUB_FAIL_NAME" ] && [ "$3" = "$STUB_FAIL_NAME" ]; then
      echo "fail start"; sleep 0.4; exit 1
    fi
    # 真实创建下载缓存文件并逐步增长（模拟 Homebrew 下载写入行为）
    # STUB_INCREMENT_MS 控制每次写入间隔（默认 60ms，场景6 用 200ms 便于观察）
    local inc_ms="${STUB_INCREMENT_MS:-60}"
    local target="$CACHE_DIR/$3-10.0MB.tmp.incomplete"
    local i mb
    for i in {1..30}; do
      mb=$((i * 10 / 30))
      dd if=/dev/zero of="$target" bs=1024 count=$((mb * 1024)) 2>/dev/null
      sleep $((inc_ms / 1000)).$(( (inc_ms % 1000) / 100 ))
    done
    mv "$target" "${target%.incomplete}"
    exit 0 ;;
  reinstall) sleep 0.3; exit 0 ;;
  upgrade) sleep 0.3; exit 0 ;;
  cleanup) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/brew"

# ---------- 工具 ----------
run_ua() { # run_ua <logfile> <filter:c|f> [env vars...]
  local log=$1 filter=$2; shift 2
  if [[ "$(uname -s)" == "Darwin" ]]; then
    env "$@" HOME="$WORK/home" PATH="$WORK:/opt/homebrew/bin:/usr/bin:/bin" \
      /usr/bin/script -q /dev/null zsh "$ROOT/brew-ua" "$filter" auto > "$log" 2>&1
  else
    # Linux util-linux 的 script 语法：-qec "cmd" file；PATH 需含 /usr/local/bin（python3 位置）
    env "$@" HOME="$WORK/home" PATH="$WORK:/usr/local/bin:/usr/bin:/bin" \
      /usr/bin/script -qec "zsh $ROOT/brew-ua $filter auto" /dev/null > "$log" 2>&1
  fi
}

run_ua_notty() { # 非 TTY：直接管道，无 script 伪终端
  local log=$1 filter=$2; shift 2
  env "$@" HOME="$WORK/home" PATH="$WORK:/opt/homebrew/bin:/usr/bin:/bin" \
    zsh "$ROOT/brew-ua" "$filter" auto > "$log" 2>&1
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
run_ua "$WORK/s1.log" c
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
# 超时用 8s：CI runner 上 python3/script/brew 启动链路开销大，
# 2s 会让正常下载的包也误超时；8s 对无限 hang 的 fake-a 仍能触发超时
run_ua "$WORK/s2.log" c STUB_HANG_NAME=fake-a BREW_UA_FETCH_TIMEOUT=8
RC=$?
OUT=$(tr -d '\r' < "$WORK/s2.log")
check "卡住的包标记下载超时" "echo \"\$OUT\" | grep -q '下载超时'"
if echo "$OUT" | grep -c '升级完成' | grep -q '^1$'; then
  echo "  ✓ 其余包正常完成"
  PASS=$((PASS + 1))
else
  echo "  ✗ 其余包正常完成"
  echo "  --- s2.log 尾部（诊断）---"
  tail -15 "$WORK/s2.log" | tr -d '\r'
  echo "  --- call.log（诊断）---"
  cat "$WORK/home/call.log" 2>/dev/null | tail -10
  echo "  --- fake-b.log（诊断）---"
  local tdir=$(echo "$OUT" | grep -oE "${TMPDIR:-/tmp}/brew-ua\.[^/]*" | head -1)
  if [[ -n "$tdir" ]]; then
    echo "  [dir: $tdir]"
    cat "$tdir/fake-b.log" 2>/dev/null | tr -d '\r' | tail -8
  fi
  FAIL=$((FAIL + 1))
fi
check "失败使退出码为 1" "[ \"\$RC\" -eq 1 ]"

# ========== 场景 3：失败隔离 ==========
echo "[场景 3] 下载失败隔离（失败包跳过安装，其余继续）"
rm -f "$WORK/home/call.log"
run_ua "$WORK/s3.log" c STUB_FAIL_NAME=fake-a
OUT=$(tr -d '\r' < "$WORK/s3.log")
check "失败的包无安装调用" "! grep -q 'reinstall --cask fake-a' \"\$WORK/home/call.log\""
check "成功包正常安装" "grep -q 'reinstall --cask fake-b' \"\$WORK/home/call.log\""
check "失败计入统计" "echo \"\$OUT\" | grep -q '下载失败'"

# ========== 场景 4：formula 两阶段 ==========
echo "[场景 4] formula 走 --formula fetch（非 cask 分支）"
rm -f "$WORK/home/call.log"
run_ua "$WORK/s4.log" f
check "fetch 使用 --formula" "grep -q 'fetch --formula fake-a' \"\$WORK/home/call.log\""

# ========== 场景 5：非 TTY 无 ANSI ==========
echo "[场景 5] 非 TTY 输出无 ANSI 控制符"
rm -f "$WORK/home/call.log"
run_ua_notty "$WORK/s5.log" c
check "无 \\x1b 控制符" "! grep -q $'\x1b' \"\$WORK/s5.log\""

# ========== 场景 6：下载中实时大小/速度（缓存文件监控） ==========
echo "[场景 6] 下载中实时大小/速度（缓存文件监控，真实 Homebrew 无 Downloading 帧）"
rm -f "$WORK/home/call.log"
# 清理前序场景残留的缓存文件（否则轮询立即命中已完成文件，无法观察下载中状态）
rm -rf "$WORK/home/cache"
mkdir -p "$WORK/home/cache"
# STUB_SLOW: 让 stub fetch 慢速写入文件，便于断言下载中的帧
# 通过小延时写入（每个包 30*0.2s=6s），确保轮询能捕捉中间状态
run_ua "$WORK/s6.log" c STUB_INCREMENT_MS=200
OUT6=$(tr -d '\r' < "$WORK/s6.log")
# 断言统一在原始 OUT6 上用 [^|]* 跨 ANSI 码匹配（不依赖 sed 剥离：
# GNU sed(Linux CI) 与 BSD sed(macOS) 对 \x1b 转义行为不同，剥离法在 Linux 失效）
check "下载中显示实时大小 (· X.XMB)" "echo \"\$OUT6\" | grep -qE '下载中 [0-9.]+(MB|KB)d' || echo \"\$OUT6\" | grep -qE '下载中[^|]*[0-9.]+(MB|KB)'"
check "下载中显示实时速度 (MB/s)" "echo \"\$OUT6\" | grep -qE '[0-9.]+(MB|KB)/s'"
check "子进度条显示已下载量 (非裸?)" \
  "echo \"\$OUT6\" | grep -qE '░+[^|]*[0-9.]+(MB|KB)[^|]*下载中' || echo \"\$OUT6\" | grep -qE '░[^|]*[0-9.]+(MB|KB)[[:space:]]+下载中'" || {
  echo "  --- 子进度条行 hex dump（诊断）---"
  echo "$OUT6" | grep -a '下载中' | grep -a $'\xe2\x96\x91' | head -3 | hexdump -C | head -25
  echo "  --- 含 MB 的所有行（诊断）---"
  echo "$OUT6" | grep -a 'MB' | head -5 | tr -d '\r' | cut -c1-160
}

echo ""
echo "===== 结果: $PASS 通过 / $FAIL 失败 ====="
rm -rf "$WORK"
(( FAIL == 0 )) && exit 0 || exit 1
