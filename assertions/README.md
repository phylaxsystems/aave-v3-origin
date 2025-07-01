# Assertions for Aave V3

## Overview

This directory contains assertions for Aave V3.

The assertions are based on the [Aave V3 Invariants Specs](https://github.com/phylaxsystems/aave-v3-origin/tree/feat/assertions/tests/invariants/specs).

We have added a bug in the borrow function logic that allows users to borrow more than they should.
This is done to showcase the power of the assertions.

DO NOT USE THE AAVE CONTRACTS IN THIS REPOSITORY IN PRODUCTION.

## Trigger the assertion on-chain

The Aave v3 Pool proxy is currently deployed on the Phylax Demo on address: `0x36B1E2aFe63c6b4D1F3aa00Af689851F00461683`.

Reach out in our [public Telegram](https://t.me/phylax_credible_layer) to request access to the Phylax Demo if you don't have it yet.

Follow these steps to trigger the assertion on-chain:

### Setup Environment Variables

```bash
export POOL_ADDRESS=0x36B1E2aFe63c6b4D1F3aa00Af689851F00461683
export RPC_URL=link_to_phylax_demo_rpc # ask in our public Telegram
export PUBLIC_KEY=0x... # your 0x public key
export PRIVATE_KEY=0x... # your 0x private key
export TEST_TOKEN=0x49947b1E7AB75e143c2fea9b273eF7D4fa7B9f6B # test token used as reserve on aave v3
```

### Get ETH and mint test token

Use the Phylax Demo faucet to get some ETH (link left out on purpose)

Then mint some of the test token:

```bash
cast send $TEST_TOKEN "mint(address,uint256)" $PUBLIC_KEY 1000000000000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

verify you have some test token in your wallet:

```bash
cast call $TEST_TOKEN "balanceOf(address)" $PUBLIC_KEY --rpc-url $RPC_URL 
```

### Supply test token to the Pool

First approve the pool to spend your test token:

```bash
cast send $TEST_TOKEN "approve(address,uint256)" $POOL_ADDRESS 0.001ether --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

Supply the test token to the pool:

```bash
cast send $POOL_ADDRESS "supply(address,uint256,address,uint16)" $TEST_TOKEN 10000000000 $PUBLIC_KEY 0 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

### Borrow test token

Borrow some of the test token from the pool. We will use the buggy number which is 333e6. When someone tries to borrow this number it triggers a bug in the the BorrowLogic.sol contract, that mints double the amout of underlying.
This should not be allowed so the transaction should make the assertion revert.

```bash
cast send $POOL_ADDRESS "borrow(address,uint256,uint256,uint16,address)" $TEST_TOKEN 333000000 2 0 $PUBLIC_KEY --rpc-url $RPC_URL --private-key $PRIVATE_KEY --timeout 20
```

## Running the tests

```bash
FOUNDRY_PROFILE=assertions pcl test
```
