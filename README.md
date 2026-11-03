# picket-code-server

Picket Code 的**远程工作区后端**（上游叫 `vscode-server`，Products 里叫 `server` / reh）。
Windows 上的 Picket Code 通过它把整个工作区放进 WSL（或任何 Linux 机器）里跑：文件系统、递归监视、搜索、扩展宿主、终端都在 Linux 侧，客户端只做 UI 与 RPC。

本仓库只负责**构建与分发**，不含源码：它按 tag 拉取 `dantesun/picket-code`（补丁的唯一事实来源）与 `microsoft/vscode`，打补丁、构建、打包、发布。

## 为什么需要独立仓库

客户端已经有 `chatService` 的默认 agent 回退、iCode 适配器等补丁；远程窗口里的 agent host 是在 **server 进程**里实例化的（`src/vs/server/node/serverServices.ts:284`），所以 server 必须由**我们自己的树**构建，才能带上 iCode。微软发布的 `vscode-server` 二进制做不到这一点（也会因分发修改过的微软产物而违反其条款）。

## 版本契约

- **tag 与客户端完全一致**：客户端 `v1.143.1-picket.1-rc.5` → 本仓库同名 tag。
- 上游版本从 tag 推导：`v1.143.1-picket.1-rc.5` → `1.143.1`。
- 客户端与服务端的 `product.json.commit` 必须相同：握手时 server 校验 `rendererCommit === myCommit`，不一致会直接 `Client refused: version mismatch`（`remoteExtensionHostAgentServer.ts:351-357`）。两者都由同一个上游 tag 构建，天然一致；CI 里有断言兜底。

## 产物契约

| 项 | 值 |
|---|---|
| 文件名 | `picket-code-server-<tag>-linux-x64.tar.gz` |
| 顶层目录 | `picket-code-server-linux-x64/`（**不含**版本号） |
| 入口 | `bin/picket-code-server`（`product.serverApplicationName`） |
| 校验 | `picket-code-server-<tag>-SHA256SUMS` |
| 发布 | GitHub Release（私有仓库，需鉴权）+ R2 镜像 `r2:picket-releases/` → https://download.noware.cn/ |

镜像上的直链形状：

```
https://download.noware.cn/picket-code-server-v1.143.1-picket.1-rc.5-linux-x64.tar.gz
https://download.noware.cn/picket-code-server-v1.143.1-picket.1-rc.5-SHA256SUMS
```

## 构建产物的三条不变量

CI 每次都会断言，任何一条失败即视为坏包：

1. `product.json.version` 是**裸 `X.Y.Z`**（带 `-`/`+` 后缀会让所有扩展被判不兼容）。
2. `product.json.serverDataFolderName` 为 `.picket-code-server`。
3. 产物里**没有 vsda**：server 只在存在 vsda 校验器时才强制客户端签名（`remoteExtensionHostAgentServer.ts:361` 的 `if (!validator) valid = true`），我们签不出微软签名，必须保持无 vsda 才能连上。

另外断言 iCode 确实进了包：`out/` 里能 grep 到 `PICKET_ICODE_BIN`（min 构建里字符串字面量会保留）。

## 手动构建

```bash
bash build/build-server.sh v1.143.1-picket.1-rc.5
# 产物：release/picket-code-server-v1.143.1-picket.1-rc.5-linux-x64.tar.gz
```

依赖：Node（`vscode/.nvmrc` 的版本）、Python 3、以及原生模块需要的系统库：

```bash
sudo apt-get install -y build-essential python3 libkrb5-dev libx11-dev \
  libxkbfile-dev libsecret-1-dev libxext-dev libxrender-dev libxrandr-dev
```

## 发布

推送与客户端同名的 tag 即触发 `.github/workflows/release-server.yml`：

```bash
git tag v1.143.1-picket.1-rc.5 && git push origin v1.143.1-picket.1-rc.5
```

流水线：`build` → `verify`（三条不变量 + `/version` 冒烟 + commit 断言）→ `release`（GitHub Release）→ `mirror`（R2 + 清理旧版本）。

需要的 secrets：`R2_ACCESS_KEY_ID`、`R2_SECRET_ACCESS_KEY`、`R2_ENDPOINT`（与 picket-code 相同）。

## 客户端如何使用

Windows 客户端内置一个 resolver 扩展（不在本仓库）：

1. 从镜像取与本机 tag 同名的包，校验 `SHA256SUMS`；
2. 解到 WSL 里（`~/.picket-code-server/<tag>/`），`wsl.exe -d <distro> -- ~/.picket-code-server/<tag>/bin/picket-code-server --port 0 --connection-token <t>`；
3. 按 `resolveAuthority` 返回 `authority + connectionToken`，之后由 `vscode-remote` 通道接管——工作区、监视、搜索、语言服务全部在 WSL 里。

## 授权

构建输入是 MIT 许可的上游源码与我们自己的补丁，产物是我们自己的构建，不含微软签名的二进制。不提供、不分发任何微软发布的 server 包。
