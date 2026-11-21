# vps-setup

新 VPS 的初始化脚本。

## 需求

1. 录入 SSH 公钥，并在**确认可以用密钥登录之后**，禁用 SSH 密码登录。
2. 安装 [zsh](https://www.zsh.org/)、[oh-my-zsh](https://ohmyz.sh/) 和 [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions)，并把 zsh 设为默认 shell。

## 用法

把脚本传到 VPS 上：

```bash
scp setup.sh <user>@<VPS_IP>:
```

运行时要加 `-t`，脚本需要交互输入。脚本需要 root 权限，普通用户用 sudo 运行；公钥和 zsh 会配置给调用 sudo 的那个用户（`<user>`）：

```bash
ssh -t <user>@<VPS_IP> sudo bash setup.sh
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

## 说明

- **禁用密码登录的方式**：如果 `sshd_config` 里有 `Include sshd_config.d/*`（较新的 Debian/Ubuntu 都有），就写入 `/etc/ssh/sshd_config.d/00-disable-password.conf`。`00-` 前缀保证它排在 cloud-init 生成的 `50-cloud-init.conf` 之前；由于 sshd 对同一选项取第一次出现的值，这样能覆盖掉后者常带的 `PasswordAuthentication yes`。如果没有 Include，就直接修改 `sshd_config`，并先备份为 `sshd_config.bak.<时间戳>`。
- **安全措施**：写入后先用 `sshd -t` 校验，失败则自动回滚；然后用 `sshd -T` 确认实际生效的值，最后才重新加载 sshd。
- **可重复执行**：已完成的步骤会自动跳过，包括已存在的公钥、已禁用的密码登录、已安装的 oh-my-zsh 和插件。
- **支持的发行版**：使用 apt、dnf、yum、pacman 或 apk 作为包管理器的发行版。目前只在 Debian 12 和 Ubuntu 24.04 容器中实际测试过。
