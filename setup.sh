#!/usr/bin/env bash
#
# 新 VPS 初始化脚本
#   1. 录入 SSH 公钥，确认密钥登录可用后禁用 SSH 密码登录
#   2. 安装 zsh、oh-my-zsh、zsh-autosuggestions，并把 zsh 设为默认 shell
#
# 用法（在本地执行，需要 -t 以便交互）：
#   scp setup.sh <user>@<VPS_IP>:
#   ssh -t <user>@<VPS_IP> sudo bash setup.sh
#
# 公钥和 zsh 配置给调用 sudo 的那个用户；直接以 root 登录则去掉 sudo，配置给 root。
# 可重复执行：已完成的步骤会自动跳过。

set -euo pipefail

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请以 root 身份运行（sudo bash $0）"

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$TARGET_HOME" ]] || die "找不到用户 $TARGET_USER 的 home 目录"

as_user() {
  if [[ "$TARGET_USER" == root ]]; then
    "$@"
  else
    sudo -H -u "$TARGET_USER" "$@"
  fi
}

# ---------------------------------------------------------------- SSH 公钥

add_public_key() {
  local key tmp ssh_dir="$TARGET_HOME/.ssh"
  local auth="$ssh_dir/authorized_keys"
  tmp="$(mktemp)"

  while true; do
    echo "请粘贴 SSH 公钥（本地 ~/.ssh/id_ed25519.pub 之类文件的整行内容），然后回车："
    IFS= read -r key || die "未读到输入"
    key="$(printf '%s' "$key" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$key" == *"PRIVATE KEY"* ]]; then
      warn "这是私钥！请粘贴 .pub 公钥。"
      continue
    fi
    printf '%s\n' "$key" > "$tmp"
    if [[ -n "$key" ]] && ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
      break
    fi
    warn "不是有效的公钥，请重试。"
  done

  info "公钥指纹：$(ssh-keygen -l -f "$tmp")"
  rm -f "$tmp"

  as_user mkdir -p "$ssh_dir"
  as_user touch "$auth"
  chmod 700 "$ssh_dir"
  chmod 600 "$auth"

  # sshd 默认 StrictModes=yes：home 目录对组/其他用户可写时会拒绝公钥登录
  if [[ -n "$(find "$TARGET_HOME" -maxdepth 0 -perm /022)" ]]; then
    chmod go-w "$TARGET_HOME"
    info "已去掉 $TARGET_HOME 的组/其他用户写权限（否则 sshd 会拒绝公钥登录）"
  fi

  # 按密钥主体（第二个字段）去重
  if grep -qF -- "$(awk '{print $2}' <<<"$key")" "$auth"; then
    info "该公钥已存在于 $auth"
  else
    # 确保文件以换行结尾再追加
    [[ -s "$auth" && -n "$(tail -c1 "$auth")" ]] && echo >> "$auth"
    printf '%s\n' "$key" >> "$auth"
    info "已将公钥写入 $auth"
  fi
}

is_private_ip() {
  case "$1" in
    10.*|192.168.*|127.*|169.254.*|fc*|fd*|fe80:*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;  # CGNAT 100.64/10
    *) return 1 ;;
  esac
}

confirm_key_login() {
  local ip port answer
  ip="$(awk '{print $3}' <<<"${SSH_CONNECTION:-}")"
  port="$(awk '{print $4}' <<<"${SSH_CONNECTION:-}")"
  [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ip" ]] || ip="<VPS_IP>"

  printf '\n\033[1;33m%s\033[0m\n' "$(cat <<'EOF'
==================================================================
  !!! 请保持【当前这个 SSH 会话】不要关闭 !!!

  禁用密码登录后，如果密钥登录不通，你将无法再登录这台机器。
  只要当前会话还开着，就仍可在这里修复（重新录入公钥、或恢复
  密码登录）。请在下面的验证通过之前，一直保留这个会话。
==================================================================
EOF
)"
  [[ "$port" == 22 ]] && port=""
  cat <<EOF

在【本地另开一个终端】执行以下命令，确认可以用密钥登录
（只允许公钥认证：能直接进入 shell 才算成功，报 Permission denied 即失败）：

    ssh -i <私钥文件> -o PreferredAuthentications=publickey ${port:+-p $port }$TARGET_USER@$ip

<私钥文件> 是与刚才粘贴的公钥配对的私钥，即同名去掉 .pub 的文件，
例如 ~/.ssh/id_ed25519。

EOF
  if is_private_ip "$ip"; then
    warn "$ip 是本机的内网地址（云服务器在 NAT 后面时常见）。"
    warn "请把它换成你登录这台机器时用的公网 IP 或域名；端口如有转发，也以你登录时用的为准。"
    echo
  fi
  read -r -p "已确认密钥登录成功？输入 yes 将禁用密码登录，其他输入则跳过: " answer || answer=""
  [[ "$answer" == "yes" ]]
}

# ------------------------------------------------------------ 禁用密码登录

# 先存进变量再匹配：直接 `sshd -T | grep -q` 在 pipefail 下会因 SIGPIPE 误判为失败
password_login_disabled() {
  local effective
  mkdir -p /run/sshd
  effective="$(sshd -T 2>/dev/null)" || return 1
  grep -qi '^passwordauthentication no' <<<"$effective"
}

