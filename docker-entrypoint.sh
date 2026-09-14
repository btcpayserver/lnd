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

    if [[ "${RPCUSER_FILE}" ]]; then
        echo "Waiting $RPCUSER_FILE to be created..."
        while [ ! -f "$RPCUSER_FILE" ]; do sleep 1; done
        printf 'bitcoind.rpcpass=%s\n' "$(< "$RPCUSER_FILE")" >> "$LND_DATA/lnd.conf"
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

    # Rotate root keys once per ID to revoke every previously issued macaroon.
    # Password changes need the existing keys: let ChangePassword rotate them
    # and write the marker on success. Otherwise clear authentication data
    # before LND starts, so it recreates the keys and tokens on normal unlock.
    export LND_PASSWORD_ROTATE_MACAROONS=false
    export LND_PASSWORD_REPAIR_AUTH=false
    PASSWORD_MIGRATION=false
    if [[ -f "$LNDUNLOCK_FILE" ]]; then
        if ! PASSWORD_MIGRATION=$(jq -rs '
            if length != 1 or (.[0] | type) != "object" then error("invalid unlock file") else .[0] end |
            (.wallet_password // "" | rtrimstr("\n")) as $pw |
            has("wallet_password_pending") or $pw == "" or $pw == "hellorockstar"' "$LNDUNLOCK_FILE"); then
            echo "[lnd_unlock_entrypoint] Invalid $LNDUNLOCK_FILE; preserving authentication files and starting LND locked for repair"
            PASSWORD_MIGRATION=invalid
        fi
    fi
    ROTATE_FILES=false
    ROTATION_MARKER="$LND_DATA/.macaroon-rotated-$LND_MACAROON_ROTATION_ID"
    if [[ "${LND_MACAROON_ROTATION_ID}" ]]; then
        if [[ ! -f "$ROTATION_MARKER" ]]; then
            if [[ -f "$WALLET_FILE" && "$PASSWORD_MIGRATION" == true ]]; then
                export LND_PASSWORD_ROTATE_MACAROONS=true
            elif [[ "$PASSWORD_MIGRATION" != invalid ]]; then
                ROTATE_FILES=true
            fi
        fi
    fi

    if [[ -f "$WALLET_FILE" && "$PASSWORD_MIGRATION" == true ]]; then
        # A fresh store cannot change passwords. Missing macaroon files also
        # make native rotation fail. Repair via plain unlock on this boot.
        if [[ ! -s "${WALLET_FILE/wallet.db/macaroons.db}" ]]; then
            export LND_PASSWORD_REPAIR_AUTH=true
        fi
        if [[ "$LND_PASSWORD_ROTATE_MACAROONS" == true ]]; then
            for NAME in admin readonly invoice; do
                MACAROON_PATH=$(sed -n "s/^[[:space:]]*${NAME}macaroonpath[[:space:]]*=[[:space:]]*//p" "$LND_DATA/lnd.conf" | tail -n 1)
                MACAROON_PATH=${MACAROON_PATH:-${WALLET_FILE/wallet.db/$NAME.macaroon}}
                if [[ ! -s "$MACAROON_PATH" ]]; then export LND_PASSWORD_REPAIR_AUTH=true; fi
            done
        fi
    fi
    if [[ "$ROTATE_FILES" == true || "$LND_PASSWORD_REPAIR_AUTH" == true ]]; then
        echo "[lnd_unlock_entrypoint] Rotating macaroons ($LND_MACAROON_ROTATION_ID), ALL existing macaroons are being invalidated"
        # Always before LND opens the database, never delete a live store.
        find "$LND_DATA" -type f \( -name '*.macaroon' -o -name 'macaroons.db' \) \
            -print -exec rm -f {} \;
        if [[ "$LND_PASSWORD_REPAIR_AUTH" != true ]]; then touch "$ROTATION_MARKER"; fi
        echo "[lnd_unlock_entrypoint] Macaroons removed, lnd will regenerate them. Every client must be re-paired"
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
