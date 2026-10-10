# flake-cloudreve

用于打包 [Cloudreve](https://cloudreve.org) 并提供对应 NixOS 模块的 Nix flake。
基于 [flake-parts](https://github.com/hercules-ci/flake-parts) 构建，导出多个
system。

Cloudreve 是一个自托管的文件管理与分享系统，支持多种存储后端（本地磁盘、
S3、OneDrive、Google Drive 等）。

本 flake 提供**两个**包：

- `cloudreve` —— 从源码构建（Go 后端 + Web 前端），是默认包。
- `cloudreve-bin` —— 直接重新打包 GitHub release 的预编译二进制。

## 本 flake 导出的内容

| 输出 | 说明 |
| --- | --- |
| `packages.<system>.cloudreve` | 从源码构建的 Cloudreve。**默认。** |
| `packages.<system>.cloudreve-bin` | 重新打包的上游 release 二进制。 |
| `packages.<system>.default` | `packages.<system>.cloudreve` 的别名。 |
| `checks.<system>.cloudreve`、`checks.<system>.cloudreve-bin` | 冒烟测试：二进制能用临时 SQLite 启动，且 Web 前端确实已嵌入。 |
| `nixosModules.default`、`nixosModules.cloudreve` | 提供 `services.cloudreve` 的 NixOS 模块。 |
| `overlays.default` | 向 nixpkgs 添加 `pkgs.cloudreve` 和 `pkgs.cloudreve-bin`。 |

支持的 system：`x86_64-linux`、`aarch64-linux`、`x86_64-darwin`、
`aarch64-darwin`。源码包可在 Linux 和 macOS 上构建；二进制包覆盖上游发布
release 的所有平台。

## 在 NixOS 中使用

把本 flake 加为 input 并导入模块：

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    cloudreve.url = "github:your-username/flake-cloudreve";
  };

  outputs = { nixpkgs, cloudreve, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        cloudreve.nixosModules.default
        {
          services.cloudreve.enable = true;
        }
      ];
    };
  };
}
```

模块默认使用从源码构建的包。若想改用预编译二进制，加上 overlay 并指定：

```nix
{
  nixpkgs.overlays = [ cloudreve.overlays.default ];

  services.cloudreve.package = pkgs.cloudreve-bin;
}
```

### 最小配置（SQLite）

```nix
services.cloudreve = {
  enable = true;
  settings = {
    "System.Listen" = "127.0.0.1:5212";
    "System.LogLevel" = "info";
  };
};
```

服务监听 `System.Listen`（默认 `:5212`）。**第一个注册的用户会被设为管理员**，
因此请打开 `http://<host>:5212` 完成注册。

### 通过 nginx 反向代理并启用 TLS

```nix
services.cloudreve = {
  enable = true;
  nginx = {
    enable = true;
    host = "cloud.example.com";
    enableACME = true;
    forceSSL = true;
  };
  settings."System.ProxyHeader" = "X-Forwarded-For";
};
```

启用 `services.cloudreve.nginx.enable` 后，会生成一个反向代理到
`System.Listen` 端口的虚拟主机。

### 本地自动配置 MariaDB/MySQL

```nix
services.cloudreve = {
  enable = true;
  database = {
    type = "mysql";
    createLocally = true;
    passwordFile = "/run/secrets/cloudreve-db-password";
  };
};
```

`createLocally = true` 会启用 `services.mysql`（默认 MariaDB）、创建数据库和
用户，并用一个 oneshot 服务设置该用户的密码。

### 使用外部 PostgreSQL

```nix
services.cloudreve = {
  enable = true;
  database = {
    type = "postgres";
    host = "127.0.0.1";
    port = 5432;
    name = "cloudreve";
    user = "cloudreve";
    passwordFile = "/run/secrets/cloudreve-db-password";
  };
};
```

> Cloudreve 4.19 对 PostgreSQL 连接写死了 `sslmode=disable`，因此目前应用层面
> 还不支持连接数据库时启用 TLS。

