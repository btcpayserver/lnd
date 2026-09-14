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

for SCENARIO in legacy newline interrupted; do
    LEGACY=hellorockstar
    if [[ "$SCENARIO" == newline ]]; then LEGACY=$'hellorockstar\n'; fi
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
    BINARY=$(docker exec "$LND" sha256sum /bin/lnd)
    jq -cn --argjson seed "$SEED" --arg scenario "$SCENARIO" \
        '{wallet_password:"hellorockstar",cipher_seed_mnemonic:$seed} +
        (if $scenario == "interrupted" then {wallet_password_pending:"saved-before-the-request"} else {} end)' \
        | docker exec -i "$LND" sh -c "cat > $WALLET"
    docker stop "$LND" >/dev/null
    docker rm "$LND" >/dev/null

    # Exercise password migration AND root-key rotation in the same startup.
    docker run -d --name "$LND" --network "$NAME" --network-alias lnd --restart unless-stopped \
        -v "$VOLUME:/data" -v "$ROOT/docker-entrypoint.sh:/docker-entrypoint.sh:ro" \
        -v "$ROOT/docker-initunlocklnd.sh:/docker-initunlocklnd.sh:ro" \
        -e LND_CHAIN=btc -e LND_ENVIRONMENT=regtest -e "LND_EXTRA_ARGS=$CONFIG" \
        -e LND_REST_LISTEN_HOST=http://lnd:8080 -e LND_MACAROON_ROTATION_ID=test "$IMAGE" >/dev/null
    URL=http://$(address):8080
    wait_for ready
    SAVED=$(saved)
    [[ $(info | jq -r .identity_pubkey) == "$IDENTITY" ]]
    [[ $(saved | jq '.cipher_seed_mnemonic') == "$SEED" ]]
    [[ $(docker exec "$LND" sha256sum /bin/lnd) == "$BINARY" ]]
    [[ $(curl -s -o /dev/null -w '%{http_code}' -H "Grpc-Metadata-macaroon:$OLD_MACAROON" "$URL/v1/getinfo") != 200 ]]
    docker logs "$LND" 2>&1 | grep 'default root key not found' >/dev/null
    docker restart "$LND" >/dev/null
    wait_for info
    [[ $(saved) == "$SAVED" ]]
    docker rm -fv "$LND" >/dev/null
    docker volume rm "$VOLUME" >/dev/null
done
echo 'PASS: rotation, both legacy passwords, interrupted migration and subsequent restart'
