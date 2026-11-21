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
5. 主机上有 Intel 板载网卡（驱动 `e1000e`，比如 I219）时，关掉它的 TSO/GSO，并写一条 udev 规则，让它每次开机都关着。见下面「要知道的」。

在虚拟机里（`runner-setup.sh`）：

- 装好 GitHub `ubuntu-24.04` 镜像里有、但 setup action 不会替你装的东西：git、gh、jq、zip、python3、build-essential、Docker + buildx、QEMU + OVMF。Node、Python 版本、uv、pnpm 这些由各自的 setup action 安装。
- 下载最新的 actions runner，核对 SHA256，注册 N 个实例（`gh-runner-1`、`gh-runner-2`……），装成 systemd 服务。
- 每个实例用自己的用户（`runner-1`、`runner-2`……，都在 docker、kvm 组，免密 sudo，和 GitHub 的 runner 一样）。GitHub 给每个 job 一台单独的机器；这里同时跑的几个 job 至少不共用家目录，setup action 装在 `~` 下的东西（pnpm 和它的 store、uv 的缓存等）不会被另一个 job 中途改掉。Docker 和 KVM 仍然共用。
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
| `--disk-cache MODE` | unsafe | 磁盘的缓存模式，见下面「要知道的」；`none` 是 PVE 自己的默认 |
| `--ssh-key FILE` | `/root/.ssh/authorized_keys` | 放进虚拟机的公钥 |
| `--no-nic-fix` | | 不改主机的 e1000e 网卡 |
| `--yes` | | 不确认直接建 |

## 要知道的

- **只给你信任的仓库用。** runner 用户能免密 sudo，job 能在这台虚拟机上做任何事。公开仓库收到陌生人的 PR 就能在你的网络里跑代码；仓库要公开之前，先移除 runner。
- 虚拟机关着时 job 会排队，最多等 24 小时。
- **Intel 板载网卡（`e1000e`）会卡死。** I219 这类网卡在 Linux 上、桥接着忙碌的虚拟机时，会在大流量下卡住（内核日志里是 `Detected Hardware Unit Hang`），主机和所有虚拟机一起断网，往往只能重启。机器放在远端机房时尤其麻烦。`pve-install.sh` 检测到这种网卡，会关掉它的 TSO/GSO（改由 CPU 切分数据包，千兆网下几乎不费力），并写入 `/etc/udev/rules.d/90-pve-github-runner-e1000e.rules`，重启和内核升级后仍然有效。重装 PVE 后再跑一次 `pve-install.sh`，修复就回来了。想在已经装好的主机上单独做这一步：
  ```bash
  ethtool -K eno1 tso off gso off
  echo 'ACTION=="add", SUBSYSTEM=="net", DRIVERS=="e1000e", RUN+="/usr/sbin/ethtool -K $name tso off gso off"' > /etc/udev/rules.d/90-pve-github-runner-e1000e.rules
  ```
  （`eno1` 换成你的网卡名，`ip -br link` 可以看到。）彻底的办法是换一块不用 `e1000e` 的 PCIe 网卡，比如 Intel I210 或 I226。
- **磁盘默认用 `cache=unsafe`。** 虚拟机里的 fsync 不再等 SSD 确认。消费级 SSD 上每次确认要十毫秒左右，大量读写数据库的测试（比如每个用例建一个 SQLite 库）会因此慢好几倍：实测 200 次 SQLite 提交从 1.98 秒降到 0.1 秒。代价是 PVE 主机突然断电或死机时，这台虚拟机的磁盘可能损坏，那就删掉重建。虚拟机自己重启或崩溃没有影响。不想要就加 `--disk-cache none`。已有的虚拟机：`qm set <vmid> --scsi0 <原来的值>,cache=unsafe`，然后关机再开机。
- 想让 job 里能跑 KVM，PVE 主机要开嵌套虚拟化（较新的内核默认开启），脚本会检查并提示。
- 加 runner：在虚拟机里用更大的 `RUNNER_COUNT` 再跑一次 `runner-setup.sh`（命令在安装结束时会打印）。
- 以前装的（所有实例共用一个 `runner` 用户）：在虚拟机里再跑一次 `runner-setup.sh`，不用注册令牌。每个实例会搬到自己的用户下，注册信息保留，服务会重启一下，所以最好在没有 job 的时候跑。跑完它会打印删掉旧 `runner` 用户的命令。
- 移除：在 GitHub 的 Settings → Actions → Runners 里删掉 runner（离线 14 天后 GitHub 也会自动删），再在 PVE 里删掉虚拟机。
- GitHub 曾宣布对自托管 runner 按分钟收费，后来推迟了；用之前看一下当前的计费说明。

## 许可

MIT
