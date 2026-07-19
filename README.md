# SSH Runner

GitHub Actions workflow that starts an Ubuntu runner with SSH access via tmate.

## Usage

1. Go to **Actions** → **🖥️ SSH Runner (6 hour idle)** → **Run workflow**
2. Wait for the tmate session link to appear in the logs
3. Copy the **SSH** line (e.g. `ssh abc123@nyc1.tmate.io`) and paste it in your terminal
4. The runner auto-terminates after 6 hours

## How it works

Downloads the tmate static binary directly from GitHub (no apt), starts a session, and prints the SSH connection string — no keys or passwords needed.
