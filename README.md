# BTCPayServer LND 

This repository is used to build LND Docker container images that are distributed with BTCPayServer by default.

Docker images are published to https://hub.docker.com/r/btcpayserver/lnd/

Versions:
 - [0.18.3-beta](https://hub.docker.com/layers/btcpayserver/lnd/v0.18.3-beta/images/sha256-e7449187b058440e4746f948bd095584d67bb82133c93737204e86c3aeff664a?context=repo)
    - Includes 0.28.7-beta Loop
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

1. **Update https://github.com/btcpayserver/lnd**

   a) Go to https://github.com/lightningnetwork/lnd/releases and find the commit on which we should add our resources.  
   b) Checkout a new branch for that commit, usually in the format of `lnd/v0.18.3-beta`.  
   c) Cherry-pick the `Adding BtcPayServer related files and resources` commit. [Example commit](https://github.com/btcpayserver/lnd/commit/ae4bb33c6a3db8b7cc01d18fdf46e600ead9bed4).  
   d) Tag it with the `basedon-v*` prefix name and push it. For v0.18.1, the tag name was `basedon-v0.18.3-beta`.  
   e) The build process will start (it [matches on tag format](.circleci/config.yml#L11)). Here is [an example CircleCI build](https://app.circleci.com/pipelines/github/btcpayserver/lnd/202/workflows/b90b5888-c0b8-4207-860e-a63ce21077af).  
   f) The resulting image will be published to Docker Hub. Example [Docker Hub image for v0.18.3](https://hub.docker.com/layers/btcpayserver/lnd/v0.18.3-beta/images/sha256-e7449187b058440e4746f948bd095584d67bb82133c93737204e86c3aeff664a?context=repo).

   Occasionally, there are problems with:
   - Versioning of base Docker images used for building Go binaries. You may need to bump that base image - [example commit](https://github.com/btcpayserver/lnd/commit/c841954c515a9d067c24987291316b093b91c2f2).
   - Updating Loop as part of the package, which needs to happen occasionally. [Example bump of Loop version](https://github.com/btcpayserver/lnd/commit/b3aecc7ac58280ef662e39ba99461573a30fe79a].

2. **Update https://github.com/btcpayserver/BTCPayServer.Lightning**

   Now we need to update the dependency in our Lightning library project. This library has tests, so we will know if something is broken.

   a) Modify the `docker-compose.yml` file to reference the new LND version. [Example](https://github.com/btcpayserver/BTCPayServer.Lightning/pull/162/commits/413784ef9b2a8e7aa0496eb91f792ff0086c0ef7).  
   b) Checkout a new branch for that commit, usually in the format of `feat/lnd-0.18.1`.  
   c) Title the commit `Bumping LND to 0.18.1-beta`.  
   d) Open a pull request and reference Docker Hub and Tag. [Example PR](https://github.com/btcpayserver/BTCPayServer.Lightning/pull/162).
   e) Once tests pass, you can merge it.

3. **Update https://github.com/btcpayserver/btcpayserver**

   This will give access to LND to the whole dev team and allow for further testing on their dev machines if everything works as expected.

   a) Modify 2 `docker-compose.yml` files in `BTCPayServer.Tests`. [Example pull request to emulate](https://github.com/btcpayserver/btcpayserver/pull/6094).  
   b) When you open the PR, include the version and link to the BTCPayServer.Lightning PR.  
   c) Once tests pass, you can merge it.

4. **Update https://github.com/btcpayserver/btcpayserver-docker**

   a) Now that everything is prepared, open a PR in the btcpayserver-docker repository to allow these changes to propagate to everyone. [Example pull request](https://github.com/btcpayserver/btcpayserver-docker/pull/911).  
   b) Open the PR in DRAFT mode and tag @NicolasDorier and @Pavlenex as reviewers. They typically handle releases, and once they test that the LND version update works on their server, they can ACK the update and merge it as part of the release process.

## Source repository

https://github.com/lightningnetwork/lnd

## Links
* [BTCPayServer main repo](https://github.com/btcpayserver/btcpayserver)
* [BTCPayServer-Docker repo](https://github.com/btcpayserver/btcpayserver-docker)
* [BTCPayServer.Lightning](https://github.com/btcpayserver/BTCPayServer.Lightning)
