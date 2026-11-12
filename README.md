# BTCPayServer LND

This repository is used to build LND Docker container images that are distributed with BTCPayServer by default.

Docker images are published to https://hub.docker.com/r/btcpayserver/lnd/

Versions:
 - [0.21.8-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.21.8-beta/images/sha256-4f9a086187505832c026508c97300697b377dcef9ebe911bd4221a5a8ea103b6?context=repo)
    - Includes 0.33.3-beta Loop
 - [0.21.7-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.21.7-beta/images/sha256-178df024d554d1646438909ee17378250581be4111aca89edb7a5d230ab77d54?context=repo)
    - Includes 0.33.3-beta Loop
 - [0.21.6-beta-1](https://hub.docker.com/layers/btcpayserver/lnd/v0.21.6-beta-1/images/sha256-159795c4cbd9c698e9e8a4c483bc374c90fc7d867f37c9016f9e15d4a30cdbd1?context=repo)
    - Includes 0.33.3-beta Loop
    - Reaps the startup helper through tini to prevent zombie processes (btcpayserver/lnd#21)
 - [0.21.6-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.21.6-beta/images/sha256-42714892377c56d8a9e309e77cd6fda639704d1ca84d0e03f5f2d14d3863edf8?context=repo)
    - Includes 0.33.3-beta Loop
 - [0.21.5-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.21.5-beta/images/sha256-789055db6de10b227f37152cd2cf0488e35e61066b500c988f9b8e26adfc41c6?context=repo)
    - Includes 0.33.3-beta Loop
 - [0.21.5-beta.rc1](https://hub.docker.com/layers/btcpayserver/lnd/v0.21.5-beta.rc1/images/sha256-b2d8472e021d69bb05f00249ece1e4d38a9caaf8bd497e390d46cfe7fc622c4e?context=repo)
    - Includes 0.33.3-beta Loop
 - [0.21.3-beta-2](https://hub.docker.com/layers/btcpayserver/lnd/v0.21.3-beta-2/images/sha256-ea1241a94fea814b98c4142639b02357c36c2ed238ee743c1125f3f7646d4375?context=repo)
    - Includes 0.33.3-beta Loop
 - [0.21.3-beta-1](https://hub.docker.com/layers/btcpayserver/lnd/v0.21.3-beta-1/images/sha256-3ed36ae52c85385f40785aa94bfc6c55343a99aea7b297c66638445a3c4a722f?context=repo)
    - Adds RPCUSER_FILE support for file-based Bitcoin RPC passwords (btcpayserver/lnd#14)
 - [0.21.3-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.21.3-beta/images/sha256-348fcb4b52b03008b42f0b53ea84211456cf712cd1a9a7963634c904a7e2879a?context=repo)
    - Includes 0.33.3-beta Loop
    - Wallets are migrated off the shared default password to a per-instance random password
 - [0.21.2-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.21.2-beta/images/sha256-809977c805455196dc6f9334ac4ee666002cc244eb5b58224a0d6c2d167f0afc?context=repo)
    - Includes 0.33.3-beta Loop
 - [0.21.1-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.21.1-beta/images/sha256-cac93abe645c6bf4bca2c9c7118bd089976c1d6c08045f922775a31864165a6c?context=repo)
    - Includes 0.33.3-beta Loop
 - [0.21.0-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.21.0-beta/images/sha256-70de68dc14e34826f25496f6ec294b096b294698670e2ecc8555e0790e7383e5?context=repo)
    - Includes 0.33.3-beta Loop
 - [0.19.3-beta-1](https://hub.docker.com/layers/btcpayserver/lnd/v0.19.3-beta-1/images/sha256-d5f1cb925128d2fd9cd5454b4e2e2a8dff28d8def6018827349ae07d8fe386c6?context=repo)
    - Includes 0.31.2-beta Loop
 - [0.19.1-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.19.1-beta/images/sha256-d56f6e57794ebc4aa0119e5ec91b1aa076ceaa324cad0d816cbf282fb0a3a2d0?context=repo)
    - Includes 0.29.0-beta Loop
 - [0.18.3-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.18.3-beta/images/sha256-513ddd55a5af44a14e27110ee14cb28f1c7a69205bcaa2fba4e66275c1f725e5?context=repo)
    - Includes 0.28.7-beta Loop
    - [Fix for lnd unlock password \n problem](https://github.com/btcpayserver/lnd/pull/7)
 - [0.18.1-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.18.1-beta/images/sha256-5fbfa76a218ab59bf9206485f4c0c071a525f9f0906255a5672054741d043b79?context=repo)
    - Includes 0.28.5-beta Loop
 - [0.18.0-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.18.0-beta/images/sha256-e6043dddf0bdbd5c740e882447c441b37f87f2c736ebb08747a4aff5e100d9bf?context=repo)
    - Includes 0.28.2-beta Loop
 - [0.17.4-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.17.4-beta/images/sha256-b62ecff5ca71d37f9b4846f35b4d86ddc4faa3fc1dd0618ae9221d99f47708bd?context=explore)
    - Includes 0.26.6-beta Loop
 - [0.17.3-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.17.3-beta/images/sha256-141611de6c062835e9513dd1ec4155c779d7a7b55258eb1fe06e228b0835fa56?context=repo)
    - Includes 0.26.6-beta Loop
 - [0.17.2-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.17.2-beta/images/sha256-936767369b703a67daf6db6a008a3b53c15f407d29a7ad2327a0de28f5951b30?context=explore)
    - Includes 0.26.5-beta Loop
 - [0.17.1-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.17.1-beta/images/sha256-b5c106136bd33a422463c736a1db8bd3541f95ac6f277dae86ab2a01b0c3445a?context=explore)
    - Includes 0.26.5-beta Loop
 - [0.17.0-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.17.0-beta/images/sha256-58b98f983cd786bcb4d48ea8586144cafd44d58dc3018e26bfbfcf875f495368?context=explore)
    - Includes 0.26.4-beta Loop
 - [0.17.0-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.17.0-beta/images/sha256-58b98f983cd786bcb4d48ea8586144cafd44d58dc3018e26bfbfcf875f495368?context=explore)
    - Includes 0.26.4-beta Loop
 - [0.16.4-beta-1](https://hub.docker.com/layers/btcpayserver/lnd/v0.16.4-beta-1/images/sha256-9dd204b62d6c892485b3dd8a76e8f48545ceda5702c9d47329ba4bcbc535a8b4?context=explore)
 - [0.16.3-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.16.3-beta/images/sha256-9ff34769378cfca18664c7d1da3747e7ad7fb7f38a9a7b82a3d4f85e5bfef7bf?context=explore)
 - [0.16.2-beta-1](https://hub.docker.com/layers/btcpayserver/lnd/v0.16.2-beta-1/images/sha256-bfff9de84a0a4af9d643ff555125358861b70374976b970cc00d1e7fc44ed520?context=explore)
 - [0.16.1-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.16.0-beta/images/sha256-f0eb70c20691aaa2ffc34fd5bd6c284299c84e96152cda5e46882a3aa4a3c6a2?context=explore)
 - [0.16.0-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.16.0-beta/images/sha256-f0eb70c20691aaa2ffc34fd5bd6c284299c84e96152cda5e46882a3aa4a3c6a2?context=explore)
 - [0.15.4-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.15.4-beta-1/images/sha256-cadbbff93cf36146e24fa4f32170b4b9d278a2e1acfdc50470790a94506ee9c3?context=explore)
 - [Other versions are tagged](https://github.com/btcpayserver/lnd/tags), but obsoleted and not supported.
    - All LND versions prior to 0.15.4 contain a consensus bug that prevents them from properly parsing transactions with more than 500,000 witness items per input (https://github.com/btcsuite/btcd/issues/1906)
    - All LND versions prior to 0.15.2 contain a bug that prevents them from properly parsing Taproot transactions with script size over 11000 bytes (https://github.com/lightningnetwork/lnd/issues/7002)
    - LND version 0.14.0-beta shipped with check that made it incompatable with c-lightning and eclair (https://github.com/lightningnetwork/lnd/issues/5890)
    - All LND versions prior to 0.13.3 contain specification-level vulnerability (https://lists.linuxfoundation.org/pipermail/lightning-dev/2021-October/003257.html)
    - All LND versions prior to 0.7 contain critical vulnerability (https://lists.linuxfoundation.org/pipermail/lightning-dev/2019-September/002174.html)

Each version is marked with appropriate `basedon-vX.X.X-beta` tags. We are using `basedon` prefix in order not to conflict with LND tags from source repository.

## Updating LND version in BTCPay Server

Follow the [LND maintenance procedure](https://github.com/btcpayserver/image-maintenance/blob/master/docs/lnd.md)
in [image-maintenance](https://github.com/btcpayserver/image-maintenance) for
upstream bumps, patch preservation, image publication and downstream validation.
Start maintenance agents from that repository so they load the shared instructions.

## Source repository

https://github.com/lightningnetwork/lnd

## Links
* [BTCPayServer main repo](https://github.com/btcpayserver/btcpayserver)
* [BTCPayServer-Docker repo](https://github.com/btcpayserver/btcpayserver-docker)
* [BTCPayServer.Lightning](https://github.com/btcpayserver/BTCPayServer.Lightning)
