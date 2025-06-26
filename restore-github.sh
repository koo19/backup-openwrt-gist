#!/bin/sh

# ==============================================================================
# OpenWrt Gist Restore Script (v5 - PBKDF2 Final Fix)
#
# Changelog:
# - v5: Switched to PBKDF2 for key derivation to match the v3 backup script.
#       This is the most reliable method and should resolve all previous errors.
# ==============================================================================

[ -f ~/.bashrc ] && . ~/.bashrc

# --- Configuration ---
RESTORE_DIR="/tmp/restore_from_github"

# --- Environment Variable Dependencies ---
GITHUB_PAT="${GITHUB_PAT:-}"
ENCRYPTION_PASSWORD="${ENCRYPTION_PASSWORD:-}"
GIST_ID="${BACKUP_GIST_ID:-}"

# --- Script Validation & Tool Check ---
if [ -z "$GITHUB_PAT" ] || [ -z "$ENCRYPTION_PASSWORD" ] || [ -z "$GIST_ID" ]; then
    echo "Error: Required environment variables are not set."
    exit 1
fi
for tool in curl jsonfilter openssl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: Required tool '$tool' is not installed."
        exit 1
    fi
done

# --- Cleanup Function ---
cleanup() {
    echo "Cleaning up temporary directory..."
    rm -rf "${RESTORE_DIR}"
    echo "Cleanup complete."
}

# --- Main Script Logic ---
echo "--- OpenWrt Configuration Restore Started ---"

# 1. Fetch Gist data
echo "Fetching backup list from Gist ID: ${GIST_ID}..."
GIST_API_URL="https://api.github.com/gists/${GIST_ID}"
RESPONSE=$(curl -s -L -H "Accept: application/vnd.github.v3+json" -H "Authorization: token ${GITHUB_PAT}" "${GIST_API_URL}")

if [ -z "$RESPONSE" ] || echo "$RESPONSE" | jsonfilter -e '@.message' | grep -q "."; then
    echo "Error: Failed to fetch data from GitHub Gist."
    exit 1
fi

FILE_LIST=$(echo "$RESPONSE" | jsonfilter -e '@.files.*.filename' | grep '\.enc$')
if [ -z "$FILE_LIST" ]; then
    echo "No valid backup files (.enc) found in the specified Gist."
    exit 0
fi

# 2. Present user menu
echo "Please select a backup file to restore:"
i=1
options=$(echo "$FILE_LIST" | tr ' ' '\n')
echo "$options" | while read -r line; do
    echo "  $i) $line"
    i=$((i + 1))
done
total_files=$(echo "$options" | wc -l)
printf "Enter the number of your choice (1-%s): " "${total_files}"
read -r choice

if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "$total_files" ]; then
    echo "Error: Invalid selection."
    exit 1
fi
FILENAME=$(echo "$options" | sed -n "${choice}p")
echo "You have selected: ${FILENAME}"

# 3. Download
mkdir -p "$RESTORE_DIR"
ENCRYPTED_FILE_PATH="${RESTORE_DIR}/${FILENAME}"
DECRYPTED_FILENAME="${FILENAME%.enc}"
DECRYPTED_FILE_PATH="${RESTORE_DIR}/${DECRYPTED_FILENAME}"
RAW_URL=$(echo "$RESPONSE" | jsonfilter -e "@.files['${FILENAME}'].raw_url")
if [ -z "$RAW_URL" ]; then
    echo "Error: Could not find the download URL for the selected file."
    cleanup
    exit 1
fi
echo "Downloading ${FILENAME}..."
curl -sL "${RAW_URL}" -o "${ENCRYPTED_FILE_PATH}"
if [ ! -s "${ENCRYPTED_FILE_PATH}" ]; then
    echo "Error: Download failed, the resulting file is empty."
    cleanup
    exit 1
fi
echo "File downloaded successfully."

# 4. Decrypt the file using the most robust method
echo "Decrypting backup file with PBKDF2..."
# *** FINAL FIX: Use PBKDF2 with explicit parameters to match the encryption method ***
openssl enc -chacha20 -d -pbkdf2 -iter 100000 \
  -in "${ENCRYPTED_FILE_PATH}" \
  -out "${DECRYPTED_FILE_PATH}" \
  -pass pass:"${ENCRYPTION_PASSWORD}"

if [ $? -ne 0 ]; then
    echo "--------------------------------------------------------"
    echo "Error: Decryption failed!"
    echo "This could be due to an incorrect password or a corrupt file."
    echo "IMPORTANT: Only backups created with the LATEST v4 backup script are compatible."
    printf "Do you want to keep the downloaded encrypted file for inspection? (y/N): "
    read -r KEEP_FILE
    if [ "$(echo "$KEEP_FILE" | tr '[:upper:]' '[:lower:]')" = "y" ]; then
        echo "The downloaded file is saved at: ${ENCRYPTED_FILE_PATH}"
        echo "Exiting without cleanup."
    else
        cleanup
    fi
    exit 1
fi
echo "File decrypted successfully: ${DECRYPTED_FILENAME}"

# 5. Restore
echo "--------------------------------------------------------"
echo "WARNING: This will overwrite your current settings!"
printf "Are you sure you want to proceed with restore? (y/N): "
read -r CONFIRM
if [ "$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')" = "y" ]; then
    echo "Starting system restore... The device may reboot."
    sysupgrade -r "${DECRYPTED_FILE_PATH}"
    [ $? -ne 0 ] && echo "Error: System restore command failed." && cleanup
else
    echo "Restore cancelled by user."
    cleanup
fi

echo "--- Restore Process Finished ---"
