FROM golang:1.17.1-alpine as builder

# Force Go to use the cgo based DNS resolver. This is required to ensure DNS
# queries required to connect to linked containers succeed.
ENV GODEBUG netdns=cgo

# Install dependencies and build the binaries.
RUN apk add --no-cache --update alpine-sdk \
    git \
    make \
    gcc

WORKDIR /go/src/github.com/lightningnetwork/lnd
COPY . .

RUN make \
&&  make install tags="signrpc walletrpc chainrpc invoicesrpc routerrpc"


# Build loop binary
RUN git clone --depth 1 --branch v0.15.0-beta https://github.com/lightninglabs/loop.git /go/src/github.com/lightninglabs/loop
WORKDIR /go/src/github.com/lightninglabs/loop/cmd


RUN go install ./...
# eof


# Start a new, final image.
FROM alpine:3.14.2 as final

# Force Go to use the cgo based DNS resolver. This is required to ensure DNS
# queries required to connect to linked containers succeed.
ENV GODEBUG netdns=cgo

# Add bash and ca-certs, for quality of life and SSL-related reasons.
RUN apk --no-cache add \
    bash \
    tini \
    ca-certificates

ENV LND_DATA /data
ENV LND_BITCOIND /deps/.bitcoin
ENV LND_LITECOIND /deps/.litecoin
ENV LND_BTCD /deps/.btcd
ENV LND_PORT 9735

RUN mkdir "$LND_DATA" && \
    mkdir "/deps" && \
    mkdir "$LND_BITCOIND" && \
    mkdir "$LND_LITECOIND" && \
    mkdir "$LND_BTCD" && \
    ln -sfn "$LND_DATA" /root/.lnd && \
    ln -sfn "$LND_BITCOIND" /root/.bitcoin && \
    ln -sfn "$LND_LITECOIND" /root/.litecoin && \
    ln -sfn "$LND_BTCD" /root/.btcd

# Define a root volume for data persistence.
VOLUME /data

# Copy the binaries from the builder image.
# lnd
COPY --from=builder /go/bin/lncli /bin/
COPY --from=builder /go/bin/lnd /bin/
COPY --from=builder /go/src/github.com/lightningnetwork/lnd/scripts/verify-install.sh /
COPY --from=builder /go/src/github.com/lightningnetwork/lnd/scripts/keys/* /keys/
# loop
COPY --from=builder /go/bin/loopd /bin/
COPY --from=builder /go/bin/loop /bin/


COPY docker-entrypoint.sh /docker-entrypoint.sh

# Copy script for automatic init and unlock of lnd, need jq for parsing JSON and curl for LND Rest
RUN apk --no-cache add jq curl
COPY docker-initunlocklnd.sh /docker-initunlocklnd.sh

# Specify the start command and entrypoint as the lnd daemon.
EXPOSE 9735
ENTRYPOINT  [ "/sbin/tini", "-g", "--", "/docker-entrypoint.sh" ]
CMD [ "lnd" ]
