#!/bin/bash
# Real LND regtest: saved password x existing marker, requesting rotation V2.
# Password: legacy (no walletunlock.json), hellorockstar, or custom.
# Marker: none, V1, or V2. Only V2 must preserve the old macaroon roots.
# Run all: bash docker-macaroon-password-rotation-tests.sh (Docker, curl, jq).
# Run one: bash docker-macaroon-password-rotation-tests.sh matrix-default-V1
# Legacy rotation failures are real failures, not skipped or expected successes.
set -Eeuo pipefail
SCENARIOS=()
for PASSWORD in legacy default custom; do
    for MARKER in none V1 V2; do
        SCENARIOS+=("matrix-$PASSWORD-$MARKER")
    done
done
SCENARIOS+=(fresh-rotation
    empty null omitted rotation-empty rotation-null rotation-omitted
    password-only custom-spaces pending-before pending-after
    rotation rotation-custom-spaces rotation-pending rotation-pending-after
    rotation-missing-readonly rotation-missing-store missing-readonly
    split-store unknown invalid-json newline stored-newline
    rotation-newline rotation-stored-newline fresh custom-dir)
if [[ "${1:-}" == --list ]]; then
    printf '%s\n' "${SCENARIOS[@]}"
    exit 0
fi
if [[ $# == 0 ]]; then
    PASSED=0 FAILED=0
    for SCENARIO in ${TEST_SCENARIOS:-${SCENARIOS[*]}}; do
        # A separate shell preserves errexit and cleanup, then lets the suite continue.
        if bash "$0" "$SCENARIO"; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
            echo "FAIL $SCENARIO" >&2
        fi
    done
    echo "Results: $PASSED passed, $FAILED failed"
    [[ "$FAILED" == 0 ]]
    exit
fi
if [[ $# != 1 || " ${SCENARIOS[*]} " != *" $1 "* ]]; then
    echo "Unknown scenario: $*. Use --list for available cases." >&2
    exit 2
fi
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
    [[ "$SCENARIO" == fresh* || "$PASSWORD_KIND" == legacy ]] ||
        docker logs "$LND" 2>&1 | grep -Eq 'Wallet unlocked|Wallet password changed|Macaroons rotated'
}
failed() { docker logs "$LND" 2>&1 | grep -Eq 'Wallet unlocking failed|Password change or macaroon rotation failed|parse error'; }
token_valid() { curl -sf --max-time 5 -H "Grpc-Metadata-macaroon:$1" "$URL/v1/getinfo" >/dev/null; }
token_revoked() {
    curl -s --max-time 5 -H "Grpc-Metadata-macaroon:$1" "$URL/v1/getinfo" |
        jq -e '.code != null and (.message | contains("signature mismatch"))' >/dev/null
}
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

SCENARIO=$1
echo "Testing $SCENARIO"
ROTATION=
ROTATE_EXPECTED=false
PASSWORD_KIND=default
OLD_MARKER=none
export ACTUAL=hellorockstar STORED=hellorockstar SCENARIO
case "$SCENARIO" in
    matrix-*)
        IFS=- read -r _ PASSWORD_KIND OLD_MARKER <<< "$SCENARIO"
        if [[ "$PASSWORD_KIND" == custom ]]; then
            ACTUAL=existing-custom-password; STORED=$ACTUAL
        fi ;;
    newline|rotation-newline) ACTUAL=$'hellorockstar\n' ;;
    stored-newline|rotation-stored-newline) ACTUAL=$'hellorockstar\n'; STORED=$ACTUAL ;;
    custom-dir) ACTUAL=existing-custom-password; STORED=$ACTUAL ;;
    custom-spaces|rotation-custom-spaces) ACTUAL='custom password with * spaces'; STORED=$ACTUAL ;;
    unknown) ACTUAL=unsaved-wallet-password ;;
esac
case "$SCENARIO" in
    rotation*) ROTATION=V2; ROTATE_EXPECTED=true ;;
    matrix-*) ROTATION=V2; [[ "$OLD_MARKER" == V2 ]] || ROTATE_EXPECTED=true ;;
    fresh-rotation) ROTATION=V2 ;;
