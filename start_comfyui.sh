#!/usr/bin/env bash
# Launch ComfyUI directly (MiniMax-H3 tuned flags).
#
# This script is the single source of truth for how ComfyUI is started:
#   - Run it by hand as a manual fallback (foreground, Ctrl+C to stop).
#   - It's also what comfyui.service (systemd --user, boot-autostart via
#     `loginctl enable-linger`) calls as its ExecStart — the unit just
#     invokes this script, it does not duplicate the flags.
#
# 2026-09-10 调优说明：首次 H3 测试（5s 视频）耗时 20:39，日志显示采样
# 循环第 1 步单独耗时 8:19（"Comfy model compiler graph breaks" 之后的
# 一次性 JIT 编译停顿），之后每步稳定在 ~7.3s。--disable-comfy-compiler
# 去掉这个不可预期的编译长尾停顿；PYTORCH_CUDA_ALLOC_CONF 降低大模型
# 显存碎片风险。
set -euo pipefail

export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"

cd /mnt/data/ComfyUI
exec /mnt/data/ComfyUI/.venv/bin/python main.py \
  --listen 0.0.0.0 --port 8189 --disable-auto-launch \
  --disable-comfy-compiler
