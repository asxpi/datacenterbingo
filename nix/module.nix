# services.datacenterbingo: Puma on a port, for a proxy (Traefik on
# asxpio-ops) to route the public names to. Read-only: the bingo role and
# an S3 key that can only read the photo bucket.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.datacenterbingo;
  inherit (lib) mkOption types;
in
{
  options.services.datacenterbingo = {
    enable = lib.mkEnableOption "datacenterbingo.xyz";
    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "the datacenterbingo flake's package";
    };
    port = mkOption {
      type = types.port;
      default = 3002;
    };
    threads = mkOption {
      type = types.str;
      default = "4:16";
      description = "Puma's -t min:max.";
    };
    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        BINGO_HOST = "datacenterbingo.xyz";
        S3_ENDPOINT = "http://garage:3900";
        S3_REGION = "us-east-1";
        S3_BUCKET = "datacenterbingo-photos";
      };
      description = "Settings without secrets.";
    };
    environmentFile = mkOption {
      type = types.str;
      description = "DATABASE_URL, S3_ACCESS_KEY, S3_SECRET_KEY, INDEXNOW_KEY.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.datacenterbingo = {
      description = "datacenterbingo.xyz";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = cfg.environment;
      # Puma tells systemd when it listens
      serviceConfig = {
        Type = "notify";
        ExecStart = "${lib.getExe cfg.package} -b tcp://0.0.0.0:${toString cfg.port} -t ${cfg.threads}";
        EnvironmentFile = cfg.environmentFile;
        DynamicUser = true;
        Restart = "always";
        RestartSec = 5;
        TimeoutStartSec = 60;
        # The database may be down for a while; keep trying
        StartLimitIntervalSec = 0;
        MemoryMax = "384M";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallFilter = [ "@system-service" ];
        LockPersonality = true;
      };
    };
  };
}
