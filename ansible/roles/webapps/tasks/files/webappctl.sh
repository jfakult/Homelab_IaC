#!/bin/bash

# Function to display help message
show_help() {
    echo "Usage: ./webappctl.sh [command] [optional: app_name]"
    echo ""
    echo "Commands:"
    echo "  start      Start all webapps or a specific one if app_name is provided"
    echo "  stop       Stop all webapps or a specific one if app_name is provided"
    echo "  restart    Restart all webapps or a specific one if app_name is provided"
    echo "  scan       Scan the webapps dir for new webapps and create new symlinks (invokes generate_web_daemons.sh)"
    echo "  status     Show status of all webapps or a specific one if app_name is provided"
}

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

# No arguments, show help
if [ $# -eq 0 ]; then
    show_help
    exit 1
fi

if [ "$1" = "scan" ]; then
    echo "Scanning for new web daemons..."
    /srv/generate_web_daemons.sh
    exit 0
fi

# Get the list of all webapps
webapps=($(cd /etc/systemd/system/ && ls -1 webapp-*.service))

# If webapps is null, exit
if [ ${#webapps[@]} -eq 0 ]; then
    echo "No webapps found. Have you run generate_web_daemons.sh?"
    exit 1
fi

# Validate the command argument
if [ "$1" != "start" ] && [ "$1" != "stop" ] && [ "$1" != "restart" ] && [ "$1" != "status" ] && [ "$1" != "scan" ]; then
    echo "Invalid command."
    show_help
    exit 1
fi

# If only the command argument is given, perform it on all webapps
if [ $# -eq 1 ]; then
    for app in "${webapps[@]}"; do
        echo "Performing '$1' on ${app%.service}..."
        systemctl $1 ${app%.service}
    done
else
    # Check if the specified webapp exists
    if [[ ! " ${webapps[@]} " =~ " webapp-$2.service " ]]; then
        echo "Webapp '$2' not found."
        exit 1
    fi

    # Perform the command on the specified webapp
    systemctl $1 webapp-$2
fi