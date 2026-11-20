# pve-github-runner

在 Proxmox VE 上一条命令建好 GitHub Actions 自托管 runner：一台 Ubuntu 24.04 虚拟机，装好 Docker、QEMU/KVM，注册好几个 runner 并设成开机自启。私有仓库用自己的 runner 跑 CI，不占 GitHub 的 Actions 分钟数。

## 用法

在 PVE 主机上以 root 运行（网页界面里节点 → Shell 即可）：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/JoeFu/pve-github-runner/main/pve-install.sh)" -- --repo OWNER/NAME
```

它会问一个**注册令牌**，在你自己的电脑上生成（1 小时内有效）：

```bash
gh api -X POST repos/OWNER/NAME/actions/runners/registration-token --jq .token
```

也可以给它一个能管理仓库 runner 的 `GITHUB_TOKEN`（fine-grained token：Administration 读写），让它自己去要注册令牌：

```bash
GITHUB_TOKEN=github_pat_... bash -c "$(curl -fsSL https://raw.githubusercontent.com/JoeFu/pve-github-runner/main/pve-install.sh)" -- --repo OWNER/NAME --set-variable NIA_RUNNER
```

`--set-variable NIA_RUNNER` 会在 runner 上线后把仓库变量 `NIA_RUNNER` 设成 `self-hosted`，适用于这样写的 workflow：

```yaml
runs-on: ${{ vars.NIA_RUNNER || 'ubuntu-24.04' }}
```

不设这个变量就继续用 GitHub 的 runner；删掉变量就切回去。也可以直接在 workflow 里写 `runs-on: self-hosted`。

## 它做了什么

在 PVE 主机上（`pve-install.sh`）：

1. 下载 Ubuntu 24.04 cloud image，核对官方 SHA256，缓存在 `/var/tmp/pve-github-runner/`。
2. 新建虚拟机：CPU 类型 `host`（虚拟机里有 KVM，可以再跑虚拟机）、默认 4 核 / 8 GB / 100 GB、DHCP、开机自启、开 guest agent，标签 `github-runner`。主机 root 的 SSH 公钥会放进虚拟机的 `ubuntu` 用户。
3. 通过 cloud-init 装 guest agent 并放入 `runner-setup.sh`。没有存储允许 snippets 时，会给 `local` 加上 snippets（运行前会提示）。
4. 等 guest agent 上线后，通过它把注册令牌交给虚拟机里的 `runner-setup.sh`。令牌不会写进 cloud-init 文件。

在虚拟机里（`runner-setup.sh`）：

- 装好 GitHub `ubuntu-24.04` 镜像里有、但 setup action 不会替你装的东西：git、gh、jq、zip、python3、build-essential、Docker + buildx、QEMU + OVMF。Node、Python 版本、uv、pnpm 这些由各自的 setup action 安装。
- 建 `runner` 用户（docker、kvm 组，免密 sudo，和 GitHub 的 runner 一样）。
- 下载最新的 actions runner，核对 SHA256，注册 N 个实例（`gh-runner-1`、`gh-runner-2`……），装成 systemd 服务。
- 每周清理一次一周前的 Docker 镜像和构建缓存。

`runner-setup.sh` 也可以单独在任何 Ubuntu 24.04 x64 机器上用，见文件开头的说明。重复运行是安全的。

## 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `--repo OWNER/NAME` | | 给这个仓库注册 runner |
| `--org ORG` | | 给整个组织注册（和 `--repo` 二选一） |
| `--token TOKEN` | 运行时询问 | 注册令牌 |
| `--count N` | 3 | runner 个数，每个一次跑一个 job |
| `--labels A,B` | | 额外标签；`self-hosted`、`linux`、`x64` 总是有 |
| `--group NAME` | Default | 组织的 runner group |
| `--set-variable VAR` | | runner 上线后把仓库变量 VAR 设为 `self-hosted`（需要 `GITHUB_TOKEN`） |
| `--vmid N` | 下一个空闲 ID | |
| `--name NAME` | gh-runner | 虚拟机名，也是 runner 名前缀 |
| `--storage ID` | local-lvm | 磁盘放在哪个存储 |
| `--bridge BRIDGE` / `--vlan TAG` | vmbr0 | 网络 |
| `--disk SIZE` / `--cores N` / `--memory MIB` | 100G / 4 / 8192 | |
| `--ssh-key FILE` | `/root/.ssh/authorized_keys` | 放进虚拟机的公钥 |
| `--yes` | | 不确认直接建 |

## 要知道的

- **只给你信任的仓库用。** runner 用户能免密 sudo，job 能在这台虚拟机上做任何事。公开仓库收到陌生人的 PR 就能在你的网络里跑代码；仓库要公开之前，先移除 runner。
- 虚拟机关着时 job 会排队，最多等 24 小时。
- 想让 job 里能跑 KVM，PVE 主机要开嵌套虚拟化（较新的内核默认开启），脚本会检查并提示。
- 加 runner：在虚拟机里用更大的 `RUNNER_COUNT` 再跑一次 `runner-setup.sh`（命令在安装结束时会打印）。
- 移除：在 GitHub 的 Settings → Actions → Runners 里删掉 runner（离线 14 天后 GitHub 也会自动删），再在 PVE 里删掉虚拟机。
- GitHub 曾宣布对自托管 runner 按分钟收费，后来推迟了；用之前看一下当前的计费说明。

## 许可

MIT
