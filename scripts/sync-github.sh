#!/usr/bin/env bash
# CNB → GitHub 全分支同步(在 CNB 流水线容器内执行)
#
# 触发方式(见 .cnb.yml):
#   1. push 到 CNB main 时实时同步
#   2. 每 6 小时 crontab 兜底
#   3. .cnb/web_trigger.yml 网页按钮手动触发
#
# 依赖环境变量(由密钥仓库 blueteam0715/keys 的 env.yml imports 提供):
#   GITHUB_SYNC_USER  - GitHub 用户名
#   GITHUB_SYNC_TOKEN - GitHub Personal Access Token(repo 权限)
set -euo pipefail

CNB_REPO="https://cnb.cool/blueteam0715/brewua.git"
DEST_REPO="https://${GITHUB_SYNC_USER}:${GITHUB_SYNC_TOKEN}@github.com/yingshu0218/homebrew-update-all.git"

if [[ -z "${GITHUB_SYNC_TOKEN:-}" ]]; then
  echo "错误:未配置 GITHUB_SYNC_TOKEN(检查密钥仓库 env.yml)" >&2
  exit 1
fi

rm -rf mirror.git
git clone --quiet --mirror "$CNB_REPO" mirror.git
cd mirror.git

# 用 --all + --tags 而非 --mirror:
# 同步全部分支与标签,但不删除 GitHub 侧 CNB 中不存在的 refs(避免误删历史分支)
git push --quiet "$DEST_REPO" --all
git push --quiet "$DEST_REPO" --tags

echo "✓ CNB → GitHub 同步完成(main 及全部分支 + tags)"
