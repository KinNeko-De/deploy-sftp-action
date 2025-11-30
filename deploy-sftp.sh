#!/usr/bin/env bash

set -euo pipefail

# Strict checks for required environment variables
for var in FTP_USERNAME FTP_SERVER FTP_PASSWORD LOCAL_DIR REMOTE_DIR; do
  if [ -z "${!var-}" ]; then
    echo "Error: $var environment variable not set."
    exit 2
  fi
done


echo "Using LOCAL_DIR: $LOCAL_DIR"
echo "Using REMOTE_DIR: $REMOTE_DIR"
PORT=${FTP_PORT:-22}

# Set SSHPASS environment variable for sshpass (more secure than -p flag)
export SSHPASS="$FTP_PASSWORD"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

remote_files_raw="$tmpdir/remote_files_raw.txt"
remote_dirs_raw="$tmpdir/remote_dirs_raw.txt"
remote_files_sorted="$tmpdir/remote_files_sorted.txt"
remote_dirs_sorted="$tmpdir/remote_dirs_sorted.txt"
local_files_sorted="$tmpdir/local_files_sorted.txt"
local_dirs_sorted="$tmpdir/local_dirs_sorted.txt"
delete_files="$tmpdir/delete_files.txt"
delete_dirs="$tmpdir/delete_dirs.txt"
sftp_delete_batch="$tmpdir/sftp_delete_batch.txt"

# Scan local files and directories first

# Build remote file and directory lists by recursively scanning the remote directory
echo "Scanning remote directory structure: $REMOTE_DIR"
: > "$remote_files_raw"
: > "$remote_dirs_raw"

# Queue of directories to scan
dirs_to_scan="$tmpdir/dirs_to_scan.txt"
dirs_scanned="$tmpdir/dirs_scanned.txt"
echo "." > "$dirs_to_scan"
: > "$dirs_scanned"

# Ensure remote directory exists (create if missing, ignore error if exists)
echo "Ensuring remote directory exists: $REMOTE_DIR"
mkdir_output="$tmpdir/sftp_mkdir_output.txt"
printf '%s\n' "mkdir $REMOTE_DIR" "bye" | sshpass -e sftp -oBatchMode=no -oStrictHostKeyChecking=no -P "$PORT" "$FTP_USERNAME@$FTP_SERVER" > "$mkdir_output" 2>&1 || true

if [ ! -s "$mkdir_output" ]; then
  echo "No output from SFTP mkdir command"
else
  echo "SFTP mkdir output for $REMOTE_DIR:"
  cat "$mkdir_output"
fi

if grep -qi "Failure" "$mkdir_output"; then
  echo "Error: Could not create remote directory: $REMOTE_DIR. Maybe it already exists."
fi

# Guard: test cd to remote dir, exit if it fails
if [ -n "${REMOTE_DIR-}" ] && [ "$REMOTE_DIR" != "." ]; then
  echo "Checking remote directory existence: $REMOTE_DIR"
  sftp_guard_output="$tmpdir/sftp_guard_check.txt"
  printf '%s\n' "cd $REMOTE_DIR" 'bye' | sshpass -e sftp -oBatchMode=no -oStrictHostKeyChecking=no -P "$PORT" "$FTP_USERNAME@$FTP_SERVER" > "$sftp_guard_output" 2>&1
  sftp_guard_exit_code=$?
  if grep -q "No such file or directory" "$sftp_guard_output"; then
    echo "SFTP exit code for guard: $sftp_guard_exit_code"
    echo "Error: Remote directory does not exist or is not accessible: $REMOTE_DIR"
    cat "$sftp_guard_output"
    exit 3
  fi
fi

