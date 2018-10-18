#!/bin/bash

#############
# Parameters
#############
AZUREUSER=$1
ARTIFACTS_URL_PREFIX=$2
ARTIFACTS_URL_SASTOKEN=$3
NETWORK_ID=$4
NODES_COUNT=$5
INITIAL_BALANCE=$6
STORAGE_ACCOUNT_NAME=$7
STORAGE_CONTAINER_NAME=$8
STORAGE_ACCOUNT_KEY=$9


printf -v INITIAL_BALANCE_HEX "%x" "$INITIAL_BALANCE"
printf -v CURRENT_TS_HEX "%x" $(date +%s)

######################
# URL parsing (root)
######################
ARTIFACTS_URL_ROOT=${ARTIFACTS_URL_PREFIX%\/*}

###########
# Constants
###########
HOMEDIR="/home/$AZUREUSER";

#############
# Use the default user
#############
cd "/home/$AZUREUSER";
echo "$@" >> $HOMEDIR/all.params
###########################
# Prepare fuse config
###########################

echo "accountName $STORAGE_ACCOUNT_NAME" > $HOMEDIR/fuse_connection.cfg
echo "accountKey $STORAGE_ACCOUNT_KEY" >> $HOMEDIR/fuse_connection.cfg
echo "containerName $STORAGE_CONTAINER_NAME" >> $HOMEDIR/fuse_connection.cfg


###########################
# Copy asset files to home
###########################
curl -L ${ARTIFACTS_URL_ROOT}/scripts/docker-compose.yml${ARTIFACTS_URL_SASTOKEN} -o $HOMEDIR/docker-compose.yml
curl -L ${ARTIFACTS_URL_ROOT}/scripts/genesis${ARTIFACTS_URL_SASTOKEN} -o $HOMEDIR/genesis
curl -L ${ARTIFACTS_URL_ROOT}/scripts/config${ARTIFACTS_URL_SASTOKEN} -o $HOMEDIR/config

#########################################
# Install docker and compose on all nodes
#########################################
wget https://packages.microsoft.com/config/ubuntu/16.04/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt-get update
sudo apt-get install -y docker-ce blobfuse
sudo systemctl enable docker
sleep 5
sudo curl -L "https://github.com/docker/compose/releases/download/1.22.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

###########################
# Mounting fuse
###########################

chown $AZUREUSER:$AZUREUSER $HOMEDIR/fuse_connection.cfg
chmod 700 $HOMEDIR/fuse_connection.cfg
mkdir -p /mnt/blobfusetmp
chown $AZUREUSER:$AZUREUSER /mnt/blobfusetmp
mkdir $HOMEDIR/shared
chown $AZUREUSER:$AZUREUSER $HOMEDIR/shared
sudo -H -u $AZUREUSER bash -c "blobfuse ${HOMEDIR}/shared --tmp-path=/tmp/blobfusetmp  --config-file=${HOMEDIR}/fuse_connection.cfg"

#########################################
date +%s | sha256sum | base64 | head -c 32 > $HOMEDIR/password.txt
ACCOUNT_ID=$(sudo docker run -v $PWD:/root gochain/gochain gochain --datadir /root/node --password /root/password.txt account new | awk -F '[{}]' '{print $2}')

echo "GOCHAIN_ACCT=0x$ACCOUNT_ID" > $HOMEDIR/.env
echo "GOCHAIN_NETWORK=$NETWORK_ID" >> $HOMEDIR/.env

###########################
# Exchange configs
###########################

echo "console.log(admin.nodeInfo.enode);" > $HOMEDIR/node/enode.js
ENODE_OUTPUT=$(docker run -v $PWD:/root gochain/gochain gochain --datadir /root/node js /root/node/enode.js)
ENODE=${ENODE_OUTPUT:0:137}
IP_ADDRESS=$(ifconfig eth0 | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')
sudo -H -u $AZUREUSER bash -c "echo '  \"${ENODE}${IP_ADDRESS}:30303\",' >> ${HOMEDIR}/shared/enodes"
sudo -H -u $AZUREUSER bash -c "echo '    \"0x${ACCOUNT_ID}\",' >> ${HOMEDIR}/shared/accounts"

# ###########################
# # Generate genesis
# ###########################
COUNTER=0
while sleep 10 && [ "$COUNTER" -lt 60 ] #wait for no more than 10 minutes
do
    SIZE=$(sudo -H -u $AZUREUSER bash -c "wc -l < ${HOMEDIR}/shared/accounts")
    echo "Number of accounts ${SIZE} nodes count ${NODES_COUNT} counter ${COUNTER}"
    if [ "$SIZE" -ge "$NODES_COUNT" ]; then
        echo "Found 3 lines" >> ${HOMEDIR}/output.log
        break;
    fi
    COUNTER=$[$COUNTER +1]
done

sleep 10

ADDRESSES=$(sudo -H -u $AZUREUSER bash -c "cat ${HOMEDIR}/shared/accounts")
ADDRESSES=${ADDRESSES%?}; # remove the last character

echo "Addresses ${ADDRESSES}" >> ${HOMEDIR}/output.log
echo "Address ${ADDRESS}" >> ${HOMEDIR}/output.log

ADDRESS=(${ADDRESSES[@]});#get the first address from the list
ADDRESS=${ADDRESS%?}; # remove the last character
sed -i "s/#NETWORKID/$NETWORK_ID/g" $HOMEDIR/genesis || exit 1;
sed -i "s/#CURRENTTSHEX/$CURRENT_TS_HEX/g" $HOMEDIR/genesis || exit 1;
echo "$(awk -v  r="${ADDRESSES}" "{gsub(/#ADDRESSES/,r)}1" genesis)" > genesis
sed -i "s/#ADDRESS/$ADDRESS/g" $HOMEDIR/genesis || exit 1;
sed -i "s/#HEX/$INITIAL_BALANCE_HEX/g" $HOMEDIR/genesis || exit 1;

mv $HOMEDIR/genesis $HOMEDIR/genesis.json

# ###########################
# # Generate config
# ###########################
ENODES=$(sudo -H -u $AZUREUSER bash -c "cat ${HOMEDIR}/shared/enodes")
ENODES=${ENODES%?}; # remove the last character
sed -i "s/#NETWORKID/$NETWORK_ID/g" $HOMEDIR/config || exit 1;
echo "$(awk -v  r="${ENODES}" "{gsub(/#NODES/,r)}1" config)" > config
mv $HOMEDIR/config $HOMEDIR/config.toml

sudo rm -rf $PWD/node/GoChain
docker run --rm -v $PWD:/gochain -w /gochain gochain/gochain gochain --datadir /gochain/node init genesis.json
#########################################
# Install docker image from private repo
#########################################
docker-compose up -d