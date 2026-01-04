# NixOS Module: FaceFusion Service

A robust, declarative NixOS module for deploying **FaceFusion** — the industry-leading next-generation face manipulation platform — using official Docker images with full GPU acceleration support.

This module provides production-grade isolation, resource management, health checking, and secure defaults while maintaining the purity and reproducibility of NixOS.

## Features

- **Declarative Docker deployment** via `docker-compose` generated from Nix configuration
- **GPU acceleration support**:
  - AMD ROCm (with `/dev/kfd` and `/dev/dri` passthrough)
  - NVIDIA CUDA and TensorRT
  - CPU-only fallback
- **Security hardening**:
  - Optional read-only root filesystem
  - `no-new-privileges`
  - Dedicated system user/group
  - Restricted group membership
- **Resource controls**:
  - Shared memory sizing
  - Memory limits
  - GPU allocation
- **Operational excellence**:
  - Health checks
  - Structured JSON logging with rotation
  - Comprehensive management script (`ff-stack`)
  - Systemd tmpfiles integration for state directories
- **Professional-grade management**:
  - Start/stop/restart/status/logs/pull/update/shell commands
  - Colorized output and helpful diagnostics

## Prerequisites

- NixOS 25.05 or later
- Docker enabled (`virtualisation.docker.enable = true;`)
- For ROCm: AMD GPU with appropriate drivers and membership in `video` and `render` groups
- For CUDA/TensorRT: NVIDIA GPU with container toolkit installed

## Installation

Save the module as `facefusion.nix` (or any name) in your configuration directory and import it in your NixOS configuration or flake.

### Example Flake Integration

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    # ... other inputs
  };

  outputs = { self, nixpkgs, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        ./facefusion.nix  # ← your module
        {
          services.facefusion = {
            enable = true;
            # ... your configuration
          };
        }
      ];
    };
  };
}
```

### Minimal Configuration Example

```nix
{
  services.facefusion = {
    enable = true;

    # Recommended for AMD 7040/8000 series laptops/workstations
    acceleration = "rocm";

    network = {
      bindAddress = "127.0.0.1";  # Change to "0.0.0.0" for LAN access
      port = 7860;
    };

    resources.shmSize = "16g";

    advanced.rocm.gfxVersionOverride = null;  # Set if needed, e.g. "11.0.3"
  };
}
```

Apply with:

```bash
sudo nixos-rebuild switch
```

## Usage

The module provides the `ff-stack` command (aliased to `ff`) for management:

```bash
ff start      # Start the service
ff logs       # Follow logs
ff status     # Show container status and health
ff restart    # Restart with current config
ff pull       # Pull latest image
ff update     # Pull and restart
ff shell      # Open bash inside container
ff stop       # Stop the service
```

The web UI will be available at `http://<bindAddress>:<port>` (default: http://127.0.0.1:7860).

Models are automatically downloaded on first use and stored persistently in `/var/lib/facefusion/models`.

## Configuration Options

| Option                              | Type                  | Default                  | Description                                                                 |
|-------------------------------------|-----------------------|--------------------------|-----------------------------------------------------------------------------|
| `enable`                            | bool                  | false                    | Enable the FaceFusion service                                               |
| `user` / `group`                    | string                | "facefusion"             | System user/group for state management                                      |
| `stateDirectory`                    | path                  | "/var/lib/facefusion"    | Base directory for models and compose files                                 |
| `image.registry`                    | string                | "docker.io"              | Container registry                                                          |
| `image.repository`                  | string                | "facefusion/facefusion"  | Image repository                                                            |
| `image.tag`                         | string                | "3.5.2"                  | Base image tag (acceleration suffix appended automatically)                 |
| `acceleration`                      | null or enum          | null                     | "rocm", "cuda", "tensorrt", or null for CPU                                 |
| `network.bindAddress`               | string                | "127.0.0.1"              | Interface to bind (use "0.0.0.0" for LAN)                                    |
| `network.port`                      | port                  | 7860                     | Host port                                                                   |
| `resources.shmSize`                 | string                | "8g"                     | Shared memory size                                                          |
| `resources.memoryLimit`             | string                | "32g"                    | Container memory limit                                                      |
| `resources.gpuCount`                | int or "all"          | "all"                    | GPUs to reserve (NVIDIA only)                                               |
| `security.readOnlyRootfs`           | bool                  | false                    | Run with read-only root filesystem                                          |
| `logging.maxSize` / `maxFiles`      | string / int          | "50m" / 3                | Log rotation settings                                                       |
| `advanced.rocm.gfxVersionOverride`  | null or string        | null                     | Override for unsupported ROCm GPUs                                          |
| `advanced.rocm.visibleDevices`      | string                | "0"                      | ROCR_VISIBLE_DEVICES value                                                  |

## Deployment on macOS and Other Linux Distributions

This module is specific to NixOS, but FaceFusion can be deployed on other platforms using Docker (Linux) or native installation (macOS recommended).

### Non-NixOS Linux (Docker)

Install Docker and docker-compose. Use this standalone `docker-compose.yml` (customize as needed):

```yaml
version: "3.8"

services:
  facefusion:
    image: facefusion/facefusion:3.5.2  # Append -rocm, -cuda, -tensorrt, or -cpu
    container_name: facefusion
    restart: unless-stopped
    ipc: host
    shm_size: 16g
    security_opt:
      - no-new-privileges:true
    # For ROCm (AMD):
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
    group_add:
      - video
      - render
    # For CUDA/TensorRT (NVIDIA):
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    volumes:
      - ~/.facefusion:/root/.facefusion
    ports:
      - "127.0.0.1:7860:7860"
    environment:
      - GRADIO_SERVER_NAME=0.0.0.0
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:7860/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
```

Run:

```bash
docker compose up -d
docker compose logs -f  # Monitor
```

Add user to `video`/`render` (ROCm) or install NVIDIA Container Toolkit (CUDA).

Check Docker Hub for latest tags: https://hub.docker.com/r/facefusion/facefusion/tags

### macOS

Official Docker images are linux/amd64 only → run emulated on Apple Silicon (slow, CPU-only, no GPU acceleration).

For best performance (especially Apple Silicon with onnxruntime optimizations):

- Follow the official macOS guide: https://docs.facefusion.io/installation/platform/macos
- Use Conda/Python native installation (supports improved Apple Silicon performance as of late 2025)
- Community one-click installers may be available via project releases or extras

Native installation provides better integration and performance on macOS.

## License

Copyright (c) 2026 DeMoD LLC. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
