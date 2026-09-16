#!/bin/bash
set -e

echo "[initunlocklnd] Waiting 2 seconds for lnd..."
sleep 2

# ensure that lnd is up and running before proceeding
while
    CA_CERT="$LND_DATA/tls.cert"
    LND_WALLET_DIR="$LND_DATA/data/chain/$1/$2/"
    MACAROON_FILE="$LND_DATA/admin.macaroon"
    MACAROON_HEADER="r0ckstar:dev"
    if [ -f "$MACAROON_FILE" ]; then
        MACAROON_HEADER="Grpc-Metadata-macaroon:$(xxd -p -c 10000 "$MACAROON_FILE" | tr -d ' ')"
    fi

    STATUS_CODE=$(curl -s --cacert "$CA_CERT" -H $MACAROON_HEADER -o /dev/null -w "%{http_code}" $LND_REST_LISTEN_HOST/v1/getinfo)
    # if lnd is running it'll either return 200 if unlocked (noseedbackup=1) or 404 if it needs initialization/unlock 
    if [ "$STATUS_CODE" == "200" ] || [ "$STATUS_CODE" == "404" ] ; then
        break
    # or 500 from version 0.13.1 onwards because it breaks with `wallet not created, create one to enable full RPC access` error
    elif [ "$STATUS_CODE" == "500" ] ; then
        STATUS_CODE=$(curl -s --cacert "$CA_CERT" -H $MACAROON_HEADER $LND_REST_LISTEN_HOST/v1/state)
        if [ "$STATUS_CODE" == "{\"state\":\"NON_EXISTING\"}" ] || [ "$STATUS_CODE" == "{\"state\":\"LOCKED\"}" ] ; then
            break # wallet ready to be either created or unlocked
        fi
        # for {\"state\":\"UNLOCKED\"}" we will depend on that previous condition with STATUS_CODE 200 or 404
        # because even though wallet is unlocked, /v1/getinfo will still keep returning 500 until it's ready

        echo "[initunlocklnd] Still waiting on LND, got response for wallet status: $STATUS_CODE ... waiting another 2 seconds..."
        sleep 2
    else
        echo "[initunlocklnd] LND still didn't start, got $STATUS_CODE status code back... waiting another 2 seconds..."
        sleep 2
    fi
do true; done

# read variables after we ensured that lnd is up
CA_CERT="$LND_DATA/tls.cert"
LND_WALLET_DIR="$LND_DATA/data/chain/$1/$2/"
MACAROON_FILE="$LND_DATA/admin.macaroon"
MACAROON_HEADER="r0ckstar:dev"
if [ -f "$MACAROON_FILE" ]; then
    MACAROON_HEADER="Grpc-Metadata-macaroon:$(xxd -p -c 10000 "$MACAROON_FILE" | tr -d ' ')"
fi

