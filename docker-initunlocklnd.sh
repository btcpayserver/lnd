#!/bin/bash
set -e
umask 077

save_json_file() {
    local file=$1 temporary
    shift
    temporary=$(mktemp "$file.tmp.XXXXXX")
    if [[ -f "$file" ]]; then
        jq -c "$@" "$file" > "$temporary"
    else
        jq -nc "$@" > "$temporary"
    fi
    jq -es 'length == 1 and (.[0] | type == "object" or type == "array")' "$temporary" >/dev/null
    sync
    mv -f "$temporary" "$file"
    sync
}

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
if [[ -f "$LNDUNLOCK_FILE" ]] && ! jq -es 'length == 1 and (.[0] | type == "object")' "$LNDUNLOCK_FILE" >/dev/null; then
    echo "[initunlocklnd] Invalid $LNDUNLOCK_FILE; restore valid JSON before automatic startup. LND remains available for manual unlock"
    exit 1
fi
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
        # Preserve the exact password in JSON, including any stored newline.
        # Legacy files sometimes omit the newline that was sent to LND.
        WALLETPASS_BASE64=$(jq -r '(.wallet_password // "") |
            if . == "" then "hellorockstar" else . end | @base64' "$LNDUNLOCK_FILE")

        # ChangePassword can change wallet.db and then fail on macaroons.db.
        # Save every candidate BEFORE the RPC. Keep the existing password and
        # seed fields, and retain the history even after a successful change.
        PENDING_PASSWORD=$(jq -r 'has("wallet_password_pending")' "$LNDUNLOCK_FILE")
        if [[ "$WALLETPASS" == "hellorockstar" || "$PENDING_PASSWORD" == true ]]; then
            PASSWORD_HISTORY="$LNDUNLOCK_FILE.password-history"
            if [[ "$PENDING_PASSWORD" == true ]]; then
                NEWPASS=$(jq -er '.wallet_password_pending | select(type == "string" and length >= 8)' "$LNDUNLOCK_FILE")
            elif [[ -f "$PASSWORD_HISTORY" ]]; then
                # Older BTCPay versions can discard extra JSON fields when
                # removing the seed. The separate history preserves this retry.
                NEWPASS=$(jq -er '.[-1].new_password | select(type == "string" and length >= 8)' "$PASSWORD_HISTORY")
                PENDING_PASSWORD=true
            else
                NEWPASS=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
                [[ ${#NEWPASS} == 44 ]]
            fi
            NEWPASS_BASE64=$(printf %s "$NEWPASS" | base64 | tr -d '\n')
            # line feed hex code 0x0A: oldest installs have the default
            # password including a trailing line feed, so if the corrected
            # one fails we retry the rotation from that variant
            WALLETPASS_BASE64_CURRENT=$(printf '%s\n' "$WALLETPASS" | base64 | tr -d '\n')
            # Never copy the seed into history: removing it must remain useful.
            save_json_file "$PASSWORD_HISTORY" --arg pw "$NEWPASS" --arg old "$WALLETPASS_BASE64" \
                --arg legacy "$WALLETPASS_BASE64_CURRENT" '
                (. // []) + [{new_password:$pw, old_password:($old | @base64d),
                    legacy_password:($legacy | @base64d)}]'
            save_json_file "$LNDUNLOCK_FILE" --arg pw "$NEWPASS" '.wallet_password_pending = $pw'

            rotate_response=""
            PASSWORDS=("$WALLETPASS_BASE64" "$WALLETPASS_BASE64_CURRENT")
            if [[ "$PENDING_PASSWORD" == true ]]; then
                PASSWORDS=("$NEWPASS_BASE64" "${PASSWORDS[@]}")
            fi

            # Retrying from the candidate also finishes a rotation whose
            # response was lost. Only a wrong wallet password permits fallback.
            for CURRENT_PASSWORD in "${PASSWORDS[@]}"; do
                ENDPOINT=changepassword
                REQUEST="{\"current_password\":\"$CURRENT_PASSWORD\",\"new_password\":\"$NEWPASS_BASE64\",\"new_macaroon_root_key\":${LND_PASSWORD_ROTATE_MACAROONS:-false}}"
                if [[ "${LND_PASSWORD_REPAIR_AUTH:-false}" == true ]]; then
                    ENDPOINT=unlockwallet
                    REQUEST="{\"wallet_password\":\"$CURRENT_PASSWORD\"}"
                fi
                if ! rotate_response=$(curl -sS --max-time 120 --cacert "$CA_CERT" -X POST -H "$MACAROON_HEADER" \
                    -d "$REQUEST" "$LND_REST_LISTEN_HOST/v1/$ENDPOINT"); then
                    echo "[initunlocklnd] Request outcome unknown; passwords are preserved in $LNDUNLOCK_FILE"
                    exit 1
                fi
                if ! jq -e '(.message // "") | contains("invalid passphrase for master public key")' >/dev/null <<< "$rotate_response"; then
                    break
                fi
            done

            response=""
            if jq -e 'type == "object" and (. == {} or
                (has("code") | not) and (.admin_macaroon | type == "string"))' >/dev/null <<< "$rotate_response"; then
                if [[ "${LND_PASSWORD_REPAIR_AUTH:-false}" == true ]]; then
                    save_json_file "$LNDUNLOCK_FILE" --arg pw "$CURRENT_PASSWORD" '.wallet_password = ($pw | @base64d)'
                    echo "[initunlocklnd] Authentication files repaired and wallet unlocked. Restart the LND container once to finish the saved password migration"
                else
                    save_json_file "$LNDUNLOCK_FILE" --arg pw "$NEWPASS" '.wallet_password = $pw | del(.wallet_password_pending)'
                    echo "[initunlocklnd] Migrated wallet off the default password; the new random password is in $LNDUNLOCK_FILE"
                fi
                if [[ "${LND_PASSWORD_ROTATE_MACAROONS:-false}" == true ]]; then
                    touch "$LND_DATA/.macaroon-rotated-$LND_MACAROON_ROTATION_ID"
                fi
                response="{}"
            else
                echo "[initunlocklnd] WARNING: migration off the default password failed, lnd returned: $rotate_response"
                echo "[initunlocklnd] Passwords are preserved in $LNDUNLOCK_FILE; migration is not complete"
                echo "[initunlocklnd] For a confirmed macaroon-store error: stop LND, back up its data outside $LND_DATA, and move aside only macaroons.db and *.macaroon files"
                echo "[initunlocklnd] Keep wallet.db, channel databases, $LNDUNLOCK_FILE and $PASSWORD_HISTORY. Start LND again and follow the repair message; never delete a live database"
                exit 1
            fi
        else
        response=$(curl -s --cacert "$CA_CERT" -X POST -H "$MACAROON_HEADER" \
            -d '{ "wallet_password":"'$WALLETPASS_BASE64'" }' $LND_REST_LISTEN_HOST/v1/unlockwallet)

        if [[ "$response" == "{}" ]]; then
            echo "[initunlocklnd] Wallet unlocked"
        else
            # Older files can omit a trailing newline from a custom password.
            # Unlock with that variant; changing it is unnecessary.
            if jq -e '(.message // "") | contains("invalid passphrase for master public key")' >/dev/null <<< "$response"; then
                WALLETPASS_BASE64_CURRENT=$(printf '%s\n' "$WALLETPASS" | base64 | tr -d '\n')
                response=$(curl -s --cacert "$CA_CERT" -X POST -H "$MACAROON_HEADER" \
                    -d '{ "wallet_password":"'$WALLETPASS_BASE64_CURRENT'" }' "$LND_REST_LISTEN_HOST/v1/unlockwallet")
            fi

            if [[ "$response" == "{}" ]]; then
                echo "[initunlocklnd] Wallet unlocked with the legacy newline password"
            else
                echo "[initunlocklnd] Wallet unlocking failed: $response"
                exit 1
            fi
        fi
        fi
    fi
else
    echo "[initunlocklnd] Wallet file doesn't exist. Initializing LND using saved password and seed"

    # Reuse a saved initialization request if an earlier startup was interrupted.
    if [[ ! -f "$LNDUNLOCK_FILE" ]]; then
        GENSEED_RESP=$(curl -s --cacert "$CA_CERT" -X GET -H "$MACAROON_HEADER" "$LND_REST_LISTEN_HOST/v1/genseed")
        CIPHER_ARRAY_EXTRACTED=$(jq -ce '.cipher_seed_mnemonic | select(type == "array" and length == 24)' <<< "$GENSEED_RESP")
        WALLETPASS=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
        mkdir -p "$LND_WALLET_DIR"
        save_json_file "$LNDUNLOCK_FILE" --arg pw "$WALLETPASS" --argjson seed "$CIPHER_ARRAY_EXTRACTED" \
            '{wallet_password:$pw,cipher_seed_mnemonic:$seed}'
    fi

    # Encode directly from JSON so an existing password's newline is preserved.
    INITWALLET_REQ=$(jq -ce 'select((.wallet_password | type == "string" and length >= 8) and
        (.cipher_seed_mnemonic | type == "array" and length == 24)) |
        {wallet_password:(.wallet_password | @base64),cipher_seed_mnemonic}' "$LNDUNLOCK_FILE")

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
