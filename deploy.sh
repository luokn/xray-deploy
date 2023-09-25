#!/usr/bin/bash
# -*- coding: utf-8 -*-
# @File   : deploy.sh
# @Data   : 2023/03/20
# @Author : Luo Kun
# @Contact: luokun485@gmail.com

DOMAIN=
PROXY=
DRY_RUN=

PASSWD=$(uuidgen | xxd -r -p | base32 | tr -d =)
GRPC_UUID=$(uuidgen | xxd -r -p | base32 | tr -d =)
CONF_UUID=$(uuidgen | xxd -r -p | base32 | tr -d =)
RULE_UUID=$(uuidgen | xxd -r -p | base32 | tr -d =)

GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
DL_URL_REG="https://github.com/XTLS/Xray-core/releases/download/v[0-9|.]+/Xray-linux-64.zip"

XRAY_CONFIG="https://raw.githubusercontent.com/luokn/xray-deploy/main/templates/xray-grpc"
NGINX_CONFIG="https://raw.githubusercontent.com/luokn/xray-deploy/main/templates/nginx"
CLASH_CONFIG="https://raw.githubusercontent.com/luokn/xray-deploy/main/templates/clash"

# Get the domain name from command line
while [[ $# -gt 0 ]]; do
    case $1 in
    -d | --domain)
        DOMAIN=$2
        shift 2
        ;;
    -p | --proxy)
        PROXY=$2
        shift 2
        ;;
    --dry-run)
        DRY_RUN=echo
        shift 1
        ;;
    *)
        echo "Usage: $0 -d <DOMAIN> -p <PROXY> [--dry-run]"
        exit 2
        ;;
    esac
done

# Check if the domain name is specified
if [ -z "$DOMAIN" ]; then
    echo "Please specify the domain name!"
    exit 2
fi

# Check if the proxy server name is specified
if [ -z "$PROXY" ]; then
    echo "Please specify the proxy server name!"
    exit 2
fi

# Check if the script is run as root
if [ "$(whoami)" != "root" ]; then
    echo "Please run this script as root!"
    exit 1
fi

# Check if the domain name is valid
if [ "$(uname -m)" != "x86_64" ]; then
    echo "This script only supports x86_64!"
    exit 1
fi

install_dependencies() {
    local TMP_FILE=/tmp/Xray-linux-64.zip
    local TMP_DIR=/tmp/Xray-linux-64

    echo "Installing dependencies..."

    # Install certbot/nginx/git/curl from apt.

    $DRY_RUN apt update
    $DRY_RUN apt install certbot nginx git curl unzip

    # Install xray from github if it is not installed.
    if [ -z "$(which xray)" ]; then
        # Get the download url of the latest release.
        local DL_URL=$(curl -sL $GITHUB_API | grep -oE $DL_URL_REG | head -n 1)
        if [ -z $DL_URL ]; then
            echo "Failed to get download url from github!"
            exit 1
        fi
        # Download the latest release.
        curl -sL $DL_URL -o $TMP_FILE
        if [ $? -ne 0 ]; then
            echo "Failed to download Xray from github!"
            exit 1
        fi
        # Unzip the downloaded file.
        unzip -o $TMP_FILE -d $TMP_DIR
        if [ $? -ne 0 ]; then
            echo "Failed to unzip Xray!"
            exit 1
        fi
        # Move the binary file to /usr/local/bin.
        # Move the geoip.dat/geosite.dat to /usr/local/share.
        $DRY_RUN mv -f $TMP_DIR/xray /usr/local/bin/
        $DRY_RUN mv -f $TMP_DIR/geo* /usr/local/share/

        # Remove the temporary files.
        $DRY_RUN rm -rf $TMP_DIR $TMP_FILE
    else
        echo "Xray is already installed! Remove it first if you want to reinstall it."
        exit 1
    fi
}

ensure_https_certs() {
    if [ -d /etc/letsencrypt/live/$DOMAIN ]; then
        echo "Renewing HTTPS certificates..."

        $DRY_RUN certbot renew
        if [ $? -ne 0 ]; then
            echo "Failed to renew HTTPS certificates!"
            exit 1
        fi
    else
        echo "Generating HTTPS certificates..."

        $DRY_RUN certbot certonly --webroot -w /var/www/html -d $DOMAIN -d www.$DOMAIN
        if [ $? -ne 0 ]; then
            echo "Failed to generate HTTPS certificates!"
            exit 1
        fi
    fi
}

enable_xray_service() {
    local SYSTEMD_SERVICE="[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target"

    echo "Enabling xray systemd service..."

    if [ -z "$DRY_RUN" ]; then
        # Generate the xray systemd service file.
        echo "$SYSTEMD_SERVICE" >|/usr/lib/systemd/system/xray.service
    else
        echo "echo $SYSTEMD_SERVICE >|/usr/lib/systemd/system/xray.service"
    fi

    # Enable the xray systemd service.
    $DRY_RUN systemctl daemon-reload
    $DRY_RUN systemctl enable xray
}

download_clash_rules() {
    cd /var/www
    if [ ! -d /var/www/clash-rules ]; then
        echo "Cloning clash-rules from GitHub..."

        $DRY_RUN git clone https://github.com/luokn/clash-rules
        if [ $? -ne 0 ]; then
            echo "Failed to clone clash-rules from GitHub!"
            exit 1
        fi
    fi
    cd -
}

