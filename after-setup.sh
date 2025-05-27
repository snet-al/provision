# Copy all provisioning scripts to forge user's home
echo "Copying provisioning scripts to forge user's home directory..."
SCRIPTS_DIR="/home/forge/provision"
sudo -u forge mkdir -p "$SCRIPTS_DIR"
sudo cp ./*.sh "$SCRIPTS_DIR/"
sudo cp README.md "$SCRIPTS_DIR/" 2>/dev/null || true
sudo chown -R forge:forge "$SCRIPTS_DIR"
sudo chmod -R 750 "$SCRIPTS_DIR"

echo "Provisioning scripts copied to $SCRIPTS_DIR"