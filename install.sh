#!/bin/bash

# Set program name variable - basename without subshell
prog=${0##*/}

dir=$(pwd)

function usage ()
{
    cat << EOF
NAME
    $prog - Install ZEN Cash secure node
DESCRIPTION
    A bash that helps to install ZEN Cash secure node by one command
EOF
}

# Display help
if [ "$1" == "-h" ]; then
    usage
    exit 0
fi

function loadTemplates ()
{
    for FILE in ${dir}/templates/*; do source $FILE; done
}

function readData ()
{
    read -r -p "System user that will be used as node operator (for example ubuntu): " USER_OPERATOR
    # Validate user exists in system
    if ! id "$USER_OPERATOR" >/dev/null 2>&1; then
        echo "System user not exists. Please fix error and try again."
        exit 0
    fi

    USER_HOMEDIR="$(getent passwd "$USER_OPERATOR" | cut -d: -f6)"

    read -r -p "Staking transparent address: " STACK_ADDRESS

    read -r -p "Alert email address: " EMAIL_ADDRESS

    read -r -p "FQDN (it should be already pointed to current server): " FQDN

    read -r -p "IP address version used for connection - 4 or 6 (default 4): " IP_VERSION
    [ -z "${IP_VERSION}" ] && IP_VERSION="4"

    # Validate ip address version
    if [ "$IP_VERSION" -ne 4 ] || [ "$IP_VERSION" -ne 6 ] ; then
        echo "IP version incorrect, used default 4";
        IP_VERSION=4
    fi
}

function update ()
{
    sudo apt-get update -y
}

function upgrade ()
{
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

function installRequirements ()
{
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        debconf-doc \
        git \
        jq \
        apt-transport-https \
        lsb-release \
        dnsutils \
        socat \
        pwgen \
        npm
}

function installZenDaemon ()
{
    if [ -x "$(command -v zend)" ]; then
        # zend already installed. skip this
        stopZenDaemon
        return 0
    fi

    rm /etc/apt/sources.list.d/zen.list
    echo 'deb https://zencashofficial.github.io/repo/ '$(lsb_release -cs)' main' | tee --append /etc/apt/sources.list.d/zen.list
    gpg --keyserver ha.pool.sks-keyservers.net --recv 219F55740BBF7A1CE368BA45FB7053CE4991B669
    gpg --export 219F55740BBF7A1CE368BA45FB7053CE4991B669 | apt-key add -
    update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y zen
    zen-fetch-params
    mkdir ${USER_HOMEDIR}/.zen
    echo "$ZEN_CONF" > ${USER_HOMEDIR}/.zen/zen.conf
}

function stopZenDaemon () {
    zen-cli stop
    sleep 10
}


function startZenDaemon () {

    if pgrep -x "zend" > /dev/null
    then
        stopZenDaemon
    fi

    zend

    while true
        do
            zen-cli getinfo &> /dev/null
            if [ $? -eq 0 ]; then
                break
            else
                sleep 1
                continue
            fi
        done
}

function installCertificate () {

    if [ -f /usr/local/share/ca-certificates/${FQDN}.crt ]; then
        # Certificate already installed. skip it
        return 0
    fi

    cd ${USER_HOMEDIR} && git clone https://github.com/Neilpang/acme.sh.git
    cd ${USER_HOMEDIR}/acme.sh && ./acme.sh --install

    cd ${USER_HOMEDIR}/acme.sh && sudo ./acme.sh --issue --standalone -d ${FQDN}

    if [ ! -f ${USER_HOMEDIR}./acme.sh/${FQDN}/ca.cer ]; then
        echo "Certificate was not installed, please check logs above."
        exit 1
    fi

    cp ${USER_HOMEDIR}/.acme.sh/${FQDN}/ca.cer /usr/share/ca-certificates/${FQDN}.crt
    cp ${USER_HOMEDIR}/.acme.sh/${FQDN}/ca.cer /usr/local/share/ca-certificates/${FQDN}.crt
    update-ca-certificates

    cat <<EOF >> ~/.zen/zen.conf
    tlscertpath=${USER_HOMEDIR}/.acme.sh/${FQDN}/${FQDN}.cer
    tlskeypath=${USER_HOMEDIR}/.acme.sh/${FQDN}/${FQDN}.key
EOF
}

function createZAddress() {

    if [ ! $(zen-cli z_listaddresses | jq '. | length') = 0 ]; then
        # private address already exists. skip this
        return 0
    fi

    while true
        do
            Z_ADDRESS=$(zen-cli z_getnewaddress)
            if [ $? -eq 0 ]; then
                break
            else
                sleep 2
                continue
            fi
        done
}

function installTracker () {
    npm install -g n
    n latest

    if [ ! -d "$USER_HOMEDIR/zencash" ]; then
        mkdir ${USER_HOMEDIR}/zencash
        cd ${USER_HOMEDIR}/zencash && git clone https://github.com/ZencashOfficial/secnodetracker.git
        cd ${USER_HOMEDIR}/zencash/secnodetracker && npm install
        cd ${USER_HOMEDIR}/zencash/secnodetracker && sudo npm install pm2 -g
    fi

    if [ -d "$USER_HOMEDIR/zencash" ]; then
        rm -rf ${USER_HOMEDIR}/zencash/secnodetracker/config/*
    fi

    mkdir ${USER_HOMEDIR}/zencash/secnodetracker/config
    echo -n "$FQDN"             >> ${USER_HOMEDIR}/zencash/secnodetracker/config/fqdn
    echo -n "$EMAIL_ADDRESS"    >> ${USER_HOMEDIR}/zencash/secnodetracker/config/email
    echo -n "$IP_VERSION"       >> ${USER_HOMEDIR}/zencash/secnodetracker/config/ipv
    echo -n "$STACK_ADDRESS"    >> ${USER_HOMEDIR}/zencash/secnodetracker/config/stakeaddr

    cd ${USER_HOMEDIR}/zencash/secnodetracker && yes "" | node setup.js
    cd ${USER_HOMEDIR}/zencash/secnodetracker && pm2 start app.js --name securenodetracker

    pm2 stop all
}

function checkBlockSynchronization() {
    while true
        do
            zen-cli getpeerinfo &> /dev/null
            if [ $? -ne 0 ]; then
                sleep 2
                continue
            fi

            CURRENT_BLOCK=$(zen-cli getblockcount)
            NETWORK_BLOCK=$(zen-cli getpeerinfo | jq '.[0].startingheight')

            CURRENT_BLOCK=$((CURRENT_BLOCK + 0))
            NETWORK_BLOCK=$((NETWORK_BLOCK + 0))

            if [ -z "$NETWORK_BLOCK" ]; then
                if (( "$CURRENT_BLOCK" >= "$NETWORK_BLOCK" )); then
                    break
                fi
            fi

            echo -ne "Synchronizing blockchain... ${CURRENT_BLOCK}/${NETWORK_BLOCK}\r"
            sleep 2
        done
}

function printFinishInstructions() {
    echo "Installation of your secure node almost done."
    echo "To continue with installation please send 4 or 5 transactions of 0.1 to 0.25 zen to your node private address from the ZenCash wallet you have running on your PC or Mac."
    echo "Your node private address is: ${Z_ADDRESS}"
    echo "After that start your tracker using following command: pm2 start all"
}

# HOT FIX fix user permissions
function fixPermissions()
{
    sudo chown ${USER_OPERATOR}:${USER_OPERATOR} ${USER_HOMEDIR}
}

# Ask a root privileges
if [[ $UID != 0 ]]; then
    echo "Please run ${prog} with sudo:"
    echo "sudo ./${prog}"
    exit 1
fi

# Main code

readData

update

installRequirements

upgrade

loadTemplates

installZenDaemon

installCertificate

startZenDaemon

createZAddress

checkBlockSynchronization

installTracker

# HOT FIX
fixPermissions

printFinishInstructions
