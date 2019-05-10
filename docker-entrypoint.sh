#!/bin/bash
set -e

if [[ "$1" == "lnd" || "$1" == "lncli" ]]; then
	mkdir -p "$LND_DATA"

	cat <<-EOF > "$LND_DATA/lnd.conf"
	${LND_EXTRA_ARGS}
    listen=0.0.0.0:${LND_PORT}
	EOF

    if [[ "${LND_EXTERNALIP}" ]]; then
        echo "externalip=$LND_EXTERNALIP:${LND_PORT}" >> "$LND_DATA/lnd.conf"
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
            ENV="mainnet"
        elif [[ $LND_ENVIRONMENT == "testnet" ]]; then
            ENV="testnet"
        elif [[ $LND_ENVIRONMENT == "regtest" ]]; then
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

    if [[ "${LND_READY_FILE}" ]]; then
        echo "Waiting $LND_READY_FILE to be created..."
        while [ ! -f "$LND_READY_FILE" ]; do sleep 1; done
        echo "The chain is fully synched"
    fi

    if [[ "${LND_HIDDENSERVICE_HOSTNAME_FILE}" ]]; then
        echo "Waiting $LND_HIDDENSERVICE_HOSTNAME_FILE to be created by tor..."
        while [ ! -f "$LND_HIDDENSERVICE_HOSTNAME_FILE" ]; do sleep 1; done
        HIDDENSERVICE_ONION="$(head -n 1 "$LND_HIDDENSERVICE_HOSTNAME_FILE"):${LND_PORT}"
        echo "externalip=$HIDDENSERVICE_ONION" >> "$LND_DATA/lnd.conf"
        echo "externalip=$HIDDENSERVICE_ONION added to $LND_DATA/lnd.conf"
    fi

    ln -sfn "$LND_DATA" /root/.lnd
    ln -sfn "$LND_BITCOIND" /root/.bitcoin
    ln -sfn "$LND_LITECOIND" /root/.litecoin
    ln -sfn "$LND_BTCD" /root/.btcd

    exec "$@"
else
	exec "$@"
fi
