# flake-cloudreve

Nix flake that packages [Cloudreve](https://cloudreve.org) and ships a NixOS
module for it. Built with [flake-parts](https://github.com/hercules-ci/flake-parts)
and exporting all supported systems.

Cloudreve is a self-hosted file management and sharing system that supports
multiple storage backends (local disk, S3, OneDrive, Google Drive, ...).

This flake provides **two** packages:

- `cloudreve` — built from source (Go backend + web frontend), and the default.
- `cloudreve-bin` — repackaged from the official GitHub release tarball.

## What this flake exports

| Output | Description |
| --- | --- |
| `packages.<system>.cloudreve` | Cloudreve built from source. **Default.** |
| `packages.<system>.cloudreve-bin` | Cloudreve repackaged from the upstream release binary. |
| `packages.<system>.default` | Alias for `packages.<system>.cloudreve`. |
| `nixosModules.default`, `nixosModules.cloudreve` | NixOS module exposing `services.cloudreve`. |
| `overlays.default` | Adds `pkgs.cloudreve` and `pkgs.cloudreve-bin` to nixpkgs. |

Supported systems: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`,
`aarch64-darwin`. The from-source package builds on Linux and macOS; the binary
package covers the systems for which upstream publishes a release.

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

The module defaults to the from-source package. To use the prebuilt release
binary instead, add the overlay and select it:

```nix
{
  nixpkgs.overlays = [ cloudreve.overlays.default ];

  # The module imports its own default, so point it at the overlay package.
  services.cloudreve.package = pkgs.cloudreve-bin;
}
```

### Minimal configuration (SQLite)

```nix
services.cloudreve = {
  enable = true;
  settings = {
    System = {
      Listen = "127.0.0.1:5212";
      LogLevel = "info";
    };
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
  settings.System.ProxyHeader = "X-Forwarded-For";
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
- `services.cloudreve.package` — the Cloudreve package to use (defaults to the
  from-source package).
- `services.cloudreve.user` / `.group` — service account (default `cloudreve`).
- `services.cloudreve.stateDir` — data directory (default `/var/lib/cloudreve`).
- `services.cloudreve.settings` — free-form `conf.ini` configuration as nested
  INI sections, e.g. `settings.System.Listen = ":5212"` or
  `settings.Redis.Server = "127.0.0.1:6379"`. Values may be strings, integers,
  floats, booleans or null.
- `services.cloudreve.database.*` — typed database configuration
  (`type`, `host`, `port`, `name`, `user`, `password`, `passwordFile`,
  `charset`, `unixSocket`, `dbFile`, `createLocally`).
- `services.cloudreve.nginx.*` — optional nginx reverse proxy
  (`enable`, `host`, `enableACME`, `forceSSL`).

### `settings` vs. `database`

`settings` is the escape hatch for everything Cloudreve supports. It maps onto
the INI structure directly: each attribute set is a `[Section]` and its keys are
the options in it.

Values may be strings, integers, floats, booleans or null. If a value contains
`#` or `;` it is automatically wrapped in backticks so Cloudreve does not treat
the rest of the line as a comment.

The dedicated `database.*` options expand into the `[Database]` section and
**take precedence** over overlapping keys in `settings`. Use `database.*` for
the common cases and `settings` for anything else.

Secrets should be passed through `database.passwordFile`. The password is
injected at runtime via the `CR_CONF_Database__Password` environment variable
and never written to the world-readable Nix store.

Refer to the upstream configuration reference for all INI keys:
<https://docs.cloudreve.org/zh/overview/configure>.

## Using the packages directly

```console
$ nix build .#cloudreve       # from source (default)
$ nix build .#cloudreve-bin   # prebuilt release

$ ./result/bin/cloudreve --help
```

### Building from source

`cloudreve` builds the Go backend with `buildGoModule` and builds the web
frontend (the `cloudreve/frontend` submodule pinned by the release tag) with
Yarn and Vite, then embeds the resulting `assets.zip`. This is a heavy build
(`~2000` npm packages plus the full Go dependency tree), so expect the first
build to take a while and use several GB of disk. The result is cached
afterwards.

The frontend revision is pinned in `packages/cloudreve.nix` and must match the
`assets` submodule revision of the Cloudreve tag.

## Binary cache (Cachix)

The flake recommends the `nix-community` and `lhcfl` Cachix caches through
`nixConfig` (`extra-substituters` / `extra-trusted-public-keys`). They are used
automatically when the consumer enables `accept-flake-config = true`.

CI builds both packages and pushes them to the `lhcfl` cache. To consume it
explicitly:

```console
$ cachix use lhcfl
```

or without Cachix:

```console
$ nix build .#cloudreve \
    --extra-substituters https://nix-community.cachix.org \
    --extra-substituters https://lhcfl.cachix.org \
    --extra-trusted-public-keys "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=" \
    --extra-trusted-public-keys "lhcfl.cachix.org-1:hf4kin1zCbaeLWygZlwhYms/oqB0I8/8ZZsPkezpFms="
```

To let CI push to the `lhcfl` cache, add the repository secret
`CACHIX_AUTH_TOKEN` — a Cachix auth token with write access to `lhcfl`. Without
it, CI only pulls from the cache and does not push.

The cache name used by CI is set directly in `.github/workflows/ci.yml`.

## CI

`.github/workflows/ci.yml` runs on pushes, pull requests and manual dispatch.
For `x86_64-linux` and `aarch64-linux` it builds both packages and pushes
everything to the Cachix cache.

The from-source package's fixed-output hashes (`fetchYarnDeps` and
`vendorHash` in `packages/cloudreve.nix`) are discovered from the CI logs: when
a build fails with a hash mismatch, the workflow writes the expected
`got: sha256-...` value to the job summary. Copy it into the corresponding
field and push again. After at most two iterations the source build passes and
is cached.

## Automatic updates

`scripts/update.sh` updates the packages to a given (or the latest) Cloudreve
release:

- `cloudreve-bin`: bumps `version` and all per-platform hashes from the
  release's `checksums.txt`.
- `cloudreve`: bumps `version`, `rev`, `lastCommit`, the pinned `frontendRev` and
  the source hashes, then uses
  [nix-update](https://github.com/Mic92/nix-update) to refresh the Go
  `vendorHash` and the Yarn `offlineCache` hash.

Run it from the dev shell:

```console
$ nix develop -c scripts/update.sh            # latest release, both packages
$ nix develop -c scripts/update.sh 4.20.0     # explicit version, both packages
$ nix develop -c scripts/update.sh 4.20.0 bin
$ nix develop -c scripts/update.sh 4.20.0 src
```

`.github/workflows/update.yml` runs the script daily (and on manual dispatch)
and opens or updates a pull request with the result. The repository setting
*Settings → Actions → General → Allow GitHub Actions to create and approve pull
requests* must be enabled for the PR to be created.

## Updating Cloudreve

1. Pick a new tag from <https://github.com/cloudreve/Cloudreve/releases>.
2. `packages/cloudreve-bin.nix`: update `version` and the `sources` hashes.
3. `packages/cloudreve.nix`: update `version`, `rev`, `lastCommit`, `frontendRev`
   (the `assets` submodule revision) and the fixed-output hashes.
4. Verify with `nix build .#cloudreve-bin` and `nix build .#cloudreve`.

The release hashes are published in the release's `checksums.txt`; the source
hashes can be recomputed with:

```console
$ nix store prefetch-file --json --hash-type sha256 \
    https://github.com/cloudreve/Cloudreve/releases/download/<version>/cloudreve_<version>_linux_amd64.tar.gz
$ nix-prefetch-url --unpack \
    https://github.com/cloudreve/Cloudreve/archive/refs/tags/<version>.tar.gz
$ nix-prefetch-url --unpack \
    https://github.com/cloudreve/frontend/archive/<frontend-rev>.tar.gz
```

## Repository layout

```
flake.nix                  # flake-parts entry point: packages, overlay, modules
packages/cloudreve.nix     # from-source build (default)
packages/cloudreve-bin.nix # prebuilt release repackaging
modules/cloudreve.nix      # NixOS module
scripts/update.sh          # release updater (nix-update)
.github/workflows/ci.yml   # GitHub Actions build + Cachix
.github/workflows/update.yml # scheduled update PR
AGENTS.md                  # instructions for automated agents
```

## License

The packaging code in this repository is licensed under the MIT License (see
[`LICENSE`](./LICENSE)). Cloudreve itself is licensed under the GNU GPL v3 (see
the upstream project). The `cloudreve-bin` package redistributes unmodified
upstream release artifacts.
