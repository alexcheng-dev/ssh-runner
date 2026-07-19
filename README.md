# SSH Runner

GitHub Actions workflow that starts an Ubuntu runner with SSH access via tmate.

## Usage

1. Go to **Actions** → **🖥️ SSH Runner (10 min idle)** → **Run workflow**
2. Enter the desired public tunnel port (default: `2222`)
3. Wait for the tmate session link to appear in the logs
4. Copy the SSH command from the logs and paste in your terminal
5. The runner auto-terminates after 10 minutes
