#!/bin/bash

set -euo pipefail

# Logo
# Credit: figlet font slant by Glenn Chappell
LOGO=$(cat << "EOF"
   __                  __                             __ 
  / /____  ____  _____/ /_____  _____________  ____  / /_
 / __/ _ \/ __ \/ ___/ __/ __ \/ ___/ ___/ _ \/ __ \/ __/
/ /_/  __/ / / (__  ) /_/ /_/ / /  / /  /  __/ / / / /_  
\__/\___/_/ /_/____/\__/\____/_/  /_/   \___/_/ /_/\__/  
EOF
)

# Fetch latest kmd from git tags
TT_KMD_GIT_URL="https://github.com/tenstorrent/tt-kmd.git"
fetch_latest_kmd_version() {
    local latest_kmd=$(git ls-remote --tags "$TT_KMD_GIT_URL" | grep -v '\^{}' | awk -F/ '{print $NF}' | sort -V | tail -n1)
    echo "${latest_kmd#ttkmd-}"
}

# Fetch lastest FW version
TT_FW_GIT_URL="https://github.com/tenstorrent/tt-firmware.git"
fetch_latest_fw_version() {
    local latest_fw=$(git ls-remote --tags "$TT_FW_GIT_URL" | grep -v '\^{}' | awk -F/ '{print $NF}' | sort -V | tail -n1)
    echo "${latest_fw#v}" # Remove 'v' prefix if present
}

# Fetch latest systools version
# Currently unused due to systools tags being broken
TT_SYSTOOLS_GIT_URL="https://github.com/tenstorrent/tt-system-tools.git"
fetch_latest_systools_version() {
    local latest_systools=$(git ls-remote --tags "$TT_SYSTOOLS_GIT_URL" | grep -v '\^{}' | awk -F/ '{print $NF}' | sort -V | tail -n1)
    echo "${latest_systools#v}" # Remove 'upstream/' prefix
}

# Optional assignment- uses TT_ envvar version if present, otherwise latest
KMD_VERSION="${TT_KMD_VERSION:-$(fetch_latest_kmd_version)}"
FW_VERSION="${TT_FW_VERSION:-$(fetch_latest_fw_version)}"
# Use manual systools version for now
SYSTOOLS_VERSION="${TT_SYSTOOLS_VERSION:-"1.1-5_all"}"

# Update FW_FILE based on FW_VERSION
FW_FILE="fw_pack-${FW_VERSION}.fwbundle"

# Create working directory
TMP_DIR_TEMPLATE="tenstorrent_install_XXXXXX"
# Use mktemp to get a temporary directory
WORKDIR=$(mktemp -d -p /tmp "$TMP_DIR_TEMPLATE")

# Initialize logging
LOG_FILE="${WORKDIR}/install.log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# log messages to both terminal (with color) and logfile (without color)
log() {
    local msg="[INFO] $1"
    echo -e "${GREEN}${msg}${NC}"  # Color output to terminal
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE"  # Plain output to logfile
}

# log errors
error() {
    local msg="[ERROR] $1"
    echo -e "${RED}${msg}${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE"
}

# log warnings
warn() {
    local msg="[WARNING] $1"
    echo -e "${YELLOW}${msg}${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE"
}

check_has_sudo_perms() {
    if [[ ! -x "/usr/bin/sudo" ]]
    then
        error "Cannot use sudo, exiting..."
        exit 1
    fi
}

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID=$ID
        DISTRO_VERSION=$VERSION_ID
        check_is_ubuntu_20
    else
        error "Cannot detect Linux distribution"
        exit 1
    fi
}

check_is_ubuntu_20() {
    # Check if it's Ubuntu and version starts with 20
    if [ "$DISTRO_ID" = "ubuntu" ] && [[ "$DISTRO_VERSION" == 20* ]]; then
        IS_UBUNTU_20=0 # Ubuntu 20.xx
    else
        IS_UBUNTU_20=1 # Not that
    fi
}

# Function to verify download
verify_download() {
    local file=$1
    if [ ! -f "$file" ]; then
        error "Download failed: $file not found"
        exit 1
    fi
}

# Function to prompt for yes/no
confirm() {
    while true; do
        read -rp "$1 [Y/n] " yn
        case $yn in
            [Nn]* ) return 1;;
            [Yy]* | "" ) return 0;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Main installation script
