#!/usr/bin/env bash
# Launch ComfyUI directly (MiniMax-H3 tuned flags).
#
# This script is the single source of truth for how ComfyUI is started:
#   - Run it by hand as a manual fallback (foreground, Ctrl+C to stop).
#   - It's also what comfyui.service (system-level unit, User=syfly007;
#     source file: /mnt/data/ComfyUI/comfyui.service) calls as its
#     ExecStart — the unit just invokes this script, it does not
#     duplicate the flags.
#
# 2026-09-10 调优说明：首次 H3 测试（5s 视频）耗时 20:39，日志显示采样
# 循环第 1 步单独耗时 8:19（"Comfy model compiler graph breaks" 之后的
# 一次性 JIT 编译停顿），之后每步稳定在 ~7.3s。--disable-comfy-compiler
# 去掉这个不可预期的编译长尾停顿；PYTORCH_CUDA_ALLOC_CONF 降低大模型
# 显存碎片风险。
set -euo pipefail

export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"

cd /mnt/data/ComfyUI
# 模型库：/mnt/data/ai_models/comfy（2026-09 统一迁移）。必须用 --models-directory 指定：
# 很多插件直接使用 folder_paths.models_dir，extra_model_paths.yaml 覆盖不到。
# --disable-pinned-memory（2026-09-15）：锁页内存上限按 ram+swap 计算，本机 30G 内存 + 16G swap 时
# 可达 26G 且不可回收，H3（约 35G 模型经 mmap 从机械盘读取）会严重抖动，被 systemd-oomd 按内存压力杀掉。
# 关闭后同一工作流内存压力为 0，采样 4.3s/it 正常完成。详见 README.local.md「故障记录」。
exec /mnt/data/ComfyUI/.venv/bin/python main.py \
  --listen 0.0.0.0 --port 8189 --disable-auto-launch \
  --disable-comfy-compiler \
  --models-directory /mnt/data/ai_models/comfy \
  --disable-pinned-memory \
  --enable-manager
