#!/usr/bin/env bash
#
# VPS 网络调优脚本
#   - 开启 BBR 拥塞控制 + fq 队列
#   - 调大 TCP 缓冲区，适配高延迟（跨境）链路
#   - 其他 TCP 小优化：空闲后不慢启动、MTU 探测、TCP Fast Open、notsent_lowat
#
# 用法：
#   scp tune-network.sh <user>@<VPS_IP>:
#   ssh <user>@<VPS_IP> sudo bash tune-network.sh
#
# 配置写入 /etc/sysctl.d/99-network-tuning.conf，重启后依然有效。
# 撤销：删除该文件和 /etc/modules-load.d/bbr.conf 后重启。
# 可重复执行。

set -euo pipefail

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请以 root 身份运行（sudo bash $0）"

CONF=/etc/sysctl.d/99-network-tuning.conf
MODCONF=/etc/modules-load.d/bbr.conf

# 单连接吞吐上限 ≈ 缓冲区 / RTT；64MB 足够 200ms 延迟下跑满 2Gbps 以上
SETTINGS=(
  "net.core.default_qdisc = fq"
  "net.ipv4.tcp_congestion_control = bbr"
  "net.core.rmem_max = 67108864"
  "net.core.wmem_max = 67108864"
  "net.ipv4.tcp_rmem = 4096 131072 67108864"
  "net.ipv4.tcp_wmem = 4096 65536 67108864"
  "net.ipv4.tcp_slow_start_after_idle = 0"
  "net.ipv4.tcp_mtu_probing = 1"
  "net.ipv4.tcp_fastopen = 3"
  "net.ipv4.tcp_notsent_lowat = 16384"
)

key_of() { awk -F' = ' '{print $1}' <<<"$1"; }
current() { sysctl -n "$1" 2>/dev/null | tr '\t' ' ' || echo "n/a"; }  # n/a：内核不支持该参数

# ------------------------------------------------------------ 环境检查

check_kernel() {
  local ver major minor
  ver="$(uname -r)"
  major="${ver%%.*}"
  minor="${ver#*.}"; minor="${minor%%.*}"
  if (( major < 4 || (major == 4 && minor < 9) )); then
    die "内核 $ver 太旧，BBR 需要 4.9 及以上。请先升级系统内核。"
  fi
  info "内核版本 $ver"
}

check_virt() {
  local virt=""
  command -v systemd-detect-virt >/dev/null 2>&1 && virt="$(systemd-detect-virt --container 2>/dev/null || true)"
  [[ -z "$virt" && -e /proc/vz && ! -e /proc/bc ]] && virt="openvz"
  case "$virt" in
    ""|none) ;;
    *) warn "检测到容器化虚拟机（$virt）：与宿主机共享内核，很可能无法修改这些参数，BBR 需由服务商在宿主机开启。" ;;
  esac
}

enable_bbr_module() {
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    die "当前内核不支持 BBR（可用算法：$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo 未知)）"
  fi
  # 开机自动加载模块（内核内置 BBR 时这行也无害）
  if [[ -d /etc/modules-load.d ]] && ! grep -qx tcp_bbr "$MODCONF" 2>/dev/null; then
    echo tcp_bbr > "$MODCONF"
  fi
}

# ------------------------------------------------------------ 写入并应用

write_conf() {
  {
    echo "# 由 tune-network.sh 生成，删除本文件并重启即可撤销"
    printf '%s\n' "${SETTINGS[@]}"
  } > "$CONF"
  info "已写入 $CONF"
}

apply_conf() {
  local errors
  # 只加载本文件，避免其他 sysctl 配置的报错干扰判断
  if ! errors="$(sysctl -p "$CONF" 2>&1 >/dev/null)"; then
    warn "部分参数应用失败："
    printf '%s\n' "$errors" | sed 's/^/    /' >&2
  fi
}

# ------------------------------------------------------------------ main

check_kernel
check_virt
enable_bbr_module

declare -A BEFORE
for s in "${SETTINGS[@]}"; do
  k="$(key_of "$s")"
  BEFORE[$k]="$(current "$k")"
done

write_conf
apply_conf

echo
# 中文按字节计宽，补偿到与下面各行对齐（"参数" 6 字节占 4 列，"调整前" 9 字节占 6 列）
printf '%-38s %-29s %s\n' "参数" "调整前" "调整后"
failed=0
for s in "${SETTINGS[@]}"; do
  k="$(key_of "$s")"
  want="${s#* = }"
  now="$(current "$k")"
  mark=""
  if [[ "$(tr -s ' ' <<<"$now")" != "$want" ]]; then
    mark="  ← 未生效"
    failed=1
  fi
  printf '%-36s %-26s %s%s\n' "$k" "${BEFORE[$k]}" "$now" "$mark"
done
echo

if (( failed )); then
  warn "有参数未生效，见上表。容器化 VPS（OpenVZ/LXC）通常无法修改内核参数。"
  exit 1
fi

info "全部生效。已建立的连接仍使用旧算法，新连接即使用 BBR。"
