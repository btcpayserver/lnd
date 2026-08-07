#!/bin/bash
set -e

if [[ "$1" == "lnd" || "$1" == "lncli" ]]; then
	mkdir -p "$LND_DATA"

    # removing noseedbackup=1 flag, adding it below if needed for legacy
    LND_EXTRA_ARGS=${LND_EXTRA_ARGS/noseedbackup=1/}
    
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
            echo "Unknown value for LND_CHAIN, expected btc or ltc"
        fi

        ENV=""
        # Make sure we use correct casing for LND_Environment
        if [[ $LND_ENVIRONMENT == "mainnet" ]]; then
            ENV="mainnet"
        elif [[ $LND_ENVIRONMENT == "testnet" ]]; then
            ENV="testnet"
        elif [[ $LND_ENVIRONMENT == "signet" ]]; then
            ENV="signet"
        elif [[ $LND_ENVIRONMENT == "regtest" ]]; then
            ENV="regtest"
        else
            echo "Unknown value for LND_ENVIRONMENT, expected mainnet, testnet, signet or regtest"
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

    # if it is legacy installation, then trigger warning and add noseedbackup=1 to config if needed
    WALLET_FILE="$LND_DATA/data/chain/$NETWORK/$ENV/wallet.db"
    LNDUNLOCK_FILE=${WALLET_FILE/wallet.db/walletunlock.json}
    if [ -f "$WALLET_FILE" -a  ! -f "$LNDUNLOCK_FILE" ]; then
        echo "[lnd_unlock_entrypoint] WARNING: UNLOCK FILE DOESN'T EXIST! MIGRATE LEGACY INSTALLATION TO NEW VERSION ASAP"
        echo "noseedbackup=1" >> "$LND_DATA/lnd.conf"
    fi

    # One-time macaroon rotation, for revoking macaroons that leaked. Deleting
    # the macaroon files is not enough on its own: lnd re-bakes equivalent
    # tokens from the same root key, so macaroons.db has to go too. lnd then
    # creates a new root key and regenerates its own macaroons on unlock.
    # Every macaroon on the volume is dead once that root key is gone, hand
    # baked ones included, so all of them are cleared rather than left behind
    # as tokens that no longer work. Runs before lnd starts, so nothing is
    # holding the files open. Bump LND_MACAROON_ROTATION_ID to rotate again.
    if [[ "${LND_MACAROON_ROTATION_ID}" ]]; then
        ROTATION_MARKER="$LND_DATA/.macaroon-rotated-$LND_MACAROON_ROTATION_ID"
        if [ ! -f "$ROTATION_MARKER" ]; then
            echo "[lnd_unlock_entrypoint] Rotating macaroons ($LND_MACAROON_ROTATION_ID), ALL existing macaroons are being invalidated"
            # -exec rm rather than -delete, busybox find on alpine may not have it
            find "$LND_DATA" -type f \( -name '*.macaroon' -o -name 'macaroons.db' \) \
                -print -exec rm -f {} \;
            touch "$ROTATION_MARKER"
            echo "[lnd_unlock_entrypoint] Macaroons removed, lnd will regenerate them. Every client must be re-paired"
        fi
    fi

    # hit up the auto initializer and unlocker on separate process to do it's work
    ./docker-initunlocklnd.sh $NETWORK $ENV &

    ln -sfn "$LND_DATA" /root/.lnd
    ln -sfn "$LND_BITCOIND" /root/.bitcoin
    ln -sfn "$LND_LITECOIND" /root/.litecoin
    ln -sfn "$LND_BTCD" /root/.btcd

    exec "$@"
else
	exec "$@"
fi