esac
docker volume create "$VOLUME" >/dev/null
printf '%s\n' "$CONFIG" | offline 'cat > /data/lnd.conf'
if [[ "$SCENARIO" != fresh* ]]; then
    # Fixture setup is separate from the counted upgrade.
    FIXTURE_ARGS=()
    [[ "$PASSWORD_KIND" != legacy ]] || FIXTURE_ARGS+=(--noseedbackup)
    docker run -d --name "$LND" --network "$NAME" --network-alias lnd \
        -v "$VOLUME:/data" --entrypoint /bin/lnd "$IMAGE" --lnddir=/data "${FIXTURE_ARGS[@]}" >/dev/null
    URL=http://$(address):8080
    if [[ "$PASSWORD_KIND" != legacy ]]; then
        wait_for curl -sf --max-time 5 "$URL/v1/genseed"
        SEED=$(curl -sf "$URL/v1/genseed")
        export SEED
        jq -nc '{wallet_password:(env.ACTUAL | @base64),cipher_seed_mnemonic:(env.SEED | fromjson | .cipher_seed_mnemonic)}' |
            curl -sf --data-binary @- "$URL/v1/initwallet" >/dev/null
    fi
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
    if [[ "$PASSWORD_KIND" != legacy ]]; then
        jq -nc '{wallet_password:env.STORED,cipher_seed_mnemonic:(env.SEED | fromjson | .cipher_seed_mnemonic),unrelated:{keep:true}} |
            if (env.SCENARIO | endswith("empty")) then .wallet_password=""
            elif (env.SCENARIO | endswith("null")) then .wallet_password=null
            elif (env.SCENARIO | endswith("omitted")) then del(.wallet_password) else . end' |
            docker exec -i "$LND" sh -c "cat > $WALLET"
    else
        docker exec "$LND" test ! -e "$WALLET"
    fi
    case "$SCENARIO" in
        pending-*|split-store|rotation-pending*)
            printf '%s\n' saved-before-request | docker exec -i "$LND" sh -c "cat > $WALLET.newpassword" ;;
    esac
    docker stop "$LND" >/dev/null
    if [[ "$SCENARIO" == split-store ]]; then
        offline 'cp /data/data/chain/bitcoin/regtest/macaroons.db /data/old-store'
    fi
    if [[ "$SCENARIO" == pending-after || "$SCENARIO" == rotation-pending-after || "$SCENARIO" == split-store ]]; then
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
        rotation-missing-store) offline 'rm /data/data/chain/bitcoin/regtest/macaroons.db' ;;
        *missing-readonly) offline 'rm /data/readonly.macaroon' ;;
        split-store) offline 'mv /data/old-store /data/data/chain/bitcoin/regtest/macaroons.db' ;;
        invalid-json) offline 'printf "{" > /data/data/chain/bitcoin/regtest/walletunlock.json' ;;
    esac
    if [[ "$PASSWORD_KIND" != legacy ]]; then
        offline "sha256sum $WALLET" > "$WORK/before"
    fi
    if [[ "$OLD_MARKER" != none ]]; then
        offline "touch /data/.macaroon-rotated-$OLD_MARKER"
    fi
else
    BINARY=$(docker run --rm --entrypoint sha256sum "$IMAGE" /bin/lnd)
fi

