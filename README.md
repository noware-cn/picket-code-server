# picket-code-server

Picket Code 的**远程工作区后端**（上游叫 `vscode-server`，Products 里叫 `server` / reh）。
Windows 上的 Picket Code 通过它把整个工作区放进 WSL（或任何 Linux 机器）里跑：文件系统、递归监视、搜索、扩展宿主、终端都在 Linux 侧，客户端只做 UI 与 RPC。

本仓库只负责**构建与分发**，不含源码：它按 ref 拉取 `dantesun/picket-code`（补丁的唯一事实来源）与 `microsoft/vscode`，打补丁、构建、打包、发布。

## 为什么需要独立仓库

客户端已经有 `chatService` 的默认 agent 回退、iCode 适配器等补丁；远程窗口里的 agent host 是在 **server 进程**里实例化的（`src/vs/server/node/serverServices.ts:284`），所以 server 必须由**我们自己的树**构建，才能带上 iCode。微软发布的 `vscode-server` 二进制做不到这一点（也会因分发修改过的微软产物而违反其条款）。

## 版本契约

真实的约束只有两条：

1. **`product.json.commit` 必须与客户端相同**。握手时 server 校验
   `rendererCommit === myCommit`，不一致直接 `Client refused: version mismatch`
   （`remoteExtensionHostAgentServer.ts:351-357`），CI 里有断言兜底。
2. **版本不低于客户端的 `product.json.picketServerMinVersion`**。客户端按 commit
   过滤、取最高版本、再和下限比较，取不到就报错，不会静默降级。

所以服务端**自己定版本号**，与客户端 tag 无关：

- 版本是**裸 semver**（`1.143.1`、`1.144.0-rc.1`），**不带 `v` 前缀**；客户端用
  `parseVersion()` 解析，`v1.143.1-picket.1-rc.4` 这种旧形式会被判为不可解析。
- Release tag 是 `server-v<版本>`，资产是 `picket-code-server-<版本>-…`。
- 同一个 commit 上可以反复发版修服务端 bug；客户端不重发也能用（只要下限满足）。
- 客户端换到新 commit 时**必须**有新 commit 的载荷——这是构建来源问题，不是版本号问题。

`product.json.version` 始终保持上游版本（`1.143.1`）：扩展加载时校验的是它，服务端自己的版本只出现在 tag、资产名和客户端 catalog 里。

## 产物契约

| 项 | 值 |
|---|---|
| 文件名 | `picket-code-server-<版本>-linux-x64.tar.gz` |
| 顶层目录 | `picket-code-server-linux-x64/`（**不含**版本号） |
| 入口 | `bin/picket-code-server`（`product.serverApplicationName`） |
| 校验 | `picket-code-server-<版本>-SHA256SUMS` |
| 发布 | GitHub Release（**公开仓库**，匿名可下载）+ R2 镜像 `r2:picket-releases/` → https://download.noware.cn/ |

客户端构建用 `PICKET_SERVER_VERSION`（可选，默认等于 `PICKET_SERVER_MIN_VERSION`）钉住这里的一个版本，`build/wsl/fetch-payload.sh` 直接走 `https://github.com/noware-cn/picket-code-server/releases/download/server-v<版本>/<file>` 匿名下载，不需要任何令牌。**这个仓库必须保持公开**：客户端发布流水线与离线组件包都依赖匿名读取。

镜像上的直链形状：

```
https://download.noware.cn/picket-code-server-1.143.1-linux-x64.tar.gz
https://download.noware.cn/picket-code-server-1.143.1-SHA256SUMS
```

## 一个容易踩的坑：commit 来自 `git rev-parse HEAD`

`product.json.commit` 由 `build/lib/getVersion.ts` 生成：优先 `BUILD_SOURCEVERSION`，否则 `git rev-parse HEAD`。CI 里两端都是"clone 上游 tag → 应用补丁（不提交）"，所以两边的 commit 都是上游 tag 的 commit，握手通过。

