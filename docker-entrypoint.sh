#!/bin/bash
set -e

if [[ "$1" == "lnd" || "$1" == "lncli" ]]; then
	mkdir -p "$LND_DATA"

	cat <<-EOF > "$LND_DATA/lnd.conf"
	${LND_EXTRA_ARGS}
	EOF

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
            echo "Unknown value for LND_CHAIN, expected btc or ltc"
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

        if [[ $LND_EXPLORERURL ]]; then
            # We need to do that because LND behave weird if it starts at same time as bitcoin core, or if the node is not synched
            echo "Waiting for the node to start and sync"
            dotnet /opt/NBXplorer.NodeWaiter/NBXplorer.NodeWaiter.dll --chains "$LND_CHAIN" --network "$LND_ENVIRONMENT" --explorerurl "$LND_EXPLORERURL"
            echo "Node synched"
        fi
    fi

	ln -sfn "$LND_DATA" /root/.lnd
    ln -sfn "$LND_BITCOIND" /root/.bitcoin
    ln -sfn "$LND_LITECOIND" /root/.litecoin
    ln -sfn "$LND_BTCD" /root/.btcd
	exec "$@"
else
	exec "$@"
fi
