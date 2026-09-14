#!/bin/bash
# Run with bash tests/docker-password-migration.sh. Requires Docker, curl, jq.
# Uses only disposable regtest data and the unchanged released LND binary.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=btcpayserver/lnd:v0.21.3-beta-1
NAME=btcpay-password-test-$$
BTC=$NAME-bitcoin
LND=$NAME-lnd
VOLUME=$NAME-data
WALLET=/data/data/chain/bitcoin/regtest/walletunlock.json
cleanup() {
    docker rm -fv "$LND" "$BTC" >/dev/null 2>&1 || true
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
    docker network rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
wait_for() {
    for ((i=0; i<120; i++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    docker logs --tail 50 "$LND" >&2 || true
    echo "Timed out: $*" >&2
    return 1
}
bitcoin() { docker exec "$BTC" bitcoin-cli -regtest -rpcuser=test -rpcpassword=test "$@"; }
address() { docker inspect "$LND" | jq -r --arg n "$NAME" '.[0].NetworkSettings.Networks[$n].IPAddress'; }
info() {
    curl -sf --max-time 5 -H "Grpc-Metadata-macaroon:$(docker exec "$LND" xxd -p -c 10000 /data/admin.macaroon)" "$URL/v1/getinfo"
}
saved() { docker exec "$LND" cat "$WALLET"; }
ready() { saved | jq -e '.wallet_password != "hellorockstar" and (has("wallet_password_pending") | not)' && info; }

docker network create --internal "$NAME" >/dev/null
docker run -d --name "$BTC" --network "$NAME" --network-alias bitcoin \
    --entrypoint bitcoind btcpayserver/bitcoin:31.1 -regtest -server \
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

for SCENARIO in legacy newline stored-newline password-only rotation-only custom-newline interrupted-before interrupted-after missing-store missing-readonly interrupted-missing-store split-store corrupt-json; do
    echo "Testing $SCENARIO"
    LEGACY=hellorockstar
    STORED=hellorockstar
    ROTATION=test
    case "$SCENARIO" in
        newline) LEGACY=$'hellorockstar\n' ;;
        stored-newline) LEGACY=$'hellorockstar\n'; STORED=$LEGACY ;;
        password-only|split-store) ROTATION= ;;
        rotation-only) LEGACY=existing-custom-password; STORED=$LEGACY ;;
        custom-newline) LEGACY=$'existing-custom-password\n'; STORED=existing-custom-password ;;
    esac
    docker volume create "$VOLUME" >/dev/null
    docker run --rm -i -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c 'cat > /data/lnd.conf' <<< "$CONFIG"
    docker run -d --name "$LND" --network "$NAME" --network-alias lnd \
        -v "$VOLUME:/data" --entrypoint lnd "$IMAGE" --lnddir=/data >/dev/null
    URL=http://$(address):8080
    wait_for curl -sf --max-time 5 "$URL/v1/genseed"
    SEED=$(curl -sf "$URL/v1/genseed" | jq '.cipher_seed_mnemonic')
    jq -cn --arg pw "$(printf %s "$LEGACY" | base64 | tr -d '\n')" --argjson seed "$SEED" \
        '{wallet_password:$pw,cipher_seed_mnemonic:$seed}' | curl -sf -d @- "$URL/v1/initwallet" >/dev/null
    wait_for info
    IDENTITY=$(info | jq -r .identity_pubkey)
    OLD_MACAROON=$(docker exec "$LND" xxd -p -c 10000 /data/admin.macaroon)
    CUSTOM_MACAROON=$(curl -sf -H "Grpc-Metadata-macaroon:$OLD_MACAROON" \
        -d '{"permissions":[{"entity":"info","action":"read"}],"root_key_id":"7"}' "$URL/v1/macaroon" | jq -er .macaroon)
    curl -sf -H "Grpc-Metadata-macaroon:$CUSTOM_MACAROON" "$URL/v1/getinfo" >/dev/null
    BINARY=$(docker exec "$LND" sha256sum /bin/lnd)
    jq -cn --argjson seed "$SEED" --arg scenario "$SCENARIO" --arg pw "$STORED" \
        '{wallet_password:$pw,cipher_seed_mnemonic:$seed,unrelated:{keep:true}} +
        (if ($scenario | startswith("interrupted-")) or $scenario == "split-store" then {wallet_password_pending:"saved-before-the-request"} else {} end)' \
        | docker exec -i "$LND" sh -c "cat > $WALLET"
    if [[ "$SCENARIO" == split-store ]]; then
        docker stop "$LND" >/dev/null
        docker run --rm -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c \
            'cp /data/data/chain/bitcoin/regtest/macaroons.db /data/old-store'
        docker start "$LND" >/dev/null
    fi
    if [[ "$SCENARIO" == interrupted-after || "$SCENARIO" == interrupted-missing-store || "$SCENARIO" == split-store ]]; then
        # The RPC succeeded but the caller did not commit its saved JSON file.
        docker restart "$LND" >/dev/null
        wait_for curl -sf "$URL/v1/state"
        jq -cn --arg old "$(printf %s "$LEGACY" | base64 | tr -d '\n')" \
            --arg new "$(printf %s saved-before-the-request | base64 | tr -d '\n')" \
            '{current_password:$old,new_password:$new,new_macaroon_root_key:true}' \
            | curl -sf -d @- "$URL/v1/changepassword" >/dev/null
        wait_for info
    fi
    docker stop "$LND" >/dev/null
    docker rm "$LND" >/dev/null
    if [[ "$SCENARIO" == *missing-store ]]; then
        docker run --rm -v "$VOLUME:/data" --entrypoint sh "$IMAGE" \
            -c 'rm -f /data/data/chain/bitcoin/regtest/macaroons.db'
    elif [[ "$SCENARIO" == missing-readonly ]]; then
        docker run --rm -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c 'rm /data/readonly.macaroon'
    elif [[ "$SCENARIO" == split-store ]]; then
        # Reproduce wallet=NEW/store=OLD with real databases, all tokens present.
        docker run --rm -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c \
            'mv /data/old-store /data/data/chain/bitcoin/regtest/macaroons.db'
    elif [[ "$SCENARIO" == corrupt-json ]]; then
        docker run --rm -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c \
            'printf "{" > /data/data/chain/bitcoin/regtest/walletunlock.json
             sha256sum /data/*.macaroon /data/data/chain/bitcoin/regtest/macaroons.db > /data/auth.sha256'
    fi

    # No restart policy: healthy upgrades finish in one startup. Repair boots
    # unlock first and explicitly request a restart to finish the saved change.
    docker run -d --name "$LND" --network "$NAME" --network-alias lnd \
        -v "$VOLUME:/data" -v "$ROOT/docker-entrypoint.sh:/docker-entrypoint.sh:ro" \
        -v "$ROOT/docker-initunlocklnd.sh:/docker-initunlocklnd.sh:ro" \
        -e LND_CHAIN=btc -e LND_ENVIRONMENT=regtest -e "LND_EXTRA_ARGS=$CONFIG" \
        -e LND_REST_LISTEN_HOST=http://lnd:8080 -e "LND_MACAROON_ROTATION_ID=$ROTATION" "$IMAGE" >/dev/null
    URL=http://$(address):8080
    if [[ "$SCENARIO" == corrupt-json ]]; then
        invalid() { docker logs "$LND" 2>&1 | grep -q 'LND remains available for manual unlock'; }
        wait_for invalid
        [[ $(curl -sf "$URL/v1/state" | jq -r .state) == LOCKED ]]
        [[ $(saved) == '{' ]]
        docker exec "$LND" sha256sum -c /data/auth.sha256
        docker exec "$LND" test ! -f /data/.macaroon-rotated-test
        docker rm -fv "$LND" >/dev/null
        docker volume rm "$VOLUME" >/dev/null
        continue
    fi
    if [[ "$SCENARIO" == split-store ]]; then
        failed() { docker logs "$LND" 2>&1 | grep -q 'never delete a live database'; }
        wait_for failed
        saved | jq -e '.wallet_password == "hellorockstar" and
            .wallet_password_pending == "saved-before-the-request"' >/dev/null
        [[ $(curl -sf "$URL/v1/state" | jq -r .state) == LOCKED ]]
        # Operator follows the logged remedy only after stopping LND.
        docker stop "$LND" >/dev/null
        docker run --rm -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c \
            'rm /data/data/chain/bitcoin/regtest/macaroons.db /data/*.macaroon'
        docker start "$LND" >/dev/null
        URL=http://$(address):8080
    fi
    if [[ "$SCENARIO" == *missing-store || "$SCENARIO" == missing-readonly || "$SCENARIO" == split-store ]]; then
        repaired() { docker logs "$LND" 2>&1 | grep -q 'Restart the LND container once'; }
        wait_for repaired
        wait_for info
        EXPECTED=$LEGACY
        if [[ "$SCENARIO" == interrupted-missing-store || "$SCENARIO" == split-store ]]; then EXPECTED=saved-before-the-request; fi
        saved | jq -e --arg pw "$EXPECTED" '.wallet_password == $pw and
            (.wallet_password_pending | length >= 8) and .unrelated.keep' >/dev/null
        for TOKEN in "$OLD_MACAROON" "$CUSTOM_MACAROON"; do
            [[ $(curl -s -o /dev/null -w '%{http_code}' -H "Grpc-Metadata-macaroon:$TOKEN" "$URL/v1/getinfo") != 200 ]]
        done
        docker restart "$LND" >/dev/null
        URL=http://$(address):8080
    fi
    wait_for ready
    SAVED=$(saved)
    [[ $(info | jq -r .identity_pubkey) == "$IDENTITY" ]]
    [[ $(saved | jq '.cipher_seed_mnemonic') == "$SEED" ]]
    saved | jq -e '.unrelated.keep == true' >/dev/null
    [[ $(docker exec "$LND" sha256sum /bin/lnd) == "$BINARY" ]]
    for TOKEN in "$OLD_MACAROON" "$CUSTOM_MACAROON"; do
        CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Grpc-Metadata-macaroon:$TOKEN" "$URL/v1/getinfo")
        if [[ "$ROTATION" || "$SCENARIO" == split-store ]]; then [[ "$CODE" != 200 ]]; else [[ "$CODE" == 200 ]]; fi
    done
    if [[ "$STORED" == hellorockstar* ]]; then
        HISTORY=$(docker exec "$LND" cat "$WALLET.password-history")
        jq -e --arg old "$LEGACY" '[.[] | .old_password, .legacy_password] | index($old) != null' <<< "$HISTORY" >/dev/null
        jq -e --arg pw "$(saved | jq -r .wallet_password)" '.[-1].new_password == $pw' <<< "$HISTORY" >/dev/null
        [[ $(docker exec "$LND" stat -c %a "$WALLET") == 600 ]]
        [[ $(docker exec "$LND" stat -c %a "$WALLET.password-history") == 600 ]]
    else
        [[ $(saved | jq -r .wallet_password) == "$STORED" ]]
    fi
    if [[ "$SCENARIO" == interrupted-* || "$SCENARIO" == split-store ]]; then
        [[ $(saved | jq -r .wallet_password) == saved-before-the-request ]]
    fi
    if [[ "$ROTATION" ]]; then docker exec "$LND" test -f /data/.macaroon-rotated-test; fi
    for FILE in admin readonly invoice; do docker exec "$LND" test -s "/data/$FILE.macaroon"; done
    [[ $(docker inspect "$LND" | jq -r '.[0].HostConfig.RestartPolicy.Name') == no ]]
    [[ $(docker inspect "$LND" | jq -r '.[0].RestartCount') == 0 ]]
    if docker logs "$LND" 2>&1 | grep -q 'default root key not found'; then exit 1; fi
    docker restart "$LND" >/dev/null
    wait_for info
    [[ $(saved) == "$SAVED" ]]
    docker rm -fv "$LND" >/dev/null
    docker volume rm "$VOLUME" >/dev/null
done
echo 'PASS: password changes, full rotation, legacy passwords, saved retries and subsequent restart'
