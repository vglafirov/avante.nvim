# Docker Setup for GitLab Duo Workflow

GitLab Duo Workflow requires Docker to execute workflows. This document explains how to configure Docker for the provider.

## Why Docker is Needed

GitLab Duo Workflow uses Docker as an execution platform where it can:
- Execute arbitrary code
- Read and write files
- Make API calls to GitLab
- Run tools and commands in isolated environments

## Automatic Docker Detection

The provider automatically detects Docker socket paths based on your operating system and container manager:

### macOS
The provider checks these locations in order:
1. `~/.colima/default/docker.sock` (Colima)
2. `~/.rd/docker.sock` (Rancher Desktop)
3. `~/.docker/run/docker.sock` (Docker Desktop)
4. `/var/run/docker.sock` (Standard location)

### Linux
The provider checks these locations in order:
1. `/var/run/docker.sock` (Standard location)
2. `~/.docker/desktop/docker.sock` (Docker Desktop)

## Manual Docker Configuration

If the automatic detection doesn't work, you can manually specify the Docker socket path using an environment variable:

```bash
export GITLAB_DOCKER_SOCKET="/path/to/docker.sock"
```

### Common Docker Socket Paths

#### Colima (macOS)
```bash
export GITLAB_DOCKER_SOCKET="$HOME/.colima/default/docker.sock"
```

#### Rancher Desktop (macOS)
```bash
export GITLAB_DOCKER_SOCKET="$HOME/.rd/docker.sock"
```

#### Docker Desktop (macOS)
```bash
export GITLAB_DOCKER_SOCKET="$HOME/.docker/run/docker.sock"
```

#### Docker Desktop (Linux)
```bash
export GITLAB_DOCKER_SOCKET="$HOME/.docker/desktop/docker.sock"
```

#### Standard Docker (Linux)
```bash
export GITLAB_DOCKER_SOCKET="/var/run/docker.sock"
```

## Installing Docker

### macOS

#### Option 1: Colima (Recommended)
Colima is a lightweight Docker runtime for macOS:

```bash
# Install via Homebrew
brew install colima docker

# Start Colima
colima start

# Verify Docker is running
docker ps
```

The Docker socket will be at: `~/.colima/default/docker.sock`

#### Option 2: Rancher Desktop
Download and install from: https://rancherdesktop.io/

The Docker socket will be at: `~/.rd/docker.sock`

#### Option 3: Docker Desktop
Download and install from: https://www.docker.com/products/docker-desktop

The Docker socket will be at: `~/.docker/run/docker.sock`

### Linux

#### Ubuntu/Debian
```bash
# Install Docker
sudo apt-get update
sudo apt-get install docker.io

# Start Docker service
sudo systemctl start docker
sudo systemctl enable docker

# Add your user to docker group (to avoid sudo)
sudo usermod -aG docker $USER
newgrp docker

# Verify Docker is running
docker ps
```

The Docker socket will be at: `/var/run/docker.sock`

#### Fedora/RHEL/CentOS
```bash
# Install Docker
sudo dnf install docker

# Start Docker service
sudo systemctl start docker
sudo systemctl enable docker

# Add your user to docker group
sudo usermod -aG docker $USER
newgrp docker

# Verify Docker is running
docker ps
```

## Verifying Docker Setup

After installing Docker, verify it's working:

```bash
# Check Docker is running
docker ps

# Check socket file exists
ls -la ~/.colima/default/docker.sock  # Colima
# or
ls -la ~/.rd/docker.sock              # Rancher Desktop
# or
ls -la /var/run/docker.sock           # Standard Docker
```

## Configuration in Neovim

Add the Docker socket path to your shell profile (`.bashrc`, `.zshrc`, etc.):

```bash
# For Colima
export GITLAB_DOCKER_SOCKET="$HOME/.colima/default/docker.sock"

# For Rancher Desktop
export GITLAB_DOCKER_SOCKET="$HOME/.rd/docker.sock"

# For Docker Desktop
export GITLAB_DOCKER_SOCKET="$HOME/.docker/run/docker.sock"

# For standard Docker
export GITLAB_DOCKER_SOCKET="/var/run/docker.sock"
```

Then restart Neovim.

## Troubleshooting

### Error: "Docker socket not configured"

This error means the provider couldn't find a Docker socket. To fix:

1. **Check Docker is installed and running:**
   ```bash
   docker ps
   ```

2. **Check socket file exists:**
   ```bash
   # For Colima
   ls -la ~/.colima/default/docker.sock

   # For Rancher Desktop
   ls -la ~/.rd/docker.sock

   # For standard Docker
   ls -la /var/run/docker.sock
   ```