main() {
    echo -e "$LOGO"
    echo # newline
    log "Welcome to tenstorrent!"
    log "Log is at ${LOG_FILE}"
    log "This script will install drivers and tooling and properly configure your tenstorrent hardware."
    if ! confirm "OK to continue?"; then
        error "Exiting."
        exit 1
    fi
    log "Starting installation"
    log "Using software versions:"
    log "  KMD: ${KMD_VERSION}"
    log "  Firmware: ${FW_VERSION}"
    log "  System Tools: ${SYSTOOLS_VERSION}"

    log "Checking for sudo permissions... (may request password)"
    check_has_sudo_perms

    # Check distribution and install base packages
    detect_distro
    log "Installing base packages"
    case "$DISTRO_ID" in
        "ubuntu"|"debian")
            sudo apt update
            # The pipx version on ubuntu 20 is too old to install git packages. It's not needed.
            if [[ "$IS_UBUNTU_20" != "0" ]]; then
                sudo apt install -y wget git python3-pip dkms cargo rustc pipx
            else
                sudo apt install -y wget git python3-pip dkms cargo rustc
            fi
            ;;
        "fedora")
            sudo dnf check-update
            sudo dnf install -y wget git python3-pip dkms cargo rust pipx
            ;;
        "rhel"|"centos")
            sudo dnf install -y epel-release
            sudo dnf check-update
            sudo dnf install -y wget git python3-pip dkms cargo rust pipx
            ;;
        *)
            error "Unsupported distribution: $DISTRO"
            exit 1
            ;;
    esac


    # Python package installation preference
    log "How would you like to install Python packages?"
    echo "1. Use the active virtual environment"
    echo "2. [DEFAULT] Create a new Python virtual environment (venv) at ~/.tenstorrent-venv"
    # The pipx version on ubuntu 20 is too old to install git packages. They must use a venv
    if [[ "$IS_UBUNTU_20" != "0" ]]; then
        echo "3. Use pipx for isolated package installation"
    fi
    read -rp "Enter your choice (1, 2...) or press enter for default: " PYTHON_CHOICE

    case $PYTHON_CHOICE in
        1)
            if [ -z "${VIRTUAL_ENV:-}" ]; then
                error "No active virtual environment detected!"
                error "Please activate your virtual environment first and try again"
                exit 1
            fi
            log "Using active virtual environment: $VIRTUAL_ENV"
            INSTALLED_IN_VENV=0
            PYTHON_INSTALL_CMD="pip install"
            ;;
        3)
            log "Checking for pipx"
            pipx ensurepath
            PYTHON_INSTALL_CMD="pipx install"
            ;;
        *|"2"|"")
            log "Setting up new Python virtual environment"
            python3 -m venv "$HOME/.tenstorrent-venv"
            source "$HOME/.tenstorrent-venv/bin/activate"
            INSTALLED_IN_VENV=0
            PYTHON_INSTALL_CMD="pip install"
            ;;
    esac

    # Install TT-KMD
    log "Installing Kernel-Mode Driver"
    cd "$WORKDIR"
    git clone https://github.com/tenstorrent/tt-kmd.git
    cd tt-kmd || exit 1
    sudo dkms add .
    sudo dkms install "tenstorrent/$KMD_VERSION"
    sudo modprobe tenstorrent

    # Install TT-Flash and Firmware
    log "Installing TT-Flash and updating firmware"
    cd "$WORKDIR"
    $PYTHON_INSTALL_CMD git+https://github.com/tenstorrent/tt-flash.git

    wget "https://github.com/tenstorrent/tt-firmware/raw/main/${FW_FILE}"
    verify_download "$FW_FILE"

    if ! tt-flash --fw-tar "$FW_FILE"; then
        warn "Initial firmware update failed, attempting force update"
        tt-flash --fw-tar "$FW_FILE" --force
    fi

    # Setup HugePages
    log "Setting up HugePages"
    wget "https://github.com/tenstorrent/tt-system-tools/releases/download/upstream%2F1.1/tenstorrent-tools_${SYSTOOLS_VERSION}.deb"
    verify_download "tenstorrent-tools_$SYSTOOLS_VERSION.deb"
    sudo dpkg -i "tenstorrent-tools_$SYSTOOLS_VERSION.deb"
    sudo systemctl enable --now tenstorrent-hugepages.service
    sudo systemctl enable --now 'dev-hugepages\x2d1G.mount'

    # Install TT-SMI
    log "Installing System Management Interface"
    $PYTHON_INSTALL_CMD git+https://github.com/tenstorrent/tt-smi

    log "Installation completed successfully!"
    log "Installation log saved to: $LOG_FILE"
    if [ "$INSTALLED_IN_VENV" = "0" ]; then
        warn "You'll need to run \"source $VIRTUAL_ENV/bin/activate\" to use tenstorrent tools."
    fi
    log "Please reboot your system to complete the setup."

    if confirm "Would you like to reboot now?"; then
        sudo reboot
    fi
}

# Start installation
main