## 配置项

完整配置项定义见 `modules/cloudreve.nix`，主要有：

- `services.cloudreve.enable` —— 是否启用服务。
- `services.cloudreve.package` —— 使用的 Cloudreve 包（默认是从源码构建的包）。
- `services.cloudreve.user` / `.group` —— 运行服务的用户/组（默认 `cloudreve`）。
- `services.cloudreve.stateDir` —— 数据目录（默认 `/var/lib/cloudreve`）。
- `services.cloudreve.settings` —— 自由的 `conf.ini` 配置，类型是
  `attrsOf str`，键使用 `"Section.Key"` 形式，例如 `"System.Listen" = ":5212"`。
- `services.cloudreve.database.*` —— 结构化的数据库配置
  （`type`、`host`、`port`、`name`、`user`、`password`、`passwordFile`、
  `charset`、`unixSocket`、`dbFile`、`createLocally`）。
- `services.cloudreve.nginx.*` —— 可选的 nginx 反向代理
  （`enable`、`host`、`enableACME`、`forceSSL`）。

### `settings` 与 `database` 的关系

`settings` 是覆盖 Cloudreve 所有配置的兜底入口，它是扁平的：键必须是
`"Section.Key"`。值都是字符串；如果值里包含 `#` 或 `;`，模块会自动用反引号
包裹，避免 Cloudreve 把后面的内容当注释。

专用的 `database.*` 配置会展开到 `[Database]` 段，且**优先级高于** `settings`
中的同名键。常见场景用 `database.*`，其他情况用 `settings`。

密码应通过 `database.passwordFile` 传入。密码会在运行时通过
`CR_CONF_Database__Password` 环境变量注入，不会写进全局可读的 Nix store。

所有 INI 配置项请参考上游文档：<https://docs.cloudreve.org/zh/overview/configure>。

## 直接使用包

```console
$ nix build .#cloudreve       # 从源码构建（默认）
$ nix build .#cloudreve-bin   # 预编译 release

$ ./result/bin/cloudreve --help
```

### 从源码构建

`cloudreve` 会用 `buildGoModule` 构建 Go 后端，并用 Yarn + Vite 构建 Web 前端
（由 release tag 关联的 `cloudreve/frontend` 子模块），再把产物 `assets.zip`
嵌入二进制。这是一个很重的构建（约 2000 个 npm 包 + 完整的 Go 依赖树），
首次构建耗时较长、占用数 GB 磁盘；之后会命中缓存。

前端 revision 固定在 `packages/cloudreve.nix`，必须与 Cloudreve tag 的
`assets` 子模块 revision 一致。

## 二进制缓存（Cachix）

本 flake 通过 `nixConfig`（`extra-substituters` / `extra-trusted-public-keys`）
推荐 `nix-community` 和 `lhcfl` 两个 Cachix 缓存。消费方开启
`accept-flake-config = true` 时会自动使用。

CI 会构建两个包并推送到 `lhcfl` 缓存。使用缓存：

```console
$ cachix use lhcfl
```

或不用 Cachix：

```console
$ nix build .#cloudreve \
    --extra-substituters https://nix-community.cachix.org \
    --extra-substituters https://lhcfl.cachix.org \
    --extra-trusted-public-keys "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=" \
    --extra-trusted-public-keys "lhcfl.cachix.org-1:hf4kin1zCbaeLWygZlwhYms/oqB0I8/8ZZsPkezpFms="
```

要让 CI 推送到 `lhcfl` 缓存，添加仓库 secret `CACHIX_AUTH_TOKEN` —— 一个对
`lhcfl` 有写权限的 Cachix token。不设置时 CI 只从缓存拉取，不推送。

CI 使用的缓存名直接写死在 `.github/workflows/ci.yml` 中。

## CI

`.github/workflows/ci.yml` 在 push、PR 和手动触发时运行。针对 `x86_64-linux`
和 `aarch64-linux` 构建两个包、执行 `nix flake check`（包含下面的冒烟测试），
并推送到 Cachix。

