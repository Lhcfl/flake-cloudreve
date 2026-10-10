# flake-cloudreve

用于打包 [Cloudreve](https://cloudreve.org) 并提供对应 NixOS 模块的 Nix flake。
基于 [flake-parts](https://github.com/hercules-ci/flake-parts) 构建，导出多个
system。

Cloudreve 是一个自托管的文件管理与分享系统，支持多种存储后端（本地磁盘、
S3、OneDrive、Google Drive 等）。

## 本 flake 导出的内容

| 输出 | 说明 |
| --- | --- |
| `packages.<system>.cloudreve` | Cloudreve 主程序（重新打包的上游 release）。 |
| `packages.<system>.default` | `packages.<system>.cloudreve` 的别名。 |
| `nixosModules.default`、`nixosModules.cloudreve` | 提供 `services.cloudreve` 的 NixOS 模块。 |
| `overlays.default` | 向 nixpkgs 添加 `pkgs.cloudreve`。 |

支持的 system：`x86_64-linux`、`aarch64-linux`、`x86_64-darwin`、
`aarch64-darwin`。

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

模块自带默认的 `package`，所以只要导入模块即可。如果你希望从 `pkgs` 中使用该
包，可以加上 overlay：

```nix
{
  nixpkgs.overlays = [ cloudreve.overlays.default ];
  services.cloudreve.package = pkgs.cloudreve; # 可选，本来就是默认值
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
- `services.cloudreve.package` —— 使用的 Cloudreve 包。
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

## 直接使用该包

```console
$ nix build .#cloudreve
$ ./result/bin/cloudreve --help
```

## 更新 Cloudreve

1. 在 <https://github.com/cloudreve/Cloudreve/releases> 选择新版本。
2. 修改 `packages/cloudreve.nix` 中的 `version` 和 `sources` 里的哈希。
3. 用 `nix build .#cloudreve` 验证。

哈希可以在 release 的 `checksums.txt` 中找到，并转换成 SRI 形式，例如：

```console
$ curl -sL https://github.com/cloudreve/cloudreve/releases/download/<version>/checksums.txt
$ nix store prefetch-file --json --hash-type sha256 \
    https://github.com/cloudreve/cloudreve/releases/download/<version>/cloudreve_<version>_linux_amd64.tar.gz
```

## 目录结构

```
flake.nix                 # flake-parts 入口：packages、overlay、modules
packages/cloudreve.nix    # Cloudreve 派生
modules/cloudreve.nix     # NixOS 模块
AGENTS.md                 # 给自动化 agent 的指令
```

## 许可证

本仓库的打包代码按原样提供。Cloudreve 本身使用 GNU GPL v3 许可证（见上游项
目）。打包的二进制为未经修改的上游 release 产物。