upgrade
case "$SCENARIO" in
    invalid-json|unknown|split-store|rotation-missing-readonly|rotation-missing-store)
        wait_for failed
        [[ $(count) == 1 ]]
        offline "sha256sum $WALLET" > "$WORK/after"
        diff -u "$WORK/before" "$WORK/after"
        docker exec "$LND" test ! -e /data/.macaroon-rotated-V2
        if [[ "$SCENARIO" == unknown ]]; then
            docker logs "$LND" 2>&1 | grep -q 'invalid passphrase for master public key'
        fi
        if [[ "$SCENARIO" == unknown || "$SCENARIO" == rotation-missing-* ]]; then
            replacement | grep -Eq '^[A-Za-z0-9+/]{43}=$'
        elif [[ "$SCENARIO" == split-store ]]; then
            [[ $(replacement) == saved-before-request ]]
        fi
        if [[ "$SCENARIO" == rotation-missing-readonly ]]; then
            docker logs "$LND" 2>&1 | grep -q 'could not remove macaroon file'
        fi
        [[ $(curl -sf "$URL/v1/state" | jq -r .state) == LOCKED ]]
        [[ $(docker exec "$LND" sha256sum /bin/lnd) == "$BINARY" ]] ;;
    *)
        wait_for ready
        [[ $(count) == 1 ]]
        [[ $(docker exec "$LND" sha256sum /bin/lnd) == "$BINARY" ]]
        # The implementation removes its temporary replacement after success.
        docker exec "$LND" test ! -e "$WALLET.newpassword"
        if [[ "$PASSWORD_KIND" != legacy ]]; then
            FINAL=$(saved | jq -r '.wallet_password | @base64')
            if [[ "$SCENARIO" == *pending* ]]; then
                saved | jq -e '.wallet_password == "saved-before-request"' >/dev/null
            elif [[ "$SCENARIO" == *custom* ]]; then
                [[ "$FINAL" == $(printf %s "$ACTUAL" | base64 | tr -d '\n') ]]
            else
                saved | jq -e '.wallet_password | length == 44' >/dev/null
            fi
        fi
        if [[ "$SCENARIO" != fresh* ]]; then
            [[ $(auth getinfo | jq -r .identity_pubkey) == "$IDENTITY" ]]
            if [[ "$PASSWORD_KIND" != legacy ]]; then
                saved | jq -e '.unrelated.keep' >/dev/null
                [[ $(saved | jq -c .cipher_seed_mnemonic) == "$(jq -c .cipher_seed_mnemonic <<< "$SEED")" ]]
            fi
        fi
        if [[ "$SCENARIO" != fresh* ]]; then
            for TOKEN in "$OLD_MACAROON" "$CUSTOM_MACAROON"; do
                if [[ "$ROTATE_EXPECTED" == false ]]; then
                    token_valid "$TOKEN"
                else
                    token_revoked "$TOKEN" || { echo "Old macaroon was not revoked by rotation $ROTATION" >&2; exit 1; }
                fi
            done
        fi
        if [[ "$ROTATION" ]]; then
            docker exec "$LND" test -f "/data/.macaroon-rotated-$ROTATION"
        fi
        if [[ "$SCENARIO" == custom-dir ]]; then
            # Real RPC access needs the custom TLS path; explicit --lnddir still wins.
            for CLI_DATA in /custom /unused; do
                CLI_ARGS=()
                [[ "$CLI_DATA" == /custom ]] || CLI_ARGS+=(--lnddir=/custom)
                CLI_INFO=$(docker run --rm --network "container:$LND" \
                    -v "$VOLUME:/custom:ro" -v "$ROOT/docker-entrypoint.sh:/docker-entrypoint.sh:ro" \
                    -e "LND_DATA=$CLI_DATA" -e LND_MACAROON_ROTATION_ID=cli-only \
                    --entrypoint /docker-entrypoint.sh "$IMAGE" lncli "${CLI_ARGS[@]}" \
                    --network=regtest --macaroonpath=/custom/admin.macaroon getinfo)
                [[ $(jq -r .identity_pubkey <<< "$CLI_INFO") == "$IDENTITY" ]]
            done
            docker exec "$LND" test ! -e /data/.macaroon-rotated-cli-only
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
        # Both operations finish on the first start; the next start preserves credentials.
        if [[ "$PASSWORD_KIND" != legacy ]]; then
            SECOND=$(saved | jq -r '.wallet_password | @base64')
            [[ "$SECOND" == "$FINAL" ]]
        fi
        token_valid "$BEFORE_MACAROON" ;;
esac
[[ $(docker inspect "$LND" | jq -r '.[0].HostConfig.RestartPolicy.Name') == no ]]
[[ $(docker inspect "$LND" | jq -r '.[0].RestartCount') == 0 ]]
docker rm -fv "$LND" >/dev/null
if [[ "$SCENARIO" == password-only || "$SCENARIO" == rotation ]]; then docker rm -fv "$PEER" >/dev/null; fi
docker volume rm "$VOLUME" >/dev/null
echo "PASS $SCENARIO"
