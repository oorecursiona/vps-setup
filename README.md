# vps-setup

新 VPS 的初始化脚本，分成两个独立脚本，按需运行：

| 脚本 | 作用 |
| --- | --- |
| [`init-ssh-zsh.sh`](init-ssh-zsh.sh) | 录入 SSH 公钥并禁用密码登录；安装 zsh、oh-my-zsh 和 zsh-autosuggestions |
| [`tune-network.sh`](tune-network.sh) | 开启 BBR，并调整 TCP 参数以提高网速 |

两个脚本都需要 root 权限，都可以重复执行。

## init-ssh-zsh.sh：SSH 加固与 zsh

### 需求

1. 录入 SSH 公钥，并在**确认可以用密钥登录之后**，禁用 SSH 密码登录。
2. 安装 [zsh](https://www.zsh.org/)、[oh-my-zsh](https://ohmyz.sh/) 和 [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions)，并把 zsh 设为默认 shell。

### 用法

把脚本传到 VPS 上：

```bash
scp init-ssh-zsh.sh <user>@<VPS_IP>:
```

运行时要加 `-t`，脚本需要交互输入。普通用户用 sudo 运行，公钥和 zsh 会配置给调用 sudo 的那个用户（`<user>`）：

```bash
ssh -t <user>@<VPS_IP> sudo bash init-ssh-zsh.sh
```

如果直接以 root 登录，就把 `<user>` 换成 `root`，并去掉 `sudo`。此时公钥和 zsh 配置给 root。

### 运行过程

1. **粘贴公钥**：粘贴本地 `<公钥文件>`（例如 `~/.ssh/id_ed25519.pub`）的整行内容。格式不对或误贴了私钥，会提示重新输入。公钥会追加到 `~/.ssh/authorized_keys`，已经存在的不会重复添加。
2. **确认密钥登录**：脚本会打印一条测试命令。**不要关闭当前会话**，在本地另开一个终端执行它，确认不用输密码就能登录：

   ```bash
   ssh -i <私钥文件> -o PreferredAuthentications=publickey <user>@<VPS_IP>
   ```

   - `<私钥文件>` 是与上一步公钥配对的私钥，即同名去掉 `.pub` 的文件，例如 `~/.ssh/id_ed25519`。用 `-i` 显式指定私钥，测的就一定是刚录入的那把密钥；不指定时，如果私钥不是默认文件名（`id_ed25519`、`id_rsa`、`id_ecdsa`），ssh 根本不会使用它。
   - `-o PreferredAuthentications=publickey` 只允许公钥认证：密钥不通会直接报 `Permission denied`。不要用 `-o PasswordAuthentication=no` 来测试，它不会关闭 keyboard-interactive 认证，服务器照样会弹出 `Password:` 提示，看不出密钥到底通没通。
   - 脚本打印的地址如果是内网 IP（云服务器在 NAT 后面时常见），请换成你登录时用的公网 IP 或域名。
   - 以后想省掉 `-i`，可以在本地 `~/.ssh/config` 里为这台主机配置 `IdentityFile`。

   回到脚本输入 `yes`，脚本才会禁用密码登录；输入其他内容则跳过这一步，确认之后重新运行脚本即可。

   禁用之后，脚本会打印一条恢复密码登录的命令。请在本地**再新开一次登录**确认没问题后，再关闭原来的会话；如果登录不了，就在原会话里执行那条命令。
3. **安装 zsh 环境**：自动安装 zsh、git、curl、oh-my-zsh 和 zsh-autosuggestions，在 `~/.zshrc` 的 `plugins=(...)` 中启用 `zsh-autosuggestions`，并把默认 shell 改为 zsh。

完成后重新登录，就会进入 zsh。

### 说明

- **禁用密码登录的方式**：如果 `sshd_config` 里有 `Include sshd_config.d/*`（较新的 Debian/Ubuntu 都有），就写入 `/etc/ssh/sshd_config.d/00-disable-password.conf`。`00-` 前缀保证它排在 cloud-init 生成的 `50-cloud-init.conf` 之前；由于 sshd 对同一选项取第一次出现的值，这样能覆盖掉后者常带的 `PasswordAuthentication yes`。如果没有 Include，就直接修改 `sshd_config`，并先备份为 `sshd_config.bak.<时间戳>`。
- **安全措施**：写入后先用 `sshd -t` 校验，失败则自动回滚；然后用 `sshd -T` 确认实际生效的值，最后才重新加载 sshd。
- **home 目录权限**：如果 home 目录对组或其他用户可写，sshd 默认会拒绝公钥登录，脚本会自动去掉这些写权限。
- **可重复执行**：已完成的步骤会自动跳过，包括已存在的公钥、已禁用的密码登录、已安装的 oh-my-zsh 和插件。
- **支持的发行版**：使用 apt、dnf、yum、pacman 或 apk 作为包管理器的发行版。目前只在 Debian 12 和 Ubuntu 24.04 容器中实际测试过。

## tune-network.sh：网络调优

### 需求

提高 VPS 的网络吞吐，尤其是跨境这类高延迟、有丢包的链路。

### 用法

不需要交互，所以不用加 `-t`：

```bash
scp tune-network.sh <user>@<VPS_IP>:
```

```bash
ssh <user>@<VPS_IP> sudo bash tune-network.sh
```

脚本会打印每个参数调整前后的值。全部生效时以 0 退出；有参数没生效时会在表中标出，并以 1 退出。

确认 BBR 已开启（输出 `bbr` 即可）：

```bash
sysctl net.ipv4.tcp_congestion_control
```

### 调整的参数

配置写入 `/etc/sysctl.d/99-network-tuning.conf`，重启后依然有效。

| 参数 | 值 | 作用 |
| --- | --- | --- |
| `net.ipv4.tcp_congestion_control` | `bbr` | 按测出的带宽和延迟控制发送速度，不会像默认的 cubic 那样一丢包就大幅降速；在高延迟、有丢包的链路上提升最明显 |
| `net.core.default_qdisc` | `fq` | 配合 BBR 的队列算法 |
| `net.core.rmem_max` / `wmem_max` | 64 MB | 允许的最大 socket 缓冲区 |
| `net.ipv4.tcp_rmem` / `tcp_wmem` | 最大 64 MB | 单连接吞吐上限约为"缓冲区 ÷ 往返延迟"；默认最大只有 4–6 MB，200ms 延迟下单连接只能跑到约 200 Mbps |
| `net.ipv4.tcp_slow_start_after_idle` | `0` | 连接空闲后不重新慢启动，长连接更快恢复速度 |
| `net.ipv4.tcp_mtu_probing` | `1` | 自动探测 MTU，避免链路上有设备丢弃大包导致连接卡住 |
| `net.ipv4.tcp_fastopen` | `3` | 握手时就能带数据，减少一次往返 |
| `net.ipv4.tcp_notsent_lowat` | `16384` | 减少发送队列里的积压，降低交互延迟 |

### 说明

- **内核要求**：需要内核 4.9 及以上，并且编译了 BBR。Debian 10+、Ubuntu 18.04+ 都满足。不满足时脚本会报错退出，不做任何修改。
- **容器化 VPS**：OpenVZ、LXC 这类 VPS 和宿主机共享内核，通常改不了这些参数，BBR 只能由服务商在宿主机上开启。脚本检测到这种环境时会给出提示。
- **生效时机**：立即生效，不需要重启。已建立的连接仍使用旧算法，新建立的连接使用 BBR。
- **撤销**：删除 `/etc/sysctl.d/99-network-tuning.conf` 和 `/etc/modules-load.d/bbr.conf`，然后重启。
- **配置调不了的部分**：从国内访问时，影响最大的是回程线路（CN2 GIA、CMI、联通 9929/4837 等）。可以用 `mtr` 或 `nexttrace` 看路由和丢包，用 `iperf3` 测实际吞吐，判断瓶颈在线路还是在参数。
