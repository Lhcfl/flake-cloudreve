# flake-cloudreve

Nix flake that packages [Cloudreve](https://cloudreve.org) and ships a NixOS
module for it. Built with [flake-parts](https://github.com/hercules-ci/flake-parts)
and exporting all supported systems.

Cloudreve is a self-hosted file management and sharing system that supports
multiple storage backends (local disk, S3, OneDrive, Google Drive, ...).

## What this flake exports

| Output | Description |
| --- | --- |
| `packages.<system>.cloudreve` | The Cloudreve server binary (repackaged upstream release). |
| `packages.<system>.default` | Alias for `packages.<system>.cloudreve`. |
| `nixosModules.default`, `nixosModules.cloudreve` | NixOS module exposing `services.cloudreve`. |
| `overlays.default` | Adds `pkgs.cloudreve` to nixpkgs. |

Supported systems: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`,
`aarch64-darwin`.

## Usage with NixOS

Add the flake as an input and import the module:

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

The module provides its own default `package`, so importing it is enough. If
you prefer to use the package from `pkgs`, add the overlay:

```nix
{
  nixpkgs.overlays = [ cloudreve.overlays.default ];
  services.cloudreve.package = pkgs.cloudreve; # optional, this is the default anyway
}
```

### Minimal configuration (SQLite)

```nix
services.cloudreve = {
  enable = true;
  settings = {
    "System.Listen" = "127.0.0.1:5212";
    "System.LogLevel" = "info";
  };
};
```

The service listens on `System.Listen` (default `:5212`). The **first user that
registers becomes the administrator**, so open `http://<host>:5212` and complete
the registration.

### Behind nginx with TLS

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

When `services.cloudreve.nginx.enable` is set, a virtual host proxying to the
port from `System.Listen` is generated.

### MariaDB/MySQL provisioned locally

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

With `createLocally = true`, `services.mysql` (MariaDB by default) is enabled,
the database and user are created, and a one-shot unit sets the user's password.

### External PostgreSQL

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

> Cloudreve 4.19 hard-codes `sslmode=disable` for PostgreSQL connections, so TLS
> to the database is not supported by the application yet.

## Options

The full option tree lives in `modules/cloudreve.nix`. The highlights:

- `services.cloudreve.enable` — enable the service.
- `services.cloudreve.package` — the Cloudreve package to use.
- `services.cloudreve.user` / `.group` — service account (default `cloudreve`).
- `services.cloudreve.stateDir` — data directory (default `/var/lib/cloudreve`).
- `services.cloudreve.settings` — free-form `conf.ini` values as an attrset of
  strings, keyed by `"Section.Key"`, e.g. `"System.Listen" = ":5212"`.
- `services.cloudreve.database.*` — typed database configuration
  (`type`, `host`, `port`, `name`, `user`, `password`, `passwordFile`,
  `charset`, `unixSocket`, `dbFile`, `createLocally`).
- `services.cloudreve.nginx.*` — optional nginx reverse proxy
  (`enable`, `host`, `enableACME`, `forceSSL`).

### `settings` vs. `database`

`settings` is the escape hatch for everything Cloudreve supports. It is flat:
keys must be `"Section.Key"`. Values are strings; if a value contains `#` or `;`
it is automatically wrapped in backticks so Cloudreve does not treat the rest of
the line as a comment.

The dedicated `database.*` options expand into the `[Database]` section and
**take precedence** over overlapping keys in `settings`. Use `database.*` for
the common cases and `settings` for anything else.

Secrets should be passed through `database.passwordFile`. The password is
injected at runtime via the `CR_CONF_Database__Password` environment variable
and never written to the world-readable Nix store.

Refer to the upstream configuration reference for all INI keys:
<https://docs.cloudreve.org/zh/overview/configure>.

## Using the package directly

```console
$ nix build .#cloudreve
$ ./result/bin/cloudreve --help
```

## Updating Cloudreve

1. Pick a new tag from <https://github.com/cloudreve/Cloudreve/releases>.
2. Update `version` and the `sources` hashes in `packages/cloudreve.nix`.
3. Verify with `nix build .#cloudreve`.

The sha256 hashes are published in the release's `checksums.txt` and can be
converted to SRI form, for example:

```console
$ curl -sL https://github.com/cloudreve/cloudreve/releases/download/<version>/checksums.txt
$ nix store prefetch-file --json --hash-type sha256 \
    https://github.com/cloudreve/cloudreve/releases/download/<version>/cloudreve_<version>_linux_amd64.tar.gz
```

## Repository layout

```
flake.nix                 # flake-parts entry point: packages, overlay, modules
packages/cloudreve.nix    # Cloudreve derivation
modules/cloudreve.nix     # NixOS module
AGENTS.md                 # instructions for automated agents
```

## License

The packaging code in this repository is provided as-is. Cloudreve itself is
licensed under the GNU GPL v3 (see the upstream project). The packaged binaries
are unmodified upstream release artifacts.
