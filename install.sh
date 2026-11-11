#!/usr/bin/env bash
# 編譯 monitor-align 到 ~/.local/bin
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p "$HOME/.local/bin"
swiftc -O monitor-align.swift -o "$HOME/.local/bin/monitor-align"
echo "已安裝：$HOME/.local/bin/monitor-align"
