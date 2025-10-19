# SFTP Deploy Action for IONOS

This GitHub Action provides robust SFTP deployment for static sites to IONOS hosting.
It was created specifically to work around the limitations and quirks of IONOS SFTP for accounts created before 10.09.2024.

# Why this action?

IONOS SFTP has several restrictions:

- No SSH access: Only SFTP is available; SSH features and commands do not work.
- Limited SFTP features: Many extended SFTP commands and batch operations are unsupported.
- Recursive mirroring: Standard tools (like rsync, scp, or advanced SFTP batch scripts) fail.

This action implements a SFTP deployment strategy that:

- Avoids unsupported SFTP features and batch commands.
- Scans remote directories and files.
- Deletes remote-only files and directories.
- Uploads the complete local site.

# Troubleshooting

If you encounter issues with this action consider using lftp as an alternative. I personally used lftp and found it reliable for mirroring with IONOS, although the installation process was noticeably slow. I also used [SFTP Deploy](https://github.com/marketplace/actions/sftp-deploy) but that actions uses ssh for deleting of files.

# Usage

This repository can be used directly as a GitHub Action. Add a step to your workflow that uses this repository. Note: this action expects `sshpass` and `sftp` to be available on the runner; GitHub-hosted Ubuntu runners typically include these tools.

Inputs

- `ftp_username` (required): SFTP username.
- `ftp_password` (required): SFTP password. Use a secret for this.
- `ftp_server` (required): SFTP server hostname or IP.
- `ftp_port` (optional): SFTP port (default: 22).
- `local_dir` (optional): Local directory to upload (default: `.`).
- `remote_dir` (optional): Remote directory on the server to upload into (default: `.`).

## Example 

```yaml
- name: Deploy via SFTP
  uses: KinNeko-De/deploy-sftp-action@main
  with:
    ftp_username: ${{ secrets.SFTP_USERNAME }}
    ftp_password: ${{ secrets.SFTP_PASSWORD }}
    ftp_server: ${{ secrets.SFTP_SERVER }}
    ftp_port: 22
    local_dir: public
    remote_dir: .
```