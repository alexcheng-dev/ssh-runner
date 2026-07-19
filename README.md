# SSH Runner

GitHub Actions workflow that runs an Ubuntu runner for 10 minutes with SSH access via tmate.

## Usage

1. Go to **Actions** → **SSH Runner (10 min idle)** → **Run workflow**
2. In the workflow logs, find the tmate SSH connection link
3. Connect via SSH and work on the runner
4. The runner auto-terminates after 10 minutes

## Security

SSH access is restricted to the repository owner (`limit-access-to-actor: true`).