reload_sshd() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
      || systemctl restart ssh 2>/dev/null || systemctl restart sshd
  elif command -v service >/dev/null 2>&1; then
    service ssh reload 2>/dev/null || service sshd reload
  else
    return 1
  fi
}

disable_password_login() {
  local main=/etc/ssh/sshd_config
  local dropin=/etc/ssh/sshd_config.d/00-disable-password.conf
  local backup=""
  # ChallengeResponseAuthentication 是 KbdInteractiveAuthentication 的旧名，新旧版本都认
  local settings=$'PasswordAuthentication no\nChallengeResponseAuthentication no'

  [[ -f "$main" ]] || die "找不到 $main"
  mkdir -p /run/sshd  # Debian 系 sshd -t 需要

  if grep -Eqi '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$main"; then
    # sshd 对同一选项取第一次出现的值，00- 前缀保证排在
    # cloud-init 的 50-cloud-init.conf（常含 PasswordAuthentication yes）之前
    mkdir -p /etc/ssh/sshd_config.d
    printf '%s\n' "$settings" > "$dropin"
    chmod 600 "$dropin"
  else
    backup="$main.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$main" "$backup"
    # 删掉已有设置，并把新设置放在文件最前面（必须位于任何 Match 块之前）
    {
      printf '%s\n' "$settings"
      grep -Evi '^[[:space:]]*(PasswordAuthentication|ChallengeResponseAuthentication|KbdInteractiveAuthentication)[[:space:]]' "$backup" || true
    } > "$main"
    info "已备份原配置到 $backup"
  fi

  if ! sshd -t; then
    if [[ -n "$backup" ]]; then cp -p "$backup" "$main"; else rm -f "$dropin"; fi
    die "sshd 配置校验失败，已回滚，密码登录未禁用"
  fi

  if ! password_login_disabled; then
    warn "配置已写入，但 sshd -T 显示密码登录仍未关闭，请手动检查 $main 及 sshd_config.d/"
    return
  fi

  if reload_sshd; then
    info "已禁用 SSH 密码登录并重新加载 sshd"
    warn "请先在本地新开终端再登录一次，确认仍能进入后，再关闭当前会话。"
    warn "如果登录不了，在当前会话中执行以下命令恢复密码登录："
    if [[ -n "$backup" ]]; then
      warn "    cp -p $backup $main && sshd -t && (systemctl reload ssh || systemctl reload sshd || service ssh reload)"
    else
      warn "    rm -f $dropin && (systemctl reload ssh || systemctl reload sshd || service ssh reload)"
    fi
  else
    warn "配置已写入，但 sshd 重新加载失败，请手动重启 sshd 使其生效"
  fi
}

# ------------------------------------------------------------------- zsh

install_packages() {
  info "安装 zsh / git / curl"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y zsh git curl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y zsh git curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y zsh git curl
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed zsh git curl
  elif command -v apk >/dev/null 2>&1; then
    apk add zsh git curl
  else
    die "不支持的发行版：找不到 apt-get / dnf / yum / pacman / apk"
  fi
}

install_oh_my_zsh() {
  if [[ -d "$TARGET_HOME/.oh-my-zsh" ]]; then
    info "oh-my-zsh 已安装，跳过"
    return
  fi
  info "安装 oh-my-zsh"
  as_user sh -c 'curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh -s -- --unattended'
}

install_autosuggestions() {
  local dir="$TARGET_HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
  local zshrc="$TARGET_HOME/.zshrc"

  if [[ -d "$dir" ]]; then
    info "zsh-autosuggestions 已安装，跳过"
  else
    info "安装 zsh-autosuggestions"
    as_user git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions "$dir"
  fi

  if grep -Eq '^plugins=\(.*zsh-autosuggestions' "$zshrc"; then
    :
  elif grep -Eq '^plugins=\(.*\)' "$zshrc"; then
    sed -i -E '/^plugins=\(/ s/\)/ zsh-autosuggestions)/' "$zshrc"
    info "已在 $zshrc 的 plugins 中启用 zsh-autosuggestions"
  else
    warn "未在 $zshrc 中找到单行的 plugins=(...)，请手动把 zsh-autosuggestions 加进去"
  fi
}

set_default_shell() {
  local zsh_path
  zsh_path="$(command -v zsh)"
  grep -qxF "$zsh_path" /etc/shells 2>/dev/null || echo "$zsh_path" >> /etc/shells

  if [[ "$(getent passwd "$TARGET_USER" | cut -d: -f7)" == "$zsh_path" ]]; then
    return
  fi
  if chsh -s "$zsh_path" "$TARGET_USER" 2>/dev/null || usermod -s "$zsh_path" "$TARGET_USER" 2>/dev/null; then
    info "已将 $TARGET_USER 的默认 shell 设为 $zsh_path"
  else
    warn "设置默认 shell 失败，请手动执行：chsh -s $zsh_path $TARGET_USER"
  fi
}

# ------------------------------------------------------------------ main

info "为用户 $TARGET_USER 配置本机"

add_public_key
if password_login_disabled; then
  info "SSH 密码登录已是禁用状态，跳过"
elif confirm_key_login; then
  disable_password_login
else
  warn "未确认密钥登录，跳过禁用密码登录。确认后重新运行本脚本即可。"
fi

install_packages
install_oh_my_zsh
install_autosuggestions
set_default_shell

info "全部完成。重新登录后即进入 zsh。"
