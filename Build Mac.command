#!/bin/bash
set -eu
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd -- "$(dirname -- "$0")"
if ! command -v node >/dev/null; then
  echo '请先安装 Node.js 24+ / Install Node.js 24+ from https://nodejs.org/'
  read -r -p '按回车关闭 / Press Return to close. ' unused
  exit 1
fi
if ! node scripts/build-mac.mjs; then
  read -r -p '按回车关闭 / Press Return to close. ' unused
  exit 1
fi
