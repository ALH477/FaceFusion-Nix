## Copyright DeMoD LLC
## Licensed under BSD-3
### FaceFusion Nix Flake 
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.facefusion;

  # Resolve user configuration
  runUser = cfg.user;
  runGroup = cfg.group;
  userHome = config.users.users.${runUser}.home or "/home/${runUser}";

  paths = {
    stateDir = cfg.stateDirectory;
    models = "${cfg.stateDirectory}/models";
    compose = "${cfg.stateDirectory}/compose";
  };

  effectiveAcceleration = cfg.acceleration;
  isRocm = effectiveAcceleration == "rocm";
  isCuda = effectiveAcceleration == "cuda";
  isTensorRT = effectiveAcceleration == "tensorrt";
  isGpu = isRocm || isCuda || isTensorRT;

  tagSuffix = optionalString (effectiveAcceleration != null) "-${effectiveAcceleration}";
  facefusionImage = "${cfg.image.registry}/${cfg.image.repository}:${cfg.image.tag}${tagSuffix}";

  # Build environment variables as proper attribute set, then serialize
  containerEnv = {
    GRADIO_SERVER_NAME = "0.0.0.0";
  } // optionalAttrs isRocm {
    ROCR_VISIBLE_DEVICES = cfg.advanced.rocm.visibleDevices;
  } // optionalAttrs (isRocm && cfg.advanced.rocm.gfxVersionOverride != null) {
    HSA_OVERRIDE_GFX_VERSION = cfg.advanced.rocm.gfxVersionOverride;
  };

  envToYaml = env: concatStringsSep "\n" (
    mapAttrsToList (k: v: "          ${k}: \"${v}\"") env
  );

  dockerComposeYml = pkgs.writeText "docker-compose.yml" ''
    version: "3.8"

    services:
      facefusion:
        image: ${facefusionImage}
        container_name: facefusion
        restart: unless-stopped
        ipc: host
        shm_size: "${cfg.resources.shmSize}"
        
        security_opt:
          - no-new-privileges:true
        ${optionalString cfg.security.readOnlyRootfs ''
        read_only: true
        ''}
        
        ${optionalString isRocm ''
        devices:
          - "/dev/kfd:/dev/kfd"
          - "/dev/dri:/dev/dri"
        group_add:
          - video
          - render
        ''}
        
        ${optionalString isGpu ''
        deploy:
          resources:
            ${optionalString (isCuda || isTensorRT) ''
            reservations:
              devices:
                - driver: nvidia
                  count: ${toString cfg.resources.gpuCount}
                  capabilities: [gpu]
            ''}
            limits:
              memory: ${cfg.resources.memoryLimit}
        ''}
        
        volumes:
          - ${paths.models}:/root/.facefusion
          ${optionalString cfg.security.readOnlyRootfs ''
          - /tmp
          ''}
        
        ports:
          - "${cfg.network.bindAddress}:${toString cfg.network.port}:7860"
        
        environment:
${envToYaml containerEnv}
        
        healthcheck:
          test: ["CMD", "curl", "-f", "http://localhost:7860/"]
          interval: 30s
          timeout: 10s
          retries: 3
          start_period: 60s
        
        logging:
          driver: "json-file"
          options:
            max-size: "${cfg.logging.maxSize}"
            max-file: "${toString cfg.logging.maxFiles}"
  '';

  ffStackScript = pkgs.writeShellScriptBin "ff-stack" ''
    set -euo pipefail

    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m'

    error() { echo -e "''${RED}[ERROR]''${NC} $*" >&2; }
    success() { echo -e "''${GREEN}[OK]''${NC} $*"; }
    warn() { echo -e "''${YELLOW}[WARN]''${NC} $*"; }
    info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }

    require_docker_group() {
      if ! groups | grep -qw docker; then
        error "Current user not in 'docker' group. Run: sudo usermod -aG docker $USER && newgrp docker"
        exit 1
      fi
    }

    readonly COMPOSE_DIR="${paths.compose}"
    readonly COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

    ensure_dirs() {
      mkdir -p "${paths.compose}" "${paths.models}"
    }

    deploy_compose() {
      local src="${dockerComposeYml}"
      if [ ! -f "$COMPOSE_FILE" ] || ! diff -q "$src" "$COMPOSE_FILE" >/dev/null 2>&1; then
        cp "$src" "$COMPOSE_FILE"
        info "Compose configuration updated"
        return 0
      fi
      return 1
    }

    cmd_start() {
      require_docker_group
      ensure_dirs
      deploy_compose || true
      cd "$COMPOSE_DIR"
      docker compose up -d --remove-orphans
      success "FaceFusion starting at http://${cfg.network.bindAddress}:${toString cfg.network.port}"
      info "Run 'ff-stack logs' to watch startup progress"
    }

    cmd_stop() {
      cd "$COMPOSE_DIR" 2>/dev/null || { warn "Not running"; return 0; }
      docker compose down --timeout 30
      success "FaceFusion stopped"
    }

    cmd_restart() {
      cmd_stop
      cmd_start
    }

    cmd_status() {
      cd "$COMPOSE_DIR" 2>/dev/null || { echo "Not deployed"; exit 1; }
      docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
      echo
      if docker compose exec -T facefusion curl -sf http://localhost:7860/ >/dev/null 2>&1; then
        success "Health: OK"
      else
        warn "Health: Unhealthy or starting"
      fi
    }

    cmd_logs() {
      cd "$COMPOSE_DIR" 2>/dev/null || { error "Not deployed"; exit 1; }
      docker compose logs -f --tail=100 facefusion
    }

    cmd_pull() {
      require_docker_group
      ensure_dirs
      deploy_compose || true
      cd "$COMPOSE_DIR"
      docker compose pull
      success "Image pulled: ${facefusionImage}"
    }

    cmd_update() {
      cmd_pull
      cmd_restart
    }

    cmd_shell() {
      cd "$COMPOSE_DIR" 2>/dev/null || { error "Not deployed"; exit 1; }
      docker compose exec facefusion /bin/bash
    }

    show_help() {
      cat <<EOF
    FaceFusion Stack Manager

    Usage: ff-stack <command>

    Commands:
      start, up     Start FaceFusion container
      stop, down    Stop FaceFusion container
      restart       Restart container with latest config
      status        Show container status and health
      logs          Follow container logs
      pull          Pull latest image
      update        Pull and restart
      shell         Open shell in container
      help          Show this help

    Image: ${facefusionImage}
    State: ${paths.stateDir}
    EOF
    }

    case "''${1:-help}" in
      start|up)      cmd_start ;;
      stop|down)     cmd_stop ;;
      restart)       cmd_restart ;;
      status)        cmd_status ;;
      logs)          cmd_logs ;;
      pull)          cmd_pull ;;
      update)        cmd_update ;;
      shell|sh)      cmd_shell ;;
      help|--help|-h) show_help ;;
      *)
        error "Unknown command: $1"
        show_help
        exit 1
        ;;
    esac
  '';