WALLET_FILE="$LND_WALLET_DIR/wallet.db"
LNDUNLOCK_FILE=${WALLET_FILE/wallet.db/walletunlock.json}
if [ -f "$WALLET_FILE" ]; then
    if [ ! -f "$LNDUNLOCK_FILE" ]; then
        echo "[initunlocklnd] WARNING: UNLOCK FILE DOESN'T EXIST! MIGRATE LEGACY INSTALLATION TO NEW VERSION ASAP"
    else
        echo "[initunlocklnd] Wallet and Unlock files are present... parsing wallet password and unlocking lnd"

        # parse wallet password from unlock file
        WALLETPASS=$(jq -c -r '.wallet_password' "$LNDUNLOCK_FILE")
        # Nicolas deleted default password in some wallet unlock files, so we initializing default if password is empty
        if [ "$WALLETPASS" == "" ] || [ "$WALLETPASS" == "null" ]; then
            WALLETPASS="hellorockstar"
        fi
        # base64 of the stored password for the REST calls
        WALLETPASS_BASE64=$(echo $WALLETPASS | tr -d '\n\r' | base64)
        # a password change that was started but never confirmed leaves its new password here
        NEWPASS_FILE="$LNDUNLOCK_FILE.newpassword"
        NEWPASS=$(cat "$NEWPASS_FILE" 2>/dev/null || true)
        NEWPASS_BASE64=""
        if [[ "$NEWPASS" ]]; then NEWPASS_BASE64=$(printf %s "$NEWPASS" | base64 | tr -d '\n'); fi

        post() {
            curl -sS --cacert "$CA_CERT" -X POST -H "$MACAROON_HEADER" -d "$2" "$LND_REST_LISTEN_HOST/v1/$1" \
                || { echo "[initunlocklnd] Request to lnd failed, outcome unknown; nothing was changed in $LNDUNLOCK_FILE" >&2; exit 1; }
        }
        # the one lnd error that means "try the next password"; anything else stops us
        wrong_password() { [[ "$1" == *"invalid passphrase for master public key"* ]]; }
        # write the confirmed working password into walletunlock.json
        save_password() {
            jq -c --arg pw "$1" '.wallet_password = $pw' "$LNDUNLOCK_FILE" > "$LNDUNLOCK_FILE.tmp" && mv "$LNDUNLOCK_FILE.tmp" "$LNDUNLOCK_FILE"
        }

        if [[ "${LND_MACAROONS_RESET:-false}" == true ]]; then
            # 1. Macaroons were just cleared: only unlock, so lnd recreates the store and
            #    its tokens. changepassword needs that store, so a legacy password is
            #    changed on the next start instead. The unconfirmed new password, if
            #    any, goes first because lnd may already have it.
            for CANDIDATE in "$NEWPASS_BASE64" "$WALLETPASS_BASE64" "$(printf %s hellorockstar | base64)"; do
                [[ "$CANDIDATE" ]] || continue
                response=$(post unlockwallet '{ "wallet_password":"'$CANDIDATE'" }')
                if [[ "$response" == "{}" ]]; then break; fi
                wrong_password "$response" || break
            done
            if [[ "$response" == "{}" ]]; then
                # keep the password that actually worked; the unconfirmed one is moot now
                save_password "$(printf %s "$CANDIDATE" | base64 -d)"
                rm -f "$NEWPASS_FILE"
                echo "[initunlocklnd] Wallet unlocked after the macaroon reset; a legacy password is changed on the next start"
            else
                echo "[initunlocklnd] Wallet unlocking failed, lnd returned: $response"
                exit 1
            fi
        elif [[ "$NEWPASS" || "$WALLETPASS" == "hellorockstar" ]]; then
            # 2. Legacy shared default password (or an unconfirmed change): move to a
            #    random one. lnd re-encrypts wallet.db BEFORE it touches macaroons.db, so
            #    the new password is saved to a file first and only moved into
            #    walletunlock.json once lnd confirms the change.
            if [[ -z "$NEWPASS" ]]; then
                NEWPASS=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
                printf '%s\n' "$NEWPASS" > "$NEWPASS_FILE"
                NEWPASS_BASE64=$(printf %s "$NEWPASS" | base64 | tr -d '\n')
            fi
            # a successful changepassword returns {} (macaroons disabled) or {"admin_macaroon":"..."}
            for CANDIDATE in "$NEWPASS_BASE64" "$WALLETPASS_BASE64"; do
                response=$(post changepassword '{ "current_password":"'$CANDIDATE'", "new_password":"'$NEWPASS_BASE64'" }')
                if [[ "$response" == "{}" || "$response" == *'"admin_macaroon"'* ]]; then break; fi
                wrong_password "$response" || break
            done
            if [[ "$response" == "{}" || "$response" == *'"admin_macaroon"'* ]]; then
                save_password "$NEWPASS" && rm -f "$NEWPASS_FILE"
                echo "[initunlocklnd] Migrated wallet off the default password; the new random password is in $LNDUNLOCK_FILE"
            else
                echo "[initunlocklnd] WARNING: password change failed, lnd returned: $response"
                echo "[initunlocklnd] Wallet is still locked; the new password stays in $NEWPASS_FILE and is retried on the next start"
                echo "[initunlocklnd] If lnd reported a macaroon store error: stop LND, delete macaroons.db (only that file) and start it again"
                exit 1
            fi
        else
            # 3. Normal start: unlock with the saved random password.
            response=$(post unlockwallet '{ "wallet_password":"'$WALLETPASS_BASE64'" }')
            if [[ "$response" == "{}" ]]; then
                echo "[initunlocklnd] Wallet unlocked"
            else
                echo "[initunlocklnd] Wallet unlocking failed, lnd returned: $response"
                exit 1
            fi
        fi

    fi
else
    echo "[initunlocklnd] Wallet file doesn't exist. Initializing LND instance with new autogenerated password and seed"

    # generate seed mnemonic
    GENSEED_RESP=$(curl -s --cacert "$CA_CERT" -X GET -H $MACAROON_HEADER $LND_REST_LISTEN_HOST/v1/genseed)
    CIPHER_ARRAY_EXTRACTED=$(echo $GENSEED_RESP | jq -c -r '.cipher_seed_mnemonic')

    # random per-instance password, stored in cleartext in the unlock file next
    # to wallet.db (the file that BTCPay's seed backup view exposes)
    WALLETPASS=$(head -c 32 /dev/urandom | base64 | tr -d '\n')

    # save all the the data to unlock file we'll use for future unlocks
    RESULTJSON='{"wallet_password":"'$WALLETPASS'", "cipher_seed_mnemonic":'$CIPHER_ARRAY_EXTRACTED'}'
    mkdir -p $LND_WALLET_DIR
    echo $RESULTJSON > $LNDUNLOCK_FILE

    # previous versions will have a default wallet password including a line feed at the end "hellorockstar\n"
    # line feed hex code 0x0A.
    WALLETPASS_BASE64=$(echo $WALLETPASS | tr -d '\n\r' | base64)
    INITWALLET_REQ='{"wallet_password":"'$WALLETPASS_BASE64'", "cipher_seed_mnemonic":'$CIPHER_ARRAY_EXTRACTED'}'

    # execute initwallet call
    curl -s --cacert "$CA_CERT" -X POST -H "$MACAROON_HEADER" -d "$INITWALLET_REQ" $LND_REST_LISTEN_HOST/v1/initwallet
fi

# LND unlocked, now run Loop

if [ ! -z "$LND_HOST_FOR_LOOP" ]; then
    echo "[initunlocklnd] Preparing to start Loop"

    if [ $LND_ENVIRONMENT == "regtest" ] || [ $LND_ENVIRONMENT == "signet" ]; then
        echo "[initunlocklnd] Loop can't be started for regtest and signet"
    elif [ -f "$MACAROON_FILE" ]; then
        sleep 10

        echo "[initunlocklnd] Starting Loop"
        ./bin/loopd --network=$2 --lnd.macaroonpath=$MACAROON_FILE --lnd.host=$LND_HOST_FOR_LOOP --restlisten=0.0.0.0:8081 &
    else
        echo "[initunlocklnd] Loop can't be started without MACAROON"
    fi
fi