# SSH Runner

GitHub Actions workflow that runs an Ubuntu runner for 10 minutes with password-based SSH access via a public bore tunnel.

## Usage

1. Go to **Actions** → **🖥️ SSH Runner (10 min idle)** → **Run workflow**
2. Enter the desired public port (default: `2222`)
3. Wait for the `Print connection details` step
4. Connect from your terminal:
   ```bash
   ssh ubuntu@bore.pub -p <port>
   ```
5. Use the password shown in the workflow logs
6. The runner auto-terminates after 10 minutes

## How it works

- **openssh-server** runs inside the runner with password authentication
- **bore** creates a TCP tunnel via `bore.pub` on the port you choose
- No SSH keys needed — just a password
