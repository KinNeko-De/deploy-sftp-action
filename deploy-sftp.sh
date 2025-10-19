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


echo "Building recursive remote file list via SFTP..."
echo "Remote base: $REMOTE_DIR"

: > "$remote_files_raw"
: > "$remote_dirs_raw"

# Queue of directories to process
dirs_to_scan="$tmpdir/dirs_to_scan.txt"
dirs_scanned="$tmpdir/dirs_scanned.txt"
echo "$REMOTE_DIR" > "$dirs_to_scan"
: > "$dirs_scanned"

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

  echo "Scanning directory: $current_dir"

  ls_output="$tmpdir/ls_current.txt"
  if [ "$current_dir" = "$REMOTE_DIR" ]; then
    printf '%s\n' "cd $REMOTE_DIR" 'ls -l' 'bye' | sshpass -p "$FTP_PASSWORD" sftp -oBatchMode=no -oStrictHostKeyChecking=no -P "$PORT" "$FTP_USERNAME@$FTP_SERVER" > "$ls_output" 2>&1 || true
  else
    printf '%s\n' "cd $current_dir" 'ls -l' 'bye' | sshpass -p "$FTP_PASSWORD" sftp -oBatchMode=no -oStrictHostKeyChecking=no -P "$PORT" "$FTP_USERNAME@$FTP_SERVER" > "$ls_output" 2>&1 || true
  fi

  while IFS= read -r line; do
    echo "$line" | grep -qE '^(Remote working directory:|sftp>|total )' && continue
    [ -z "$line" ] && continue

    first_char="${line:0:1}"
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

echo "Remote base: ."

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

  (cat "$sftp_delete_batch"; echo "bye") | sshpass -p "$FTP_PASSWORD" sftp -oBatchMode=no -oStrictHostKeyChecking=no -P "$PORT" "$FTP_USERNAME@$FTP_SERVER"
else
  echo "No remote-only files to delete."
fi

echo "Uploading local $LOCAL_DIR contents to remote..."
printf '%s\n' "cd $REMOTE_DIR" "lcd $LOCAL_DIR" 'put -r *' 'bye' | sshpass -p "$FTP_PASSWORD" sftp -oBatchMode=no -oStrictHostKeyChecking=no -P "$PORT" "$FTP_USERNAME@$FTP_SERVER"

echo "Deployment completed"
