#!/bin/bash

# loop through each webapp and disable them
for app in /etc/systemd/system/webapp-*.service; do
    systemctl disable $(basename "$app")

    # if there was an error, exit with a message
    if [ $? -ne 0 ]; then
        echo "Error disabling $(basename "$app")"
        exit 1
    fi
done

cd /etc/systemd/system/ && rm -f webapp-*.service