in
{
  options.services.facefusion = {
    enable = mkEnableOption "FaceFusion face manipulation platform via Docker";

    user = mkOption {
      type = types.str;
      default = "facefusion";
      description = "User account to run FaceFusion management commands";
    };

    group = mkOption {
      type = types.str;
      default = "facefusion";
      description = "Group for FaceFusion files";
    };

    stateDirectory = mkOption {
      type = types.path;
      default = "/var/lib/facefusion";
      description = "Directory for FaceFusion state, models, and compose files";
    };

    image = {
      registry = mkOption {
        type = types.str;
        default = "docker.io";
        description = "Container registry";
      };

      repository = mkOption {
        type = types.str;
        default = "facefusion/facefusion";
        description = "Image repository";
      };

      tag = mkOption {
        type = types.str;
        default = "3.5.2";
        description = "Image tag (acceleration suffix added automatically)";
      };
    };

    acceleration = mkOption {
      type = types.nullOr (types.enum [ "rocm" "cuda" "tensorrt" ]);
      default = null;
      description = "GPU acceleration backend. null for CPU-only.";
    };

    network = {
      bindAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Listen address. Use 0.0.0.0 for LAN access.";
      };

      port = mkOption {
        type = types.port;
        default = 7860;
        description = "Host port for web UI";
      };
    };

    resources = {
      shmSize = mkOption {
        type = types.str;
        default = "8g";
        description = "Shared memory size (for model loading)";
      };

      memoryLimit = mkOption {
        type = types.str;
        default = "32g";
        description = "Container memory limit";
      };

      gpuCount = mkOption {
        type = types.either types.int (types.enum [ "all" ]);
        default = "all";
        description = "Number of GPUs to allocate (NVIDIA only)";
      };
    };

    security = {
      readOnlyRootfs = mkOption {
        type = types.bool;
        default = false;
        description = "Run container with read-only root filesystem";
      };
    };

    logging = {
      maxSize = mkOption {
        type = types.str;
        default = "50m";
        description = "Maximum log file size";
      };

      maxFiles = mkOption {
        type = types.int;
        default = 3;
        description = "Number of log files to retain";
      };
    };

    advanced.rocm = {
      gfxVersionOverride = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "HSA_OVERRIDE_GFX_VERSION for unsupported GPUs";
        example = "11.0.3";
      };

      visibleDevices = mkOption {
        type = types.str;
        default = "0";
        description = "ROCR_VISIBLE_DEVICES value";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.acceleration != "tensorrt" || cfg.acceleration == "cuda";
        message = "TensorRT requires CUDA-capable hardware";
      }
    ];

    # Ensure docker is available
    virtualisation.docker.enable = true;

    # Create dedicated user/group if using defaults
    users.users.${runUser} = mkIf (cfg.user == "facefusion") {
      isSystemUser = true;
      group = runGroup;
      home = "/var/lib/facefusion";
      extraGroups = [ "docker" ] ++ optionals isRocm [ "video" "render" ];
    };

    users.groups.${runGroup} = mkIf (cfg.group == "facefusion") {};

    # For non-default users, just add to docker group
    users.users.${runUser}.extraGroups = mkIf (cfg.user != "facefusion")
      ([ "docker" ] ++ optionals isRocm [ "video" "render" ]);

    systemd.tmpfiles.rules = [
      "d ${paths.stateDir} 0750 ${runUser} ${runGroup} -"
      "d ${paths.models} 0750 ${runUser} ${runGroup} -"
      "d ${paths.compose} 0750 ${runUser} ${runGroup} -"
    ];

    environment.systemPackages = [
      pkgs.docker-compose
      ffStackScript
    ] ++ optionals isRocm [
      pkgs.rocmPackages.rocm-smi
      pkgs.rocmPackages.rocminfo
    ];

    networking.firewall.allowedTCPPorts =
      mkIf (cfg.network.bindAddress != "127.0.0.1") [ cfg.network.port ];

    environment.shellAliases = {
      ff = "ff-stack";
    };
  };
}
