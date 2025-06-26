#!/bin/sh

[ -f ~/.bashrc ] && . ~/.bashrc

# --- Configuration ---
RESTORE_DIR="/tmp/restore_backup" # Temporary directory for restoration files on OpenWrt

# GitHub Personal Access Token (PAT) and Encryption Password
# These MUST be the same as used for backup!
# Set them as environment variables before running the script:
# export GITHUB_PAT="ghp_YOUR_PERSONAL_ACCESS_TOKEN_HERE"
# export ENCRYPTION_PASSWORD="YOUR_VERY_STRONG_ENCRYPTION_PASSWORD"
# export GIST_ID="SPECIFIC_GIST_ID_HERE" # Set this if you want to restore a specific Gist
GITHUB_PAT="${GITHUB_PAT:-}"
ENCRYPTION_PASSWORD="${ENCRYPTION_PASSWORD:-}"
GIST_ID="${BACKUP_GIST_ID:-}" # Now explicitly checks for GIST_ID environment variable

# --- Script Validation ---
if [ -z "$GITHUB_PAT" ]; then
    echo "Error: GITHUB_PAT environment variable is not set. Please set your GitHub Personal Access Token."
    exit 1
fi

if [ -z "$ENCRYPTION_PASSWORD" ]; then
    echo "Error: ENCRYPTION_PASSWORD environment variable is not set. Please set your encryption password."
    exit 1
fi

# --- Main Script Logic ---
echo "--- OpenWrt Configuration Restoration Started ---"

mkdir -p "${RESTORE_DIR}" || { echo "Error: Could not create restoration directory."; exit 1; }

# Determine if a specific GIST_ID is provided or if we need to find the latest
if [ -n "$GIST_ID" ]; then
    echo "Restoring from specific Gist ID: ${GIST_ID}"
    TARGET_GIST_ID="${GIST_ID}"
else
    echo "No specific GIST_ID provided. Fetching your Gist list to find the latest OpenWrt backup..."
    GIST_LIST_RESPONSE=$(curl -s -H "Authorization: token ${GITHUB_PAT}" "https://api.github.com/gists")

    if [ $? -ne 0 ]; then
        echo "Error: Failed to fetch Gist list via curl!"
        echo "Response: ${GIST_LIST_RESPONSE}"
        rm -rf "${RESTORE_DIR}"
        exit 1
    fi

    # Find the latest private Gist with "OpenWrt Config Backup - Encrypted" in its description
    # and contains at least one file ending with ".enc"
    LATEST_GIST_INFO=$(echo "$GIST_LIST_RESPONSE" | jsonfilter -e '@[]' | \
        awk -F'\n' '{
            gist_id=""; created_at=""; description=""; has_enc_file="false"; is_private="false";
            for(i=1; i<=NF; i++) {
                if ($i ~ /^ *"id": /) gist_id=gensub(/.*"([^"]+)".*/, "\\1", "g", $i);
                if ($i ~ /^ *"created_at": /) created_at=gensub(/.*"([^"]+)".*/, "\\1", "g", $i);
                if ($i ~ /^ *"description": /) description=gensub(/.*"([^"]+)".*/, "\\1", "g", $i);
                if ($i ~ /"public": false/) is_private="true";
                if ($i ~ /\.enc"/) has_enc_file="true";
                if ($i ~ /^\}/) { # End of Gist object
                    if (is_private == "true" && description ~ /OpenWrt Config Backup - Encrypted/ && has_enc_file == "true") {
                        print created_at " " gist_id;
                    }
                    is_private="false"; has_enc_file="false"; # Reset for next Gist
                }
            }
        }' | sort -r | head -n 1)

    if [ -z "$LATEST_GIST_INFO" ]; then
        echo "Error: No matching private OpenWrt backup Gist found."
        echo "Please ensure you have run the backup script successfully and the PAT has 'gist' scope."
        rm -rf "${RESTORE_DIR}"
        exit 1
    fi

    TARGET_GIST_ID=$(echo "$LATEST_GIST_INFO" | awk '{print $2}')
    LATEST_CREATED_AT=$(echo "$LATEST_GIST_INFO" | awk '{print $1}')
    echo "Found latest backup Gist (ID: ${TARGET_GIST_ID}) created at: ${LATEST_CREATED_AT}"
