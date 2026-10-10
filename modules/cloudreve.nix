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
    optional
    optionalAttrs
    types
    ;

  cfg = config.services.cloudreve;

  db = cfg.database;

  isSqlite = db.type == "sqlite";
  isMySql = db.type == "mysql" || db.type == "mariadb";
  isPostgres = db.type == "postgres";
  isLocalMySql = isMySql && db.createLocally;

  # Values containing the INI comment characters `#` or `;` have to be wrapped
  # in backticks, otherwise Cloudreve treats the rest of the line as a comment.
  # See https://docs.cloudreve.org/zh/overview/configure
  quoteValue =
    value: if lib.hasInfix "#" value || lib.hasInfix ";" value then "`${value}`" else value;

  # `settings` is a flat set of `"Section.Key" = "value"` pairs, while
  # `lib.generators.toINI` wants `{ Section = { Key = "value"; }; }`. Group the
  # flat keys into that shape.
  settingsToSections =
    settings:
    lib.mapAttrs (
      _: keys:
      lib.listToAttrs (
        map (key: {
          name = lib.concatStringsSep "." (lib.tail (lib.splitString "." key));
          value = quoteValue settings.${key};
        }) keys
      )
    ) (lib.groupBy (key: lib.head (lib.splitString "." key)) (lib.attrNames settings));

  userSections = settingsToSections cfg.settings;

  databaseSection = {
    Type = db.type;
  }
  // optionalAttrs isSqlite {
    DBFile = if db.dbFile != null then toString db.dbFile else "${cfg.stateDir}/cloudreve.db";
  }
  // optionalAttrs isMySql {
    Host = db.host;
    Port = toString db.port;
    User = db.user;
    Name = db.name;
    Charset = db.charset;
    UnixSocket = lib.boolToString db.unixSocket;
  }
  // optionalAttrs isPostgres {
    Host = db.host;
    Port = toString db.port;
    User = db.user;
    Name = db.name;
  }
  // optionalAttrs (db.passwordFile == null && db.password != "") {
    # Secrets passed through `database.passwordFile` are injected through the
    # `CR_CONF_Database__Password` environment variable at runtime instead.
    Password = quoteValue db.password;
  };

  # The dedicated `database` options win over overlapping keys in `settings`.
  sections = userSections // {
    Database = (userSections.Database or { }) // databaseSection;
  };

  configFile = pkgs.writeText "cloudreve.conf.ini" (lib.generators.toINI { } sections);

  listenPort =
    let
      listen = cfg.settings."System.Listen" or ":5212";
    in
    lib.toInt (lib.last (lib.splitString ":" listen));

  startScript = pkgs.writeShellScript "cloudreve-start" ''
    if [ -n "''${CREDENTIALS_DIRECTORY:-}" ] && [ -f "$CREDENTIALS_DIRECTORY/dbpass" ]; then
      export CR_CONF_Database__Password="$(cat "$CREDENTIALS_DIRECTORY/dbpass")"
    fi

    exec ${lib.getExe cfg.package} server -w -c ${lib.escapeShellArg "${cfg.stateDir}/conf.ini"}
  '';
