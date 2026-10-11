{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkIf
    mkOption
    optionalAttrs
    types
    ;

  cfg = config.services.cloudreve;

  ini = pkgs.formats.ini {
    # Cloudreve reads a standard INI file (`[Section]` headers, `Key = value`).
    # It does however treat `#` and `;` as comment characters, so a value
    # containing either of them has to be wrapped in backticks.
    # See https://docs.cloudreve.org/zh/overview/configure
    mkKeyValue =
      key: value:
      let
        rendered = lib.generators.mkValueStringDefault { } value;
      in
      "${key} = "
      + (if lib.hasInfix "#" rendered || lib.hasInfix ";" rendered then "`${rendered}`" else rendered);
  };

  unixsocket = "${cfg.stateDir}/clodureve.socket";
in
{
  options.services.cloudreve = {
    enable = mkEnableOption "Cloudreve, a self-hosted file management and sharing system";

    enableExtraPackages = mkEnableOption ''
      Enable ffmpeg, vips, and etc for thumbnail generation
    '';

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../packages/cloudreve.nix { };
      defaultText = literalExpression "pkgs.callPackage ../packages/cloudreve.nix { }";
      description = "The Cloudreve package to use.";
    };

    user = mkOption {
      type = types.str;
      default = "cloudreve";
      description = "User account under which Cloudreve runs.";
    };

    group = mkOption {
      type = types.str;
      default = "cloudreve";
      description = "Group under which Cloudreve runs.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/cloudreve";
      description = "Directory where Cloudreve stores its data (SQLite database, uploads, ...).";
    };

    port = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "HTTP port to listen. If left empty, unix socket will be used.";
    };

    settings = mkOption {
      type = ini.type;
      default = { };
      example = {
        System = {
          Listen = ":5212";
          LogLevel = "info";
          ProxyHeader = "X-Forwarded-For";
        };
        Redis.Server = "127.0.0.1:6379";
      };
      description = ''
        The primary cloudreve configuration. See the <https://docs.cloudreve.org/en/overview/configure> for possible values.

        Secrets **should** be passed in by using the `environmentFile` option.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Environment file for cloudreve. Secrets **should** be passed in by using this option.

        See <https://docs.cloudreve.org/en/overview/configure#override-config-env>
      '';
    };

    nginx = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to set up an nginx reverse proxy for Cloudreve.";
      };

      host = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "cloud.example.com";
        description = "Host name served by the nginx virtual host.";
      };

      enableACME = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to obtain an ACME certificate for the host.";
      };

      forceSSL = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to redirect all HTTP traffic to HTTPS.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.nginx.enable -> cfg.nginx.host != null;
        message = "services.cloudreve.nginx.host must be set when nginx is enabled.";
      }
    ];

    # add port to settings
    services.cloudreve.settings = {
      System.Listen = lib.mkIf (cfg.port != null) ":${toString cfg.port}";
      UnixSocket.Listen = lib.mkIf (cfg.port == null) unixsocket;
    };

    users = {
      users = optionalAttrs (cfg.user == "cloudreve") {
        cloudreve = {
          group = cfg.group;
          home = cfg.stateDir;
          isSystemUser = true;
        };
      };

      groups = optionalAttrs (cfg.group == "cloudreve") {
        cloudreve = { };
      };
    };

    systemd.tmpfiles.settings."10-cloudreve".${cfg.stateDir}.d = {
      inherit (cfg) user group;
      mode = "0750";
    };

    systemd.services.cloudreve = {
      description = "Cloudreve file management and sharing system";
      documentation = [ "https://docs.cloudreve.org/" ];

      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      path = lib.mkIf (cfg.enableExtraPackages) (
        with pkgs;
        [
          ffmpeg
          vips
          libreoffice
          libraw
        ]
      );

      script = "${lib.getExe cfg.package} server -w -c ${ini.generate "conf.ini" cfg.settings}";

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStopSec = 60;
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.stateDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
      };
    };

    services.nginx = mkIf cfg.nginx.enable {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      virtualHosts.${cfg.nginx.host} = {
        enableACME = cfg.nginx.enableACME;
        forceSSL = cfg.nginx.forceSSL;
        locations."/" = lib.mkMerge [
          (lib.mkIf (cfg.port != null) {
            proxyPass = "http://127.0.0.1:${toString cfg.port}";
          })
          (lib.mkIf (cfg.port == null) {
            proxyPass = "http://unix:/${unixsocket}:/";
          })
        ];
      };
    };
  };
}
