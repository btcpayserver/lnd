#!/bin/bash
set -e

if [[ "$1" == "lnd" || "$1" == "lncli" ]]; then
	mkdir -p "$LND_DATA"

	cat <<-EOF > "$LND_DATA/lnd.conf"
	${LND_EXTRA_ARGS}
	EOF

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

    ln -sfn "$LND_DATA" /root/.lnd
    ln -sfn "$LND_BITCOIND" /root/.bitcoin
    ln -sfn "$LND_LITECOIND" /root/.litecoin
    ln -sfn "$LND_BTCD" /root/.btcd

    if [[ "$LND_CHAIN" == "ltc" && "$LND_ENVIRONMENT" == "testnet" ]]; then
        echo "LTC on testnet is not supported, let's sleep instead!"
        while true; do sleep 86400; done
    else
        # NBXplorer.NodeWaiter.dll is a wrapper which wait the full node to be fully synced before starting LND
        # it also correctly handle SIGINT and SIGTERM so this container can die properly if SIGKILL or SIGTERM is sent
        exec dotnet /opt/NBXplorer.NodeWaiter/NBXplorer.NodeWaiter.dll --chains "$LND_CHAIN" --network "$LND_ENVIRONMENT" --explorerurl "$LND_EXPLORERURL" -- \
             $@
    fi
else
	exec "$@"
fi