in
{
  options.services.cloudreve = {
    enable = mkEnableOption "Cloudreve, a self-hosted file management and sharing system";

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

    settings = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = literalExpression ''
        {
          "System.Listen" = ":5212";
          "System.LogLevel" = "info";
          "System.ProxyHeader" = "X-Forwarded-For";
          "Redis.Server" = "127.0.0.1:6379";
        }
      '';
      description = ''
        Free-form Cloudreve configuration (`conf.ini`). Keys must use the
        `Section.Key` form, where `Section` and `Key` are the names of the INI
        section and option as documented at
        <https://docs.cloudreve.org/zh/overview/configure>.

        Every value is a string. Values that contain `#` or `;` are
        automatically wrapped in backticks.

        Options set through {option}`services.cloudreve.database` take
        precedence over overlapping keys defined here.
      '';
    };

    database = {
      type = mkOption {
        type = types.enum [
          "sqlite"
          "mysql"
          "mariadb"
          "postgres"
        ];
        default = "sqlite";
        description = ''
          Database backend to use. `sqlite` requires no additional setup, but is
          not recommended for production because it does not handle concurrent
          access well.
        '';
      };

      createLocally = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Provision the database locally. Currently only supported for
          `mysql`/`mariadb`, in which case {option}`services.mysql` is enabled
          and the database and user are created automatically.
        '';
      };

      name = mkOption {
        type = types.str;
        default = "cloudreve";
        description = "Name of the database.";
      };

      user = mkOption {
        type = types.str;
        default = "cloudreve";
        description = "Database user.";
      };

      password = mkOption {
        type = types.str;
        default = "";
        description = ''
          Password of the database user. Unlike
          {option}`services.cloudreve.database.passwordFile`, this stores the
          password in the world-readable Nix store and is therefore discouraged.
        '';
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/secrets/cloudreve-db-password";
        description = ''
          File containing the database password. The password is passed to
          Cloudreve at runtime and never written to the Nix store.
        '';
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Database host.";
      };

      port = mkOption {
        type = types.port;
        default = if isPostgres then 5432 else 3306;
        defaultText = literalExpression "3306";
        description = "Database port.";
      };

      charset = mkOption {
        type = types.str;
        default = "utf8mb4";
        description = "Connection charset (MySQL/MariaDB only).";
      };

      unixSocket = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Connect to MySQL/MariaDB through a Unix socket. When enabled,
          {option}`services.cloudreve.database.host` must be the socket path.
        '';
      };

      dbFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/var/lib/cloudreve/cloudreve.db";
        description = ''
          Path of the SQLite database file. Defaults to
          `''${stateDir}/cloudreve.db` when {option}`services.cloudreve.database.type`
          is `sqlite`.
        '';
      };
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
        assertion = lib.all (key: lib.hasInfix "." key) (lib.attrNames cfg.settings);
        message = ''
          services.cloudreve.settings keys must use the "Section.Key" form, e.g.
          "System.Listen" = ":5212".
        '';
      }
      {
        assertion = !db.createLocally || isMySql;
        message = ''
          services.cloudreve.database.createLocally is currently only supported
          for database.type = "mysql" or "mariadb".
        '';
      }
      {
        assertion = !isLocalMySql || db.passwordFile != null;
        message = ''
          services.cloudreve.database.passwordFile must be set when
          services.cloudreve.database.createLocally is enabled.
        '';
      }
      {
        assertion = cfg.nginx.enable -> cfg.nginx.host != null;
        message = "services.cloudreve.nginx.host must be set when nginx is enabled.";
      }
    ];

    users.users = optionalAttrs (cfg.user == "cloudreve") {
      cloudreve = {
        group = cfg.group;
        home = cfg.stateDir;
        isSystemUser = true;
      };
    };

    users.groups = optionalAttrs (cfg.group == "cloudreve") {
      cloudreve = { };
    };

    systemd.tmpfiles.settings."10-cloudreve".${cfg.stateDir}.d = {
      inherit (cfg) user group;
      mode = "0750";
    };

    systemd.services.cloudreve = {
      description = "Cloudreve file management and sharing system";
      documentation = [ "https://docs.cloudreve.org/" ];

      after = [ "network.target" ] ++ optional isLocalMySql "mysql.service";
      wants = optional isLocalMySql "mysql.service";
      wantedBy = [ "multi-user.target" ];

      preStart = ''
        ${pkgs.coreutils}/bin/install -m 0600 ${configFile} ${lib.escapeShellArg "${cfg.stateDir}/conf.ini"}
      '';

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        ExecStart = startScript;
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStopSec = 60;

        # Secrets
        LoadCredential = optional (db.passwordFile != null) "dbpass:${toString db.passwordFile}";

        # Hardening
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

    # Create the local MariaDB/MySQL user with a password, because NixOS
    # provisions local database users with socket authentication only.
    systemd.services.cloudreve-mysql-init = mkIf isLocalMySql {
      description = "Set up the Cloudreve database user and password";
      after = [ "mysql.service" ];
      requires = [ "mysql.service" ];
      wantedBy = [ "multi-user.target" ];
      before = [ "cloudreve.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        password="$(cat ${lib.escapeShellArg (toString db.passwordFile)})"
        ${config.services.mysql.package}/bin/mysql --skip-column-names --execute \
          "ALTER USER '${db.user}'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$password'); FLUSH PRIVILEGES;"
      '';
    };

    services.mysql = mkIf isLocalMySql {
      enable = true;
      package = lib.mkDefault pkgs.mariadb;
      ensureDatabases = [ db.name ];
      ensureUsers = [
        {
          name = db.user;
          ensurePermissions = {
            "${db.name}.*" = "ALL PRIVILEGES";
          };
        }
      ];
    };

    services.nginx = mkIf cfg.nginx.enable {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      virtualHosts.${cfg.nginx.host} = {
        enableACME = cfg.nginx.enableACME;
        forceSSL = cfg.nginx.forceSSL;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString listenPort}";
        };
      };
    };
  };
}
