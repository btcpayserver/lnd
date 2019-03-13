#!/bin/bash
set -e

if [[ "$1" == "lnd" || "$1" == "lncli" ]]; then
	mkdir -p "$LND_DATA"

	cat <<-EOF > "$LND_DATA/lnd.conf"
	${LND_EXTRA_ARGS}
	EOF

    NBXPLORER_DATA_DIR_NAME=""
    if [[ "${LND_EXTERNALIP}" ]]; then
        # This allow to strip this parameter if LND_EXTERNALIP is not a proper domain
        LND_EXTERNAL_HOST=$(echo ${LND_EXTERNALIP} | cut -d ':' -f 1)
        LND_EXTERNAL_PORT=$(echo ${LND_EXTERNALIP} | cut -d ':' -f 2)
        if [[ "$LND_EXTERNAL_HOST" ]] && [[ "$LND_EXTERNAL_PORT" ]]; then
            echo "externalip=$LND_EXTERNALIP" >> "$LND_DATA/lnd.conf"
            echo "externalip=$LND_EXTERNALIP added to $LND_DATA/lnd.conf"
        fi
    fi

    if [[ "${LND_ALIAS}" ]]; then
        # This allow to strip this parameter if LND_ALIAS is empty or null, and truncate it
        LND_ALIAS="$(echo "$LND_ALIAS" | cut -c -32)"
        echo "alias=$LND_ALIAS" >> "$LND_DATA/lnd.conf"
        echo "alias=$LND_ALIAS added to $LND_DATA/lnd.conf"
    fi

    if [[ $LND_CHAIN && $LND_ENVIRONMENT ]]; then
        echo "LND_CHAIN=$LND_CHAIN"
        echo "LND_ENVIRONMENT=$LND_ENVIRONMENT"

        NETWORK=""

        shopt -s nocasematch
        if [[ $LND_CHAIN == "btc" ]]; then
            NETWORK="bitcoin"
        elif [[ $LND_CHAIN == "ltc" ]]; then
            NETWORK="litecoin"
        else
            echo "Unknwon value for LND_CHAIN, expected btc or ltc"
        fi

        ENV=""
        # Make sure we use correct casing for LND_Environment
        if [[ $LND_ENVIRONMENT == "mainnet" ]]; then
            NBXPLORER_DATA_DIR_NAME="Main"
            ENV="mainnet"
        elif [[ $LND_ENVIRONMENT == "testnet" ]]; then
            NBXPLORER_DATA_DIR_NAME="TestNet"
            ENV="testnet"
        elif [[ $LND_ENVIRONMENT == "regtest" ]]; then
            NBXPLORER_DATA_DIR_NAME="RegTest"
            ENV="regtest"
        else
            echo "Unknwon value for LND_ENVIRONMENT, expected mainnet, testnet or regtest"
        fi
        shopt -u nocasematch

        if [[ $ENV && $NETWORK ]]; then
            echo "
            $NETWORK.active=1
            $NETWORK.$ENV=1
            " >> "$LND_DATA/lnd.conf"
            echo "Added $NETWORK.active and $NETWORK.$ENV to config file $LND_DATA/lnd.conf"
        else
            echo "LND_CHAIN or LND_ENVIRONMENT is not set correctly"
        fi
    fi

    if [[ "${LND_NBXPLORER_ROOT}" ]]; then
        NBXPLORER_READY_FILE="${LND_NBXPLORER_ROOT}/${NBXPLORER_DATA_DIR_NAME}/${LND_CHAIN}_fully_synched"
        echo "Waiting $NBXPLORER_READY_FILE to be signaled by nbxplorer..."
        while [ ! -f "$NBXPLORER_READY_FILE" ]; do sleep 1; done
        echo "The chain is fully synched"
    fi

    ln -sfn "$LND_DATA" /root/.lnd
    ln -sfn "$LND_BITCOIND" /root/.bitcoin
    ln -sfn "$LND_LITECOIND" /root/.litecoin
    ln -sfn "$LND_BTCD" /root/.btcd

    if [[ "$LND_CHAIN" == "ltc" && "$LND_ENVIRONMENT" == "testnet" ]]; then
        echo "LTC on testnet is not supported, let's sleep instead!"
        while true; do sleep 86400; done
    else
        exec "$@"
    fi
else
	exec "$@"
fi
