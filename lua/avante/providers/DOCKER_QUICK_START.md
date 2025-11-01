# Docker Quick Start for GitLab Duo Workflow

## TL;DR

GitLab Duo Workflow needs Docker. Here's the fastest way to get started:

### macOS

```bash
# Install Colima (lightweight Docker runtime)
brew install colima docker

# Start Colima
colima start

# Verify it's working
docker ps

# Set environment variable
echo 'export GITLAB_DOCKER_SOCKET="$HOME/.colima/default/docker.sock"' >> ~/.zshrc
source ~/.zshrc

# Restart Neovim
```

### Linux (Ubuntu/Debian)

```bash
# Install Docker
sudo apt-get update
sudo apt-get install docker.io

# Start Docker
sudo systemctl start docker
sudo systemctl enable docker

# Add your user to docker group (avoid sudo)
sudo usermod -aG docker $USER
newgrp docker

# Verify it's working
docker ps

# Set environment variable (usually not needed)
echo 'export GITLAB_DOCKER_SOCKET="/var/run/docker.sock"' >> ~/.bashrc
source ~/.bashrc

# Restart Neovim
```

## Verify Setup

1. Check Docker is running:
   ```bash
   docker ps
   ```

2. Check socket exists:
   ```bash
   # macOS (Colima)
   ls -la ~/.colima/default/docker.sock

   # Linux
   ls -la /var/run/docker.sock
   ```

3. Start Neovim and try a workflow:
   ```vim
   :AvanteAsk explain this file
   ```

## Troubleshooting

### "Docker socket not configured"

**Quick fix:**
```bash
# Find your Docker socket
find ~ -name "docker.sock" 2>/dev/null

# Set it manually
export GITLAB_DOCKER_SOCKET="/path/to/docker.sock"

# Restart Neovim
```

### "Permission denied" on Linux

```bash
# Add your user to docker group
sudo usermod -aG docker $USER
newgrp docker
```

### Still not working?

See the full [Docker Setup Guide](DOCKER_SETUP.md) for detailed instructions.

## What Docker is Used For

Docker allows GitLab Duo Workflow to:
- Execute code safely in isolated containers
- Run tools and commands
- Read and write files
- Test code changes

Without Docker, you can still use basic chat features, but complex workflows won't work.

## Alternative Docker Runtimes

- **Colima** (macOS) - Recommended, lightweight
- **Rancher Desktop** (macOS/Linux) - Good alternative
- **Docker Desktop** (macOS/Linux) - Works but heavier
- **Podman** (Linux) - May work with socket compatibility

## Security Note

Docker socket access is powerful. Only run workflows from trusted sources and review tool approvals carefully.