download_clash_dashboard() {
    cd /var/www
    if [ ! -d /var/www/clash-dashboard ]; then
        echo "Cloning clash-dashboard from GitHub..."

        $DRY_RUN git clone https://github.com/Dreamacro/clash-dashboard
        if [ $? -ne 0 ]; then
            echo "Failed to clone clash-dashboard from GitHub!"
            exit 1
        fi

        # Link clash-dashboard to html
        $DRY_RUN rm -rf ./html
        $DRY_RUN ln -sf ./clash-dashboard ./html

        # Checkout gh-pages branch
        $DRY_RUN cd html
        $DRY_RUN git checkout gh-pages
        $DRY_RUN cd -
    fi
    cd -
}

generate_clash_config() {
    local TMP_FILE=/tmp/clash-config

    echo "Generating clash config file..."

    # Download the clash config template.
    curl -sL $CLASH_CONFIG -o $TMP_FILE
    if [ $? -ne 0 ]; then
        echo "Failed to download clash config template!"
        exit 1
    fi
    sed -i "s/@PROXY/$PROXY/g;s/@DOMAIN/$DOMAIN/g;s/@PASSWD/$PASSWD/g;s/@GRPC_UUID/$GRPC_UUID/g;s/@RULE_UUID/$RULE_UUID/g" $TMP_FILE
    # Move the clash config file to /var/www.
    $DRY_RUN mv -bf $TMP_FILE /var/www/clash-config.yaml
}

configure_nginx() {
    local TMP_FILE=/tmp/nginx-config

    echo "Configuring nginx..."

    # Download the nginx config template.
    curl -sL $NGINX_CONFIG -o $TMP_FILE
    if [ $? -ne 0 ]; then
        echo "Failed to download nginx config template!"
        exit 1
    fi
    sed -i "s/@DOMAIN/$DOMAIN/g;s/@GRPC_UUID/$GRPC_UUID/g;s/@CONF_UUID/$CONF_UUID/g;s/@RULE_UUID/$RULE_UUID/g" $TMP_FILE
    # Move the nginx config file to /etc/nginx/sites-available.
    $DRY_RUN mv -bf $TMP_FILE /etc/nginx/sites-available/default

    # Restart nginx.
    $DRY_RUN systemctl restart nginx
}

configure_xray() {
    local TMP_FILE=/tmp/xray-config

    echo "Downloading xray config template..."

    # Download the xray config template.
    curl -sL $XRAY_CONFIG -o $TMP_FILE
    if [ $? -ne 0 ]; then
        echo "Failed to download xray config template!"
        exit 1
    fi
    sed -i "s/@DOMAIN/$DOMAIN/g;s/@PASSWD/$PASSWD/g;s/@GRPC_UUID/$GRPC_UUID/g" $TMP_FILE
    # Move the xray config file to /usr/local/etc/xray.
    $DRY_RUN mv -bf $TMP_FILE /usr/local/etc/xray/config.json

    # Restart xray.
    $DRY_RUN systemctl restart xray
}

enable_xray_logging() {
    local LOGROTATE_CONF="/var/log/xray/*.log {
    rotate 10
    daily
    dateext 
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}"

    # Ensure the log directory exists.
    $DRY_RUN mkdir -p /var/log/xray

    if [[ -d /var/log/xray ]] && [[ "$(stat -c %U:%G /var/log/xray)" != "nobody:nogroup" ]]; then
        $DRY_RUN chown -R nobody:nogroup /var/log/xray
    fi

    if [ ! -f /etc/logrotate.d/xray ]; then
        echo "Configuring logrotate for xray..."

        if [ -z $DRY_RUN ]; then
            # Generate the logrotate config file.
            echo "$LOGROTATE_CONF" >|/etc/logrotate.d/xray
        else
            echo "echo $LOGROTATE_CONF >|/etc/logrotate.d/xray"
        fi
    fi
}

enable_bbr() {
    if [ -z "$(lsmod | grep tcp_bbr)" ]; then
        echo "Enabling BBR for congestion control..."

        if [ -z $DRY_RUN ]; then
            # Enable BBR for congestion control.
            echo "net.core.default_qdisc=fq" >>/etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.conf
            sysctl -p --quiet
        else
            echo "echo net.core.default_qdisc=fq >>/etc/sysctl.conf"
            echo "echo net.ipv4.tcp_congestion_control=bbr >>/etc/sysctl.conf"
            echo "sysctl -p --quiet"
        fi
    fi
}

# 1. Install dependencies.
install_dependencies

# 2. Ensure HTTPS certificates are generated
#    - If the certificates are not generated, generate them via certbot.
#    - If the certificates are generated, renew them via certbot.
ensure_https_certs

# 3. Configure nginx for serving static files and proxying requests to xray.
# 3.1 Configure xray logging.
enable_xray_logging
# 3.2 Enable xray systemd service.
enable_xray_service
# 3.3 Configure xray.
configure_xray

# 4. Configure nginx for serving static files and proxying requests to xray.
# 4.1 Download clash rules.
download_clash_rules
# 4.2 Download clash dashboard.
download_clash_dashboard
# 4.3 Generate clash config.
generate_clash_config
# 4.4 Configure nginx.
configure_nginx

# 5. Enable BBR
enable_bbr

echo "Deployment completed!"
echo "Subsciption URL: https://$DOMAIN/$CONF_UUID"
