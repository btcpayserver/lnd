#!/bin/bash
# Disposable regtest integration tests using the released, unmodified LND binary.
# Run: bash docker-startup-tests.sh (Docker, curl and jq required).
# Historical newline cases are unsupported compatibility probes (expected to fail):
# TEST_SCENARIOS='newline stored-newline custom-newline custom-stored-newline rotation-newline rotation-custom-newline' bash docker-startup-tests.sh
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
IMAGE=btcpayserver/lnd:v0.21.3-beta-1
NAME=btcpay-startup-$$
BTC=$NAME-bitcoin
LND=$NAME-lnd
PEER=$NAME-peer
VOLUME=$NAME-data
WALLET=/data/data/chain/bitcoin/regtest/walletunlock.json
WORK=$(mktemp -d)
cleanup() {
    docker rm -fv "$LND" "$PEER" "$BTC" >/dev/null 2>&1 || true
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
    docker network rm "$NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'echo "FAIL ${SCENARIO:-setup} at test line $LINENO" >&2; docker logs --tail 25 "$LND" >&2 || true; docker logs --tail 15 "$PEER" >&2 || true' ERR
wait_for() {
    for ((i=0; i<120; i++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    docker logs --tail 35 "$LND" >&2 || true
    docker logs "$LND" 2>&1 | grep '^\[initunlocklnd\]' >&2 || true
    echo "Timed out waiting for $1" >&2
    return 1
}
bitcoin() { docker exec "$BTC" bitcoin-cli -regtest -rpcuser=test -rpcpassword=test "$@"; }
address() { docker inspect "$LND" | jq -r --arg n "$NAME" '.[0].NetworkSettings.Networks[$n].IPAddress'; }
auth() {
    curl -sf --max-time 5 -H "Grpc-Metadata-macaroon:$(docker exec "$LND" xxd -p -c 10000 /data/admin.macaroon)" "$URL/v1/$1"
}
funded() { auth balance/blockchain | jq -e '.confirmed_balance | tonumber >= 100000000'; }
channel_open() { auth channels | jq -e '.channels | length == 1'; }
peer_connected() { auth peers | jq -e --arg key "$PEER_KEY" 'any(.peers[]; .pub_key == $key)'; }
channels() { auth channels | jq -Sc '[.channels[] | {channel_point,remote_pubkey,capacity,local_balance,remote_balance}]'; }
peer_info() {
    curl -sf --max-time 5 -H "Grpc-Metadata-macaroon:$(docker exec "$PEER" xxd -p -c 10000 /data/admin.macaroon)" "$PEER_URL/v1/getinfo"
}
ready() {
    auth getinfo >/dev/null || return 1
    [[ "$SCENARIO" == fresh ]] || docker logs "$LND" 2>&1 | grep -Eq 'Wallet unlocked|Migrated wallet'
}
failed() { docker logs "$LND" 2>&1 | grep -Eq 'Wallet unlocking failed|password change failed|parse error'; }
offline() { docker run --rm -i -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c "$1"; }
saved() { docker exec "$LND" cat "$WALLET"; }
replacement() { docker exec "$LND" cat "$WALLET.newpassword"; }
count() { offline 'if [ -f /data/launches ]; then wc -l < /data/launches; else echo 0; fi'; }
upgrade() {
    docker run -d --name "$LND" --network "$NAME" --network-alias lnd \
        -v "$VOLUME:/data" -v "$ROOT/docker-entrypoint.sh:/docker-entrypoint.sh:ro" \
        -v "$ROOT/docker-initunlocklnd.sh:/docker-initunlocklnd.sh:ro" \
        -v "$WORK/count-lnd:/usr/local/bin/lnd:ro" \
        -e LND_CHAIN=btc -e LND_ENVIRONMENT=regtest -e "LND_EXTRA_ARGS=$CONFIG" \
        -e LND_REST_LISTEN_HOST=http://lnd:8080 -e "LND_MACAROON_ROTATION_ID=$ROTATION" "$IMAGE" >/dev/null
    URL=http://$(address):8080
}
# Count execs of the real daemon, including child launches inside a container.
cat > "$WORK/count-lnd" <<'SH'
#!/bin/sh
echo launch >> /data/launches
exec /bin/lnd "$@"
SH
chmod +x "$WORK/count-lnd"
docker network create --internal "$NAME" >/dev/null
docker run -d --name "$BTC" --network "$NAME" --network-alias bitcoin \
    --entrypoint bitcoind btcpayserver/bitcoin:31.1 -regtest -server \
    -fallbackfee=0.0002 \
    -rpcuser=test -rpcpassword=test -rpcbind=0.0.0.0:18443 -rpcallowip=0.0.0.0/0 \
    -listen=0 -zmqpubrawblock=tcp://0.0.0.0:28332 -zmqpubrawtx=tcp://0.0.0.0:28333 >/dev/null
wait_for bitcoin getblockchaininfo
bitcoin createwallet test >/dev/null
bitcoin generatetoaddress 101 "$(bitcoin getnewaddress)" >/dev/null
CONFIG='bitcoin.active=1
bitcoin.regtest=1
bitcoin.node=bitcoind
bitcoind.rpchost=bitcoin:18443
bitcoind.rpcuser=test
bitcoind.rpcpass=test
bitcoind.zmqpubrawblock=tcp://bitcoin:28332
bitcoind.zmqpubrawtx=tcp://bitcoin:28333
restlisten=lnd:8080
no-rest-tls=1
adminmacaroonpath=/data/admin.macaroon
readonlymacaroonpath=/data/readonly.macaroon
invoicemacaroonpath=/data/invoice.macaroon'

for SCENARIO in ${TEST_SCENARIOS:-legacy empty null omitted password-only custom pending-before pending-after rotation rotation-custom rotation-pending rotation-split-store missing-store-old missing-store-new missing-readonly split-store unknown invalid-json fresh}; do
    echo "Testing $SCENARIO"
    ROTATION=
    RESET_EXPECTED=false
    export ACTUAL=hellorockstar STORED=hellorockstar SCENARIO
    case "$SCENARIO" in
        newline|rotation-newline) ACTUAL=$'hellorockstar\n' ;;
        stored-newline) ACTUAL=$'hellorockstar\n'; STORED=$ACTUAL ;;
        custom|rotation-custom) ACTUAL=existing-custom-password; STORED=$ACTUAL ;;
        custom-newline|rotation-custom-newline) ACTUAL=$'existing-custom-password\n'; STORED=existing-custom-password ;;
        custom-stored-newline) ACTUAL=$'existing-custom-password\n'; STORED=$ACTUAL ;;
        unknown) ACTUAL=unsaved-wallet-password ;;
    esac
    case "$SCENARIO" in
        rotation*) ROTATION=test; RESET_EXPECTED=true ;;
        missing-store-*) RESET_EXPECTED=true ;;
    esac
    docker volume create "$VOLUME" >/dev/null
    printf '%s\n' "$CONFIG" | offline 'cat > /data/lnd.conf'
    if [[ "$SCENARIO" != fresh ]]; then
        # Fixture setup is separate from the counted upgrade.
        docker run -d --name "$LND" --network "$NAME" --network-alias lnd \
            -v "$VOLUME:/data" --entrypoint /bin/lnd "$IMAGE" --lnddir=/data >/dev/null
        URL=http://$(address):8080
        wait_for curl -sf --max-time 5 "$URL/v1/genseed"
        SEED=$(curl -sf "$URL/v1/genseed")
        export SEED
        jq -nc '{wallet_password:(env.ACTUAL | @base64),cipher_seed_mnemonic:(env.SEED | fromjson | .cipher_seed_mnemonic)}' |
            curl -sf --data-binary @- "$URL/v1/initwallet" >/dev/null
        wait_for auth getinfo
        IDENTITY=$(auth getinfo | jq -r .identity_pubkey)
        OLD_MACAROON=$(docker exec "$LND" xxd -p -c 10000 /data/admin.macaroon)
        if [[ "$SCENARIO" == password-only || "$SCENARIO" == rotation ]]; then
            # Verify a funded channel and its backup, not only an empty wallet.
            echo "Creating disposable channel peer"
            printf '%s\n' "${CONFIG/restlisten=lnd/restlisten=peer}" > "$WORK/peer.conf"
            docker create --name "$PEER" --network "$NAME" --network-alias peer \
                --entrypoint /bin/lnd "$IMAGE" --lnddir=/data >/dev/null
            docker cp "$WORK/peer.conf" "$PEER:/data/lnd.conf"
            docker start "$PEER" >/dev/null
            PEER_URL=http://$(docker inspect "$PEER" | jq -r --arg n "$NAME" '.[0].NetworkSettings.Networks[$n].IPAddress'):8080
            wait_for curl -sf --max-time 5 "$PEER_URL/v1/genseed"
            curl -sf "$PEER_URL/v1/genseed" | jq -c '{wallet_password:("disposable-peer-password" | @base64),cipher_seed_mnemonic}' |
                curl -sf --data-binary @- "$PEER_URL/v1/initwallet" >/dev/null
            wait_for peer_info
            echo "Funding disposable channel wallet"
            bitcoin sendtoaddress "$(auth newaddress | jq -r .address)" 1 >/dev/null
            bitcoin generatetoaddress 6 "$(bitcoin getnewaddress)" >/dev/null
            wait_for funded
            PEER_KEY=$(peer_info | jq -r .identity_pubkey)
            echo "Connecting disposable channel peer"
            jq -nc --arg key "$PEER_KEY" '{addr:{pubkey:$key,host:"peer:9735"},perm:true}' |
                curl -sf --max-time 60 -H "Grpc-Metadata-macaroon:$OLD_MACAROON" --data-binary @- "$URL/v1/peers" >/dev/null
            wait_for peer_connected
            jq -nc --arg key "$PEER_KEY" '{node_pubkey_string:$key,local_funding_amount:"1000000",private:true,sat_per_vbyte:"2"}' |
                curl -sf --max-time 60 -H "Grpc-Metadata-macaroon:$OLD_MACAROON" --data-binary @- "$URL/v1/channels" >/dev/null
            echo "Confirming disposable channel"
            bitcoin generatetoaddress 6 "$(bitcoin getnewaddress)" >/dev/null
            wait_for channel_open
            CHANNELS=$(channels)
            BACKUP_POINTS=$(auth channels/backup | jq -Sc .multi_chan_backup.chan_points)
        fi
        CUSTOM_MACAROON=$(curl -sf -H "Grpc-Metadata-macaroon:$OLD_MACAROON" \
            -d '{"permissions":[{"entity":"info","action":"read"}],"root_key_id":"7"}' "$URL/v1/macaroon" | jq -er .macaroon)
        BINARY=$(docker exec "$LND" sha256sum /bin/lnd)
        jq -nc '{wallet_password:env.STORED,cipher_seed_mnemonic:(env.SEED | fromjson | .cipher_seed_mnemonic),unrelated:{keep:true}} |
            if env.SCENARIO == "empty" then .wallet_password="" elif env.SCENARIO == "null" then .wallet_password=null
            elif env.SCENARIO == "omitted" then del(.wallet_password) else . end' |
            docker exec -i "$LND" sh -c "cat > $WALLET"
        case "$SCENARIO" in
            pending-*|missing-store-new|*split-store|rotation-pending)
                printf '%s\n' saved-before-request | docker exec -i "$LND" sh -c "cat > $WALLET.newpassword" ;;
        esac
        docker stop "$LND" >/dev/null
        if [[ "$SCENARIO" == *split-store ]]; then
            offline 'cp /data/data/chain/bitcoin/regtest/macaroons.db /data/old-store'
        fi
        if [[ "$SCENARIO" == pending-after || "$SCENARIO" == missing-store-new || "$SCENARIO" == *split-store ]]; then
            docker start "$LND" >/dev/null
            wait_for curl -sf "$URL/v1/state"
            jq -nc '{current_password:(env.ACTUAL | @base64),new_password:("saved-before-request" | @base64)}' |
                curl -sf --data-binary @- "$URL/v1/changepassword" >/dev/null
            wait_for auth getinfo
            docker stop "$LND" >/dev/null
            ACTUAL=saved-before-request
        fi
        docker rm "$LND" >/dev/null
        case "$SCENARIO" in
            missing-store-*) offline 'rm /data/data/chain/bitcoin/regtest/macaroons.db' ;;
            missing-readonly) offline 'rm /data/readonly.macaroon' ;;
            *split-store) offline 'mv /data/old-store /data/data/chain/bitcoin/regtest/macaroons.db' ;;
            invalid-json) offline 'printf "{" > /data/data/chain/bitcoin/regtest/walletunlock.json' ;;
        esac
        offline "sha256sum $WALLET" > "$WORK/before"
    else
        BINARY=$(docker run --rm --entrypoint sha256sum "$IMAGE" /bin/lnd)
    fi

    upgrade
    case "$SCENARIO" in
        invalid-json)
            wait_for failed
            [[ $(count) == 1 ]]
            offline "sha256sum $WALLET" > "$WORK/after"
            diff -u "$WORK/before" "$WORK/after"
            [[ $(curl -sf "$URL/v1/state" | jq -r .state) == LOCKED ]] ;;
        unknown|split-store)
            wait_for failed
            [[ $(count) == 1 ]]
            if [[ "$SCENARIO" == unknown ]]; then
                docker logs "$LND" 2>&1 | grep -q 'invalid passphrase for master public key'
            else
                docker logs "$LND" 2>&1 | grep -q 'macaroon store error'
                [[ $(replacement) == saved-before-request ]]
            fi
            [[ $(curl -sf "$URL/v1/state" | jq -r .state) == LOCKED ]]
            [[ $(docker exec "$LND" sha256sum /bin/lnd) == "$BINARY" ]] ;;
        *)
            wait_for ready
            [[ $(count) == 1 ]]
            [[ $(docker exec "$LND" sha256sum /bin/lnd) == "$BINARY" ]]
            # The implementation removes its temporary replacement after success.
            docker exec "$LND" test ! -e "$WALLET.newpassword"
            FINAL=$(saved | jq -r '.wallet_password | @base64')
            [[ "$ROTATION" != test ]] || docker exec "$LND" test -f /data/.macaroon-rotated-test
            if [[ "$RESET_EXPECTED" == true ]]; then
                [[ "$FINAL" == $(printf %s "$ACTUAL" | base64 | tr -d '\n') ]]
                ! docker logs "$LND" 2>&1 | grep -q 'Migrated wallet'
            elif [[ "$SCENARIO" == pending-* ]]; then
                saved | jq -e '.wallet_password == "saved-before-request"' >/dev/null
            elif [[ "$SCENARIO" != custom* ]]; then
                saved | jq -e '.wallet_password | length == 44' >/dev/null
            fi
            if [[ "$SCENARIO" != fresh ]]; then
                [[ $(auth getinfo | jq -r .identity_pubkey) == "$IDENTITY" ]]
                saved | jq -e '.unrelated.keep' >/dev/null
                [[ $(saved | jq -c .cipher_seed_mnemonic) == "$(jq -c .cipher_seed_mnemonic <<< "$SEED")" ]]
                if [[ "$SCENARIO" == custom* ]]; then
                    [[ "$FINAL" == $(printf %s "$ACTUAL" | base64 | tr -d '\n') ]]
                fi
            fi
            if [[ "$SCENARIO" != fresh ]]; then
                for TOKEN in "$OLD_MACAROON" "$CUSTOM_MACAROON"; do
                    if [[ "$RESET_EXPECTED" == false ]]; then
                        curl -sf -H "Grpc-Metadata-macaroon:$TOKEN" "$URL/v1/getinfo" >/dev/null
                    else
                        curl -s --max-time 5 -H "Grpc-Metadata-macaroon:$TOKEN" "$URL/v1/getinfo" |
                            jq -e '.code != null and (.message | contains("signature mismatch") or
                                endswith("root key with id 7 doesn\u0027t exist"))' >/dev/null
                    fi
                done
            fi
            if [[ "$SCENARIO" == password-only || "$SCENARIO" == rotation ]]; then
                [[ $(channels) == "$CHANNELS" ]]
                [[ $(auth channels/backup | jq -Sc .multi_chan_backup.chan_points) == "$BACKUP_POINTS" ]]
            fi
            for FILE in admin readonly invoice; do docker exec "$LND" test -s "/data/$FILE.macaroon"; done
            BEFORE_MACAROON=$(docker exec "$LND" xxd -p -c 10000 /data/admin.macaroon)
            docker stop "$LND" >/dev/null
            docker rm "$LND" >/dev/null
            upgrade
            wait_for ready
            [[ $(count) == 2 ]]
            # A completed reset may migrate the password on this later start.
            # It must preserve the tokens generated by the reset startup.
            SECOND=$(saved | jq -r '.wallet_password | @base64')
            if [[ "$RESET_EXPECTED" == true && ( "$ACTUAL" == hellorockstar || "$ACTUAL" == $'hellorockstar\n' ) ]]; then
                [[ "$SECOND" != "$FINAL" ]]
                saved | jq -e '.wallet_password | length == 44' >/dev/null
            else
                [[ "$SECOND" == "$FINAL" ]]
            fi
            curl -sf -H "Grpc-Metadata-macaroon:$BEFORE_MACAROON" "$URL/v1/getinfo" >/dev/null ;;
    esac
    [[ $(docker inspect "$LND" | jq -r '.[0].HostConfig.RestartPolicy.Name') == no ]]
    [[ $(docker inspect "$LND" | jq -r '.[0].RestartCount') == 0 ]]
    docker rm -fv "$LND" >/dev/null
    if [[ "$SCENARIO" == password-only || "$SCENARIO" == rotation ]]; then docker rm -fv "$PEER" >/dev/null; fi
    docker volume rm "$VOLUME" >/dev/null
    echo "PASS $SCENARIO"
done