# Process directories iteratively
while true; do
  current_dir=""
  while IFS= read -r dir; do
    if ! grep -Fxq "$dir" "$dirs_scanned"; then
      current_dir="$dir"
      echo "$dir" >> "$dirs_scanned"
      break
    fi
  done < "$dirs_to_scan"

  [ -z "$current_dir" ] && break

  echo "Scanning remote directory: $current_dir"

  # Guard: check if remote directory exists before scanning
  dir_guard_output="$tmpdir/dir_guard_$current_dir.txt"
  if [ "$current_dir" = "." ]; then
    printf '%s\n' "cd $REMOTE_DIR" 'bye' | sshpass -e sftp -oBatchMode=no -oStrictHostKeyChecking=no -P "$PORT" "$FTP_USERNAME@$FTP_SERVER" > "$dir_guard_output" 2>&1
  else
    printf '%s\n' "cd $REMOTE_DIR/$current_dir" 'bye' | sshpass -e sftp -oBatchMode=no -oStrictHostKeyChecking=no -P "$PORT" "$FTP_USERNAME@$FTP_SERVER" > "$dir_guard_output" 2>&1
  fi
  if grep -q "No such file or directory" "$dir_guard_output"; then
    echo "Warning: Remote directory not found (guard): $current_dir. Skipping."
    continue
  fi

  ls_output="$tmpdir/ls_current.txt"
  if [ "$current_dir" = "." ]; then
    printf '%s\n' "cd $REMOTE_DIR" 'ls -l' 'bye' | sshpass -e sftp -oBatchMode=no -oStrictHostKeyChecking=no -P "$PORT" "$FTP_USERNAME@$FTP_SERVER" > "$ls_output" 2>&1 || true
  else
    printf '%s\n' "cd $REMOTE_DIR/$current_dir" 'ls -l' 'bye' | sshpass -e sftp -oBatchMode=no -oStrictHostKeyChecking=no -P "$PORT" "$FTP_USERNAME@$FTP_SERVER" > "$ls_output" 2>&1 || true
  fi

  # If directory does not exist, skip further processing for this dir (redundant, but extra safe)
  if grep -q "No such file or directory" "$ls_output"; then
    echo "Warning: Remote directory not found: $current_dir. Skipping."
    continue
  fi

  while IFS= read -r line; do
    echo "$line" | grep -qE '^(Remote working directory:|sftp>|total )' && continue
    [ -z "$line" ] && continue

    first_char="${line:0:1}"
    # Robustly extract the last field (filename or directory name) from ls -l output
    name=$(echo "$line" | awk '{print $NF}')
    [ "$name" = "." ] || [ "$name" = ".." ] && continue

    if [ "$current_dir" = "." ]; then
      rel_path="$name"
    else
      rel_path="$current_dir/$name"
    fi

    if [ "$first_char" = "d" ]; then
      echo "$rel_path" >> "$remote_dirs_raw"
      echo "$rel_path" >> "$dirs_to_scan"
    elif [ "$first_char" = "-" ]; then
      echo "$rel_path" >> "$remote_files_raw"
    fi
  done < "$ls_output"
done

sort -u "$remote_files_raw" -o "$remote_files_sorted" || true
sort -u "$remote_dirs_raw" -o "$remote_dirs_sorted" || true

if [ ! -d "$LOCAL_DIR" ]; then
  echo "Local directory not found: $LOCAL_DIR"
  exit 1
fi

find "$LOCAL_DIR" -type f | sed "s:^$LOCAL_DIR/::" | sort > "$local_files_sorted"
find "$LOCAL_DIR" -type d | sed "s:^$LOCAL_DIR/::" | sort > "$local_dirs_sorted"

comm -23 "$remote_files_sorted" "$local_files_sorted" > "$delete_files" || true
comm -23 "$remote_dirs_sorted" "$local_dirs_sorted" > "$delete_dirs" || true
sed -i -e '/^$/d' -e '/^\.$/d' "$delete_files" "$delete_dirs" 2>/dev/null || true

if [ -s "$delete_files" ] || [ -s "$delete_dirs" ]; then
  echo "Building SFTP delete batch..."
  : > "$sftp_delete_batch"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ "$REMOTE_DIR" = "." ] || [ -z "$REMOTE_DIR" ]; then
      echo "rm $f" >> "$sftp_delete_batch"
    else
      echo "rm $REMOTE_DIR/$f" >> "$sftp_delete_batch"
    fi
  done < "$delete_files"

  if [ -s "$delete_dirs" ]; then
    awk -F'/' '{print NF, $0}' "$delete_dirs" | sort -rn | cut -d' ' -f2 > "$tmpdir/delete_dirs_sorted_by_depth.txt"
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      if [ "$REMOTE_DIR" = "." ] || [ -z "$REMOTE_DIR" ]; then
        echo "rmdir $d" >> "$sftp_delete_batch"
      else
        echo "rmdir $REMOTE_DIR/$d" >> "$sftp_delete_batch"
      fi
    done < "$tmpdir/delete_dirs_sorted_by_depth.txt"
  fi

  echo "Delete batch commands:"
  cat "$sftp_delete_batch"

  (cat "$sftp_delete_batch"; echo "bye") | sshpass -e sftp -oBatchMode=no -oStrictHostKeyChecking=no -P "$PORT" "$FTP_USERNAME@$FTP_SERVER"
else
  echo "No remote-only files to delete."
fi

echo "Uploading local $LOCAL_DIR contents to $REMOTE_DIR..."
# Check for files to upload (excluding hidden files)
if ! find "$LOCAL_DIR" -maxdepth 1 -type f ! -name '.*' | grep -q .; then
  echo "Error: No files found in $LOCAL_DIR to upload (excluding hidden files)."
  exit 3
fi
printf '%s\n' "cd $REMOTE_DIR" "lcd $LOCAL_DIR" 'put -r *' 'bye' | sshpass -e sftp -oBatchMode=no -oStrictHostKeyChecking=no -P "$PORT" "$FTP_USERNAME@$FTP_SERVER"

echo "Deployment completed"
