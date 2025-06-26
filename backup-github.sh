#!/bin/sh

# ==============================================================================
# OpenWrt Gist Backup Script (v4 - Paranoid Mode Final)
#
# Changelog:
# - v4: Implemented a robust JSON creation method that avoids shell variables
#       for file content, preventing any potential data corruption during upload.
# ==============================================================================

[ -f ~/.bashrc ] && . ~/.bashrc

# --- Configuration ---
BACKUP_DIR="/tmp/backup_to_github"
BACKUP_FILENAME="openwrt_config_$(date +%Y%m%d_%H%M%S 2>/dev/null | sed 's/://g').tar.gz"
[ -z "$(echo "$BACKUP_FILENAME" | grep '_')" ] && BACKUP_FILENAME="openwrt_config_$(date +%Y%m%d)_$(date +%H%M%S 2>/dev/null | sed 's/://g').tar.gz"

ENCRYPTED_FILENAME="${BACKUP_FILENAME}.enc"
GIST_DESCRIPTION="OpenWrt Config Backup - Encrypted ($(date +%Y-%m-%d %H:%M:%S 2>/dev/null || date +%Y-%m-%d))"
GIST_PUBLIC="false"

# --- Environment Variable Dependencies ---
GITHUB_PAT="${GITHUB_PAT:-}"
ENCRYPTION_PASSWORD="${ENCRYPTION_PASSWORD:-}"
GIST_ID="${BACKUP_GIST_ID:-}"

# --- Script Validation ---
if [ -z "$GITHUB_PAT" ] || [ -z "$ENCRYPTION_PASSWORD" ] || [ -z "$GIST_ID" ]; then
    echo "Error: GITHUB_PAT, ENCRYPTION_PASSWORD, or BACKUP_GIST_ID is not set."
    exit 1
fi

# --- Main Script Logic ---
echo "--- OpenWrt Configuration Backup and Encryption Started ---"

# 1. Create Backup
echo "Creating backup to ${BACKUP_DIR}/${BACKUP_FILENAME}..."
mkdir -p "$BACKUP_DIR"
sysupgrade -b "${BACKUP_DIR}/${BACKUP_FILENAME}"
if [ $? -ne 0 ]; then
    echo "Error: OpenWrt backup creation failed!"
    exit 1
fi

# 2. Encrypt the Backup File
echo "Encrypting backup file with ChaCha20 and PBKDF2..."
openssl enc -chacha20 -e -pbkdf2 -iter 100000 -salt \
  -in "${BACKUP_DIR}/${BACKUP_FILENAME}" \
  -out "${BACKUP_DIR}/${ENCRYPTED_FILENAME}" \
  -pass pass:"${ENCRYPTION_PASSWORD}"
if [ $? -ne 0 ]; then
    echo "Error: Backup file encryption failed!"
    rm -f "${BACKUP_DIR}/${BACKUP_FILENAME}"
    exit 1
fi

# 3. Prepare Gist Payload (Robust Method)
echo "Preparing robust Gist payload..."
JSON_TEMP_FILE="${BACKUP_DIR}/gist_payload.json"

# Build the JSON file piece by piece to avoid storing large content in variables
# a. Write the JSON header
printf '{"description": "%s", "public": %s, "files": {"%s": {"content": "' \
    "${GIST_DESCRIPTION}" "${GIST_PUBLIC}" "${ENCRYPTED_FILENAME}" > "${JSON_TEMP_FILE}"

# b. Append the base64 encoded content directly to the JSON file
base64 -w 0 < "${BACKUP_DIR}/${ENCRYPTED_FILENAME}" >> "${JSON_TEMP_FILE}"

# c. Append the JSON footer
printf '"}}}' >> "${JSON_TEMP_FILE}"

# 4. Push to GitHub Gist using PATCH to update the existing Gist
echo "Pushing encrypted backup to GitHub Gist..."
RESPONSE=$(curl -s -X PATCH \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: token ${GITHUB_PAT}" \
  -H "Content-Type: application/json" \
  --data-binary "@${JSON_TEMP_FILE}" \
  https://api.github.com/gists/${GIST_ID})

GIST_URL=$(echo "$RESPONSE" | jsonfilter -e '@.html_url')

if [ -z "$GIST_URL" ]; then
    echo "Error: Gist upload may have failed."
    echo "Full Response: ${RESPONSE}"
else
    echo "Encrypted backup successfully pushed!"
    echo "Gist URL: ${GIST_URL}"
fi

# 5. Cleanup
rm -f "${BACKUP_DIR}/${BACKUP_FILENAME}"
rm -f "${BACKUP_DIR}/${ENCRYPTED_FILENAME}"
rm -f "${JSON_TEMP_FILE}"

echo "--- Backup Process Finished ---"