源码包的 fixed-output hash（`packages/cloudreve.nix` 里的 `fetchYarnDeps` 和
`vendorHash`）通过 CI 日志确定：构建因 hash 不匹配失败时，工作流会把
expected `got: sha256-...` 写入 job summary。把它填回对应字段再 push 即可。
最多两轮迭代后源码构建就能通过并被缓存。

### 冒烟测试

`nix flake check` 会构建 `checks.<system>.cloudreve` 和
`checks.<system>.cloudreve-bin`。每个检查会在 `127.0.0.1:0` 上用临时 SQLite
启动服务，并断言：

- 二进制能运行且打印出预期版本和短 commit —— 验证 `ldflags` 注入。commit 同时
  检查格式（`Commit #<7 位十六进制>`）和具体值，因此能捕获「构建输入泄漏进 linker
  flags」这类问题；
- 二进制中存在 `assets/build/index.html`、`assets/build/version.json` 和
  `assets/build/sw.js` —— 即 Web 前端确实被嵌入。否则 `assets.zip` 出问题时
  构建依然会「成功」，只在运行时才暴露。

## 自动更新

`scripts/update.sh` 可以把两个包更新到指定（或最新）的 Cloudreve 版本：

- `cloudreve-bin`：更新 `version`，并根据 release 的 `checksums.txt` 更新所有平台
  的 hash。
- `cloudreve`：更新 `version`、`rev`、`lastCommit`、固定的 `frontendRev` 以及源码
  hash，然后用 [nix-update](https://github.com/Mic92/nix-update) 刷新 Go 的
  `vendorHash` 和 Yarn 的 `offlineCache` hash。

在 dev shell 中运行：

```console
$ nix develop -c scripts/update.sh            # 最新 release，两个包
$ nix develop -c scripts/update.sh 4.20.0     # 指定版本，两个包
$ nix develop -c scripts/update.sh 4.20.0 bin
$ nix develop -c scripts/update.sh 4.20.0 src
```

`.github/workflows/update.yml` 会每天（以及手动触发时）运行该脚本，并创建或更新
一个 pull request。需要在仓库设置中开启 *Settings → Actions → General → Allow
GitHub Actions to create and approve pull requests*，否则无法创建 PR。

## 更新 Cloudreve

1. 在 <https://github.com/cloudreve/Cloudreve/releases> 选择新版本。
2. `packages/cloudreve-bin.nix`：更新 `version` 和 `sources` 里的哈希。
3. `packages/cloudreve.nix`：更新 `version`、`rev`、`lastCommit`、`frontendRev`
   （`assets` 子模块 revision）以及 fixed-output 哈希。
4. 用 `nix build .#cloudreve-bin` 和 `nix build .#cloudreve` 验证。

release 哈希可从 `checksums.txt` 获取；源码哈希可用以下命令重算：

```console
$ nix-prefetch-url --unpack \
    https://github.com/cloudreve/Cloudreve/archive/refs/tags/<version>.tar.gz
$ nix-prefetch-url --unpack \
    https://github.com/cloudreve/frontend/archive/<frontend-rev>.tar.gz
```

## 目录结构

```
flake.nix                  # flake-parts 入口：packages、overlay、modules
packages/cloudreve.nix     # 从源码构建（默认）
packages/cloudreve-bin.nix # 重新打包 release
modules/cloudreve.nix      # NixOS 模块
scripts/update.sh          # 版本更新脚本（nix-update）
.github/workflows/ci.yml   # GitHub Actions 构建 + Cachix
.github/workflows/update.yml # 定时更新 PR
AGENTS.md                  # 给自动化 agent 的指令
```

## 许可证

本仓库的打包代码使用 MIT 许可证（见 [`LICENSE`](./LICENSE)）。Cloudreve 本身
使用 GNU GPL v3 许可证（见上游项目）。`cloudreve-bin` 分发的为未经修改的上游
release 产物。
