#!/bin/bash

# -----------------------------------------------------------------------------
# generate_web_daemons.sh
#
# This script automatically generates systemd service files for web applications
# located in /home/butlah/webapps. Each folder in this directory should contain
# a "start.sh" script to start the application and a "stop.sh" script to stop it.
#
# The generated systemd service files will be placed in /etc/systemd/system.
#
# To use this script:
# 1. Save it as generate_web_daemons.sh.
# 2. Make it executable: chmod +x generate_web_daemons.sh
# 3. Run it as root: sudo ./generate_web_daemons.sh
#
# NOTE: This script should be run as root.
# -----------------------------------------------------------------------------

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

for service_file in /etc/systemd/system/webapp*.service; do
  service_name=$(basename $service_file)
  systemctl disable $service_name
done

echo
echo "--------------------------------------------------------------------"
echo

mkdir -p /srv/webapps/archive
echo "Moving all webapp files to /srv/webapps/archive"
mv /etc/systemd/system/webapp-* /srv/webapps/archive

echo
echo "--------------------------------------------------------------------"
echo

# Loop through each folder in /srv/webapps
for dir in /srv/webapps/*; do
  # Check if it is a directory
  if [ -d "$dir" ]; then
    # If the service starts with an underscore, assume it is not meant to be enabled
    if [[ $(basename $dir) = _* ]]
    then
      echo "*** $dir starts with an underscore (_)... Skipping."
      continue
    fi

    app_name=$(basename "$dir")
    service_file="/etc/systemd/system/webapp-${app_name}.service"

    # Create systemd service file for the app

cat <<EOL > "$service_file"
[Unit]
Description=Kicks off proxied web app: ${app_name}
After=network.target

[Service]
ExecStart=/bin/bash -c ./start.sh
ExecStop=/bin/bash -c ./stop.sh
WorkingDirectory=${dir}
Restart=always
RestartSec=10
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOL

    # Reload and enable the service
    systemctl daemon-reload
    systemctl enable "webapp-${app_name}.service"
  fi
done

echo "Service files generated and enabled."