3. **Manually configure the socket path:**
   ```bash
   export GITLAB_DOCKER_SOCKET="/path/to/docker.sock"
   ```

4. **Restart Neovim** to pick up the environment variable.

### Error: "Permission denied" accessing Docker socket

If you get permission errors:

#### Linux
Add your user to the docker group:
```bash
sudo usermod -aG docker $USER
newgrp docker
```

#### macOS
Usually not needed with Colima or Rancher Desktop. If using Docker Desktop, ensure it's running with your user account.

### Docker socket not found automatically

If the provider can't find your Docker socket automatically:

1. **Find your Docker socket manually:**
   ```bash
   # Check common locations
   find ~ -name "docker.sock" 2>/dev/null
   ```

2. **Set the environment variable:**
   ```bash
   export GITLAB_DOCKER_SOCKET="/path/to/docker.sock"
   ```

3. **Add to your shell profile** (`.bashrc`, `.zshrc`, etc.) to make it permanent.

### Workflow still fails after Docker setup

If Docker is configured but workflows still fail:

1. **Check Docker is accessible:**
   ```bash
   docker ps
   ```

2. **Check GitLab token is set:**
   ```bash
   echo $GITLAB_TOKEN
   ```

3. **Enable debug mode** in Avante:
   ```lua
   require('avante').setup({
     debug = true,
     provider = "gitlab_duo",
   })
   ```

4. **Check debug logs** for Docker-related errors:
   ```vim
   :messages
   ```

## Limited Functionality Without Docker

If Docker is not available, the provider will show a warning:

```
Docker socket not found. Workflow may have limited functionality.
Set GITLAB_DOCKER_SOCKET env var to specify Docker socket path.
```

**What works without Docker:**
- Basic chat interactions
- Simple code explanations
- Code suggestions

**What doesn't work without Docker:**
- Complex workflows requiring code execution
- Tool usage (file operations, command execution)
- Multi-step workflows
- Code generation and testing

## Security Considerations

### Docker Socket Access

Mounting the Docker socket gives the workflow access to your Docker daemon. This means:

- Workflows can create/delete containers
- Workflows can access files on your system
- Workflows run with your Docker permissions

**Recommendations:**
1. Only use workflows from trusted sources
2. Review workflow plans before approving them
3. Use the "Approve Once" option for tool approvals
4. Monitor Docker activity during workflow execution

### Isolation

GitLab Duo Workflow runs code in Docker containers for isolation:

- Each workflow gets its own container
- Containers are destroyed after workflow completion
- File access is limited to workflow workspace
- Network access is controlled

## Advanced Configuration

### Custom Docker Configuration

You can customize Docker behavior by setting additional environment variables:

```bash
# Use a specific Docker host
export DOCKER_HOST="unix:///path/to/docker.sock"

# Use Docker over TCP (not recommended)
export DOCKER_HOST="tcp://localhost:2375"

# Specify Docker API version
export DOCKER_API_VERSION="1.41"
```

### Docker Resource Limits

GitLab LSP may respect Docker resource limits. Configure in your Docker daemon settings:

```json
{
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  },
  "default-runtime": "runc",
  "max-concurrent-downloads": 3,
  "max-concurrent-uploads": 5
}
```

## FAQ

### Q: Do I need Docker Desktop?
**A:** No, you can use any Docker-compatible runtime like Colima, Rancher Desktop, or standard Docker.

### Q: Can I use Podman instead of Docker?
**A:** Potentially, if Podman provides a Docker-compatible socket. Set `GITLAB_DOCKER_SOCKET` to the Podman socket path.

### Q: Will workflows work without Docker?
**A:** Limited functionality. Simple chat works, but complex workflows requiring code execution will fail.

### Q: Is my Docker socket secure?
**A:** Docker socket access is powerful. Only run workflows from trusted sources and review tool approvals.

### Q: Can I use a remote Docker host?
**A:** Yes, set `DOCKER_HOST` to a TCP endpoint, but this is not recommended for security reasons.

### Q: How much disk space do workflows use?
**A:** Workflows use Docker images and containers. Clean up periodically with `docker system prune`.

## See Also

- [GitLab Duo Workflow Documentation](https://docs.gitlab.com/ee/user/duo_workflow/)
- [Docker Installation Guide](https://docs.docker.com/get-docker/)
- [Colima GitHub](https://github.com/abiosoft/colima)
- [Rancher Desktop](https://rancherdesktop.io/)

