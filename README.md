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

See the action.yml for input parameters and example workflow usage.