#!/bin/sh

[ -f ~/.bashrc ] && . ~/.bashrc

# --- Configuration ---
BACKUP_DIR="/tmp/backup_to_github"                  # Temporary directory for backup files on OpenWrt
# FIX: Adjusted date format to be more compatible with BusyBox date for filename
BACKUP_FILENAME="openwrt_config_$(date +%Y%m%d_%H%M%S 2>/dev/null | sed 's/://g').tar.gz"
# Fallback date if main one fails (for filename)
[ -z "$(echo "$BACKUP_FILENAME" | grep '_')" ] && BACKUP_FILENAME="openwrt_config_$(date +%Y%m%d)_$(date +%H%M%S 2>/dev/null | sed 's/://g').tar.gz"

ENCRYPTED_FILENAME="${BACKUP_FILENAME}.enc"
# FIX: Adjusted date format for Gist description
GIST_DESCRIPTION="OpenWrt Config Backup - Encrypted ($(date +%Y-%m-%d %H:%M:%S 2>/dev/null || date +%Y-%m-%d))"
GIST_PUBLIC="false"                # 'true' for public, 'false' for private (recommended)

# GitHub Personal Access Token (PAT) and Encryption Password
# It is STRONGLY RECOMMENDED not to hardcode these sensitive details in the script!
# Instead, pass them as environment variables when executing the script.
# Example: export GITHUB_PAT="ghp_YOUR_TOKEN"
# Example: export ENCRYPTION_PASSWORD="YOUR_SUPER_STRONG_PASSWORD"
GITHUB_PAT="${GITHUB_PAT:-}"       # Reads from GITHUB_PAT environment variable
ENCRYPTION_PASSWORD="${ENCRYPTION_PASSWORD:-}" # Reads from ENCRYPTION_PASSWORD environment variable

# --- Script Validation ---
if [ -z "$GITHUB_PAT" ]; then
    echo "Error: GITHUB_PAT environment variable is not set. Please set your GitHub Personal Access Token."
    exit 1
fi

if [ -z "$ENCRYPTION_PASSWORD" ]; then
    echo "Error: ENCRYPTION_PASSWORD environment variable is not set. Please set your encryption password."
    echo "Warning: Do NOT hardcode the password in the script; it's insecure!"
    exit 1
fi

# --- Main Script Logic ---
echo "--- OpenWrt Configuration Backup and Encryption Started ---"

# 1. Create OpenWrt Configuration Backup
if [ ! -d "$BACKUP_DIR" ]; then
  mkdir -p "$BACKUP_DIR"
  echo "Directory '$BACKUP_DIR' created."
else
  echo "Directory '$BACKUP_DIR' already exists."
fi
echo "Creating OpenWrt configuration backup to ${BACKUP_DIR}/${BACKUP_FILENAME}..."
sysupgrade -b "${BACKUP_DIR}/${BACKUP_FILENAME}"
if [ $? -ne 0 ]; then
    echo "Error: OpenWrt backup creation failed!"
    exit 1
fi
echo "Backup file created successfully."

# 2. Encrypt the Backup File using ChaCha20
echo "Encrypting backup file using ChaCha20..."
openssl enc -chacha20 -e -in "${BACKUP_DIR}/${BACKUP_FILENAME}" -out "${BACKUP_DIR}/${ENCRYPTED_FILENAME}" -k "${ENCRYPTION_PASSWORD}"
if [ $? -ne 0 ]; then
    echo "Error: Backup file encryption failed! Check openssl command and password."
    rm -f "${BACKUP_DIR}/${BACKUP_FILENAME}" # Clean up unencrypted backup
    exit 1
fi
echo "Backup file encrypted successfully: ${ENCRYPTED_FILENAME}"

# 3. Get the content of the encrypted file for Gist upload (base64 encoded)
ENCRYPTED_CONTENT=$(cat "${BACKUP_DIR}/${ENCRYPTED_FILENAME}" | base64 -w 0)

# 4. Prepare the Gist API request body and write to a temporary file
JSON_TEMP_FILE="${BACKUP_DIR}/gist_payload.json"

cat <<EOF > "${JSON_TEMP_FILE}"
{
  "description": "${GIST_DESCRIPTION}",
  "public": ${GIST_PUBLIC},
  "files": {
    "${ENCRYPTED_FILENAME}": {
      "content": "${ENCRYPTED_CONTENT}"
    }
  }
}
EOF

# 5. Push encrypted backup file to GitHub Gist using the temporary JSON file
echo "Pushing encrypted backup file to GitHub Gist..."
RESPONSE=$(curl -s -X POST \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: token ${GITHUB_PAT}" \
  -H "Content-Type: application/json" \
  --data-binary "@${JSON_TEMP_FILE}" \
  https://api.github.com/gists)

if [ $? -ne 0 ]; then
    echo "Error: Failed to call GitHub Gist API via curl!"
    echo "Response: ${RESPONSE}"
    # Clean up temporary files
    rm -f "${BACKUP_DIR}/${BACKUP_FILENAME}"
    rm -f "${BACKUP_DIR}/${ENCRYPTED_FILENAME}"
    rm -f "${JSON_TEMP_FILE}" # Clean up the temporary JSON file
    exit 1
fi

GIST_URL=$(echo "$RESPONSE" | jsonfilter -e '@.html_url')

if [ -z "$GIST_URL" ]; then
    echo "Error: Could not retrieve Gist URL from GitHub Gist response. Upload may have failed."
    echo "Full Response: ${RESPONSE}"
else
    echo "Encrypted backup successfully pushed to GitHub Gist!"
    echo "Gist URL: ${GIST_URL}"
fi

# 6. Clean up temporary files
echo "Cleaning up temporary backup files..."
rm -f "${BACKUP_DIR}/${BACKUP_FILENAME}"
rm -f "${BACKUP_DIR}/${ENCRYPTED_FILENAME}"
rm -f "${JSON_TEMP_FILE}" # Clean up the temporary JSON file
echo "Cleanup complete."

echo "--- Backup and Encryption Process Finished ---"
