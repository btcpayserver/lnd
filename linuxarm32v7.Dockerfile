FROM golang:1.11.5-stretch as builder

# Force Go to use the cgo based DNS resolver. This is required to ensure DNS
# queries required to connect to linked containers succeed.
ENV GODEBUG netdns=cgo

# Install dependencies and build the binaries.
RUN apt-get -y update && apt-get -y install git make
ENV GOARM=7	GOARCH=arm
WORKDIR /go/src/github.com/lightningnetwork/lnd
COPY . .

RUN make \
&&  make install

# This is a manifest image, will pull the image with the same arch as the builder machine
FROM microsoft/dotnet:2.1.500-sdk AS dotnetbuilder

RUN apt-get -y update && apt-get -y install git

WORKDIR /source

RUN git clone https://github.com/dgarage/NBXplorer && cd NBXplorer && git checkout de6245f0c90a07a676a2df2531bc8e553150a558

# Cache some dependencies
RUN cd NBXplorer/NBXplorer.NodeWaiter && dotnet restore && cd ..
RUN cd NBXplorer/NBXplorer.NodeWaiter && \
    dotnet publish --output /app/ --configuration Release

# Force the builder machine to take make an arm runtime image. This is fine as long as the builder does not run any program
FROM microsoft/dotnet:2.1.6-runtime-stretch-slim-arm32v7 as final

# Force Go to use the cgo based DNS resolver. This is required to ensure DNS
# queries required to connect to linked containers succeed.
ENV GODEBUG netdns=cgo
#EnableQEMU COPY qemu-arm-static /usr/bin
# Add bash and ca-certs, for quality of life and SSL-related reasons.
RUN apt-get -y update && apt-get install -y bash ca-certificates  && rm -rf /var/lib/apt/lists/*

ENV LND_DATA /data
ENV LND_BITCOIND /deps/.bitcoin
ENV LND_LITECOIND /deps/.litecoin
ENV LND_BTCD /deps/.btcd

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
COPY --from=dotnetbuilder /app /opt/NBXplorer.NodeWaiter

COPY docker-entrypoint.sh /docker-entrypoint.sh
# Specify the start command and entrypoint as the lnd daemon.
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["lnd"]