fi

# 2. Get the full metadata for the target Gist to find the encrypted filename and raw URL
echo "Fetching metadata for Gist ID: ${TARGET_GIST_ID}..."
GIST_METADATA_RESPONSE=$(curl -s -H "Authorization: token ${GITHUB_PAT}" "https://api.github.com/gists/${TARGET_GIST_ID}")

if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch Gist metadata via curl for specific Gist!"
    echo "Response: ${GIST_METADATA_RESPONSE}"
    rm -rf "${RESTORE_DIR}"
    exit 1
fi

# Extract the filename ending with .enc and its raw_url
ENCRYPTED_FILENAME=$(echo "$GIST_METADATA_RESPONSE" | jsonfilter -e '@.files | keys[] | select(contains(".enc"))')
RAW_URL=$(echo "$GIST_METADATA_RESPONSE" | jsonfilter -e '@.files."'$ENCRYPTED_FILENAME'".raw_url')

if [ -z "$ENCRYPTED_FILENAME" ] || [ -z "$RAW_URL" ]; then
    echo "Error: Could not find any '.enc' file or its raw URL in the Gist ID: ${TARGET_GIST_ID}."
    echo "Full Gist Metadata Response: ${GIST_METADATA_RESPONSE}"
    rm -rf "${RESTORE_DIR}"
    exit 1
fi

echo "Found encrypted file in Gist: ${ENCRYPTED_FILENAME}"
echo "Raw Download URL: ${RAW_URL}"

# 3. Download the base64-encoded encrypted content
DOWNLOADED_BASE64_FILE="${RESTORE_DIR}/downloaded_backup.base64"
echo "Downloading encrypted backup from Gist..."
curl -s "${RAW_URL}" -o "${DOWNLOADED_BASE64_FILE}"
if [ $? -ne 0 ]; then
    echo "Error: Failed to download backup file from Gist!"
    rm -rf "${RESTORE_DIR}"
    exit 1
fi
echo "Downloaded to ${DOWNLOADED_BASE64_FILE}"

# 4. Decode the base64 content
TEMP_ENCRYPTED_FILE="${RESTORE_DIR}/temp_encrypted.enc"
echo "Decoding base64 content..."
base64 -d "${DOWNLOADED_BASE64_FILE}" > "${TEMP_ENCRYPTED_FILE}"
if [ $? -ne 0 ]; then
    echo "Error: Failed to decode base64 content!"
    rm -rf "${RESTORE_DIR}"
    exit 1
fi
echo "Decoded to ${TEMP_ENCRYPTED_FILE}"

# 5. Decrypt the backup file
DECRYPTED_TAR_GZ_FILE="${RESTORE_DIR}/restored_config.tar.gz"
echo "Decrypting backup file using ChaCha20..."
# IMPORTANT: Use the same cipher as used for encryption (ChaCha20 based on your backup script's last output)
openssl enc -d -chacha20 -in "${TEMP_ENCRYPTED_FILE}" -out "${DECRYPTED_TAR_GZ_FILE}" -k "${ENCRYPTION_PASSWORD}"
if [ $? -ne 0 ]; then
    echo "Error: Failed to decrypt backup file! Check encryption password and cipher."
    rm -rf "${RESTORE_DIR}"
    exit 1
fi
echo "Decrypted backup saved to: ${DECRYPTED_TAR_GZ_FILE}"

# 6. Provide instructions for restoration
echo ""
echo "--- IMPORTANT: RESTORATION STEPS ---"
echo "Your decrypted OpenWrt configuration backup is located at: ${DECRYPTED_TAR_GZ_FILE}"
echo ""
echo "To restore this configuration to your router, run the following command:"
echo ""
echo "    sysupgrade -r ${DECRYPTED_TAR_GZ_FILE}"
echo ""
echo "WARNINGS:"
echo "1. This command will APPLY THE CONFIGURATION and then REBOOT YOUR ROUTER."
echo "2. Ensure you are ready for a reboot and potential loss of network connectivity during the process."
echo "3. If you are not physically next to the router, ensure you have a fallback plan (e.g., failsafe mode)."
echo ""
echo "Once you have executed the 'sysupgrade -r' command, the temporary files will be removed automatically after reboot."
echo ""
echo "--- Restoration Script Finished ---"
