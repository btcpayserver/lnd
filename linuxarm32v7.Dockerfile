FROM golang:1.11.5-stretch as builder

# Force Go to use the cgo based DNS resolver. This is required to ensure DNS
# queries required to connect to linked containers succeed.
ENV GODEBUG netdns=cgo

# Install dependencies and build the binaries.
RUN apt-get -y update && apt-get -y install git make wget \
    && apt-get install -qq --no-install-recommends qemu qemu-user-static qemu-user binfmt-support

RUN wget -qO /opt/tini "https://github.com/krallin/tini/releases/download/v0.18.0/tini-armhf" \
    && echo "01b54b934d5f5deb32aa4eb4b0f71d0e76324f4f0237cc262d59376bf2bdc269 /opt/tini" | sha256sum -c - \
    && chmod +x /opt/tini

ENV GOARM=7	GOARCH=arm
WORKDIR /go/src/github.com/lightningnetwork/lnd
COPY . .

RUN make \
&&  make install

# Force the builder machine to take make an arm runtime image. This is fine as long as the builder does not run any program
FROM arm32v7/debian:stretch-slim as final

COPY --from=builder /opt/tini /usr/bin/tini
COPY --from=builder /usr/bin/qemu-arm-static /usr/bin/qemu-arm-static

# Force Go to use the cgo based DNS resolver. This is required to ensure DNS
# queries required to connect to linked containers succeed.
ENV GODEBUG netdns=cgo
# Add bash and ca-certs, for quality of life and SSL-related reasons.
RUN apt-get -y update && apt-get install -y bash ca-certificates && rm -rf /var/lib/apt/lists/*

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
COPY --from=builder /go/bin/linux_arm/lncli /bin/
COPY --from=builder /go/bin/linux_arm/lnd /bin/

COPY docker-entrypoint.sh /docker-entrypoint.sh
# Specify the start command and entrypoint as the lnd daemon.
EXPOSE 9735
ENTRYPOINT  [ "/usr/bin/tini", "-g", "--", "/docker-entrypoint.sh" ]
CMD [ "lnd" ]