**但如果本地在 `vscode/` 里 `git commit` 过**（例如为了导出补丁），本地构建出来的 commit 就变成你自己的提交，与发行版的另一端不一致，握手会报 `Client refused: version mismatch`。导出补丁请用 `git add -N` + `git diff`，不要提交。

## 构建产物的三条不变量

CI 每次都会断言，任何一条失败即视为坏包：

1. `product.json.version` 是**裸 `X.Y.Z`** 且等于指定的上游版本（带 `-`/`+` 后缀会让所有扩展被判不兼容）。
2. `product.json.serverDataFolderName` 为 `.vscode-server`：WSL 侧的数据根必须与官方 Remote-WSL 相同（`~/.vscode-server`），否则同一个发行版里两个扩展各写各的目录、用户数据分叉。
3. 产物里**没有 vsda**：server 只在存在 vsda 校验器时才强制客户端签名（`remoteExtensionHostAgentServer.ts:361` 的 `if (!validator) valid = true`），我们签不出微软签名，必须保持无 vsda 才能连上。

另外断言 iCode 确实进了包：`out/` 里能 grep 到 `PICKET_ICODE_BIN`（min 构建里字符串字面量会保留）。

## 手动构建

```bash
bash build/build-server.sh <source-ref> <版本> <上游 vscode 版本>
bash build/build-server.sh feat/picket-wsl 1.143.1 1.143.1
# 产物：release/picket-code-server-1.143.1-linux-x64.tar.gz
```

`source-ref` 是**客户端**的分支或 tag（补丁与扩展裁剪清单从那里取），`上游 vscode 版本` 是客户端所基于的 `microsoft/vscode` tag。

依赖：Node（`vscode/.nvmrc` 的版本）、Python 3、以及原生模块需要的系统库：

```bash
sudo apt-get install -y build-essential python3 libkrb5-dev libx11-dev \
  libxkbfile-dev libsecret-1-dev libxext-dev libxrender-dev libxrandr-dev
```

## 发布

手工触发 `.github/workflows/release-server.yml`，三个输入：

| 输入 | 必填 | 含义 |
|---|---|---|
| `version` | 是 | 服务端版本，裸 semver，例如 `1.143.1`；发布为 tag `server-v1.143.1` |
| `source_ref` | 是 | 客户端分支或 tag，载荷的补丁来源（例如 `feat/picket-wsl`、`v1.143.1-picket.1-rc.5`） |
| `vscode_version` | 是 | 客户端所基于的上游 tag，例如 `1.143.1` |

```bash
gh workflow run release-server.yml -R noware-cn/picket-code-server \
  -f version=1.143.1 -f source_ref=feat/picket-wsl -f vscode_version=1.143.1
```

**不再由 tag push 触发**：客户端的 tag 说明不了该产出哪个服务端版本。

流水线：`build` → `verify`（三条不变量 + `/version` 冒烟 + commit 断言）→ `release`（GitHub Release）→ `mirror`（R2 + 清理旧版本，保留最近 3 个新式版本）。

需要的 secrets：`R2_ACCESS_KEY_ID`、`R2_SECRET_ACCESS_KEY`、`R2_ENDPOINT`（与 picket-code 相同）。

## 客户端如何使用

Windows 客户端内置一个 resolver 扩展（不在本仓库）：

1. 从镜像取与 catalog 中同版本的包，校验 `SHA256SUMS`；
2. 解到 WSL 里（`~/.picket-code-server/payloads/server-<版本>/`），
   `wsl.exe -d <distro> -- …/bin/picket-code-server --port 0 --connection-token <t>`；
3. 按 `resolveAuthority` 返回 `authority + connectionToken`，之后由 `vscode-remote` 通道接管——工作区、监视、搜索、语言服务全部在 WSL 里。

## 历史版本

`v1.143.1-picket.1-rc.4` 及更早的 release 是改版前的形式（tag 与客户端同名、资产名带 `v`）。新的客户端取不到它们，仅作历史保留。

## 授权

构建输入是 MIT 许可的上游源码与我们自己的补丁，产物是我们自己的构建，不含微软签名的二进制。不提供、不分发任何微软发布的 server 包。
