#!/usr/bin/env bash
# 安装 / 更新 ComfyUI 系统级服务；如果还在用旧的 user 级服务，一并切换过来。
#   用法：sudo bash /mnt/data/ComfyUI/install_comfyui_service.sh
#   ComfyUI 有任务在运行或排队时会拒绝执行（切换必然重启 ComfyUI）。
set -euo pipefail

RUN_USER=syfly007
RUN_UID=$(id -u "$RUN_USER")
SRC=/mnt/data/ComfyUI/comfyui.service
DST=/etc/systemd/system/comfyui.service
USER_UNIT=/home/$RUN_USER/.config/systemd/user/comfyui.service
TS=$(date +%Y%m%d%H%M%S)

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行"; exit 1; }
[ -f "$SRC" ] || { echo "找不到单元源文件：$SRC"; exit 1; }

# 1) 有任务就停止，不做任何改动
#    用 printf 原样传递 JSON（echo 在部分 shell 下会展开提示词里的 \n 等转义，破坏 JSON）；
#    解析失败一律当作"无法确认"并中止，绝不当作空闲。
if Q_JSON=$(curl -sf -m 5 http://127.0.0.1:8189/queue); then
    Q_STATE=$(printf '%s' "$Q_JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print("busy" if d["queue_running"] or d["queue_pending"] else "idle")
except Exception as e:
    print("error")')
    case "$Q_STATE" in
        idle) echo "== 1/4 ComfyUI 当前没有任务" ;;
        busy) echo "ComfyUI 仍有任务在运行或排队，未做任何改动。请等任务完成后再执行。"; exit 1 ;;
        *)    echo "无法解析 ComfyUI 任务队列，未做任何改动。请手动确认没有任务后再执行。"; exit 1 ;;
    esac
else
    echo "== 1/4 ComfyUI 未在运行（8189 无响应）"
fi

# 2) 停用旧的 user 级服务（如果存在）
if [ -f "$USER_UNIT" ]; then
    sudo -u "$RUN_USER" XDG_RUNTIME_DIR=/run/user/$RUN_UID systemctl --user disable --now comfyui.service || true
    mv "$USER_UNIT" "$USER_UNIT.disabled-$TS"
    sudo -u "$RUN_USER" XDG_RUNTIME_DIR=/run/user/$RUN_UID systemctl --user daemon-reload || true
    echo "== 2/4 已停用 user 级服务，旧单元文件改名为 $USER_UNIT.disabled-$TS"
else
    echo "== 2/4 没有 user 级服务，跳过"
fi

# 3) 安装系统级单元
if [ -f "$DST" ] && ! cmp -s "$SRC" "$DST"; then
    cp -a "$DST" "$DST.bak.$TS"
    echo "   已备份旧单元：$DST.bak.$TS"
fi
install -m 644 -o root -g root "$SRC" "$DST"
systemd-analyze verify "$DST"
systemctl daemon-reload
systemctl enable comfyui.service
systemctl restart comfyui.service
echo "== 3/4 系统级服务已安装并启动"

# 4) 等待 HTTP 就绪
for _ in $(seq 1 90); do
    curl -s -m 2 http://127.0.0.1:8189/system_stats >/dev/null && break
    sleep 2
done
echo "== 4/4 状态：$(systemctl is-active comfyui.service)，开机自启：$(systemctl is-enabled comfyui.service)，" \
     "运行用户：$(ps -o user= -p "$(systemctl show -p MainPID --value comfyui.service)" 2>/dev/null)，" \
     "HTTP：$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:8189/system_stats)"
