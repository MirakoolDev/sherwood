# HoodRand

**Verifiable randomness for Robinhood Chain.** HoodRand turns drand's public randomness beacon into random numbers your contract can use, checked onchain, so nobody can predict or bias them. That includes PFWA, which runs it.

- **Contract:** [`0xbE5105faf1Cb76733876959d5802448d066D734F`](https://robinhoodchain.blockscout.com/address/0xbE5105faf1Cb76733876959d5802448d066D734F) on Robinhood Chain (chain id 4663)
- **Fee:** 0.00002 ETH per request (about 5 cents)
- **Answer time:** about 15 to 20 seconds after the request

## Why

Robinhood Chain has no Chainlink VRF and no Pyth Entropy. The randomness services that exist there run commit-reveal from their own server: if that server stops, every game waiting on it stops too, and you have to trust the server's secret. HoodRand has no secret and no single server:

1. **The randomness comes from [drand](https://drand.love)**, run by the [League of Entropy](https://www.drand.love/about) (Cloudflare, Protocol Labs, universities and others). Its **evmnet** beacon publishes a new BLS signature on the BN254 curve every 3 seconds, and the signature is the random value.
2. **A request is tied to a round that hasn't happened yet**, 5 rounds (15 to 18 seconds) after the request. Nobody can know its value when the request is made.
3. **Anyone can submit that round's signature.** The contract checks it against drand's public key with Robinhood Chain's BN254 pairing precompile, so only the real beacon value is accepted. PFWA's relayer submits every round with waiting requests; if it's down, the requester or anyone else can.
4. **Each request gets its own number:** `keccak256(sha256(signature), userRandomNumber, sequence)`.

## Use it

HoodRand has the same interface as Dice Protocol and Pyth Entropy, so a contract built for them works unchanged:

```solidity
interface IHoodRand {
    function getFeeV2(address provider, uint32 gasLimit) external view returns (uint128);
    function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit) external payable returns (uint64 sequence);
    function refundRequest(address provider, uint64 sequence) external;
}

// Your contract receives:
function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external;
```

- Pass HoodRand's own address as `provider`. It is ignored: HoodRand is its own provider.
- Send exactly `getFeeV2(...)` with the request. `gasLimit` is the gas your callback gets, up to 1,000,000.
- Check `msg.sender == HoodRand` in your callback, and don't revert in it: a reverting callback is still counted as answered.
- If a request isn't answered within a day, `refundRequest` returns its fee to you.

To answer a round yourself, fetch its signature from drand (`https://api.drand.sh/v2/beacons/evmnet/rounds/<round>`) and call `reveal(round, signature, maxAnswers)`.

## drand evmnet

| | |
|---|---|
| Chain hash | `04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3` |
| Genesis | 1727521075 |
| Period | 3 seconds |
| Scheme | `bls-bn254-unchained-on-g1` |
| Info | https://api.drand.sh/v2/beacons/evmnet/info |

## What the owner can do

Set the fee (up to 0.0002 ETH), withdraw the fees of answered requests (fees of open requests stay refundable), and hand over ownership in two steps. Nothing else: the owner has no say over any result.

## Trust

- drand's security assumes the League of Entropy's nodes don't collude past its threshold.
- Robinhood Chain's sequencer sets block timestamps. The 5-round delay is the margin against a timestamp running behind real time.
- The BLS library in `src/vendor/` is described by its authors as experimental and unaudited, and HoodRand itself hasn't been audited yet.

## Build and test

```
cd hoodrand
forge test
```

The tests verify real evmnet signatures (rounds 2, 1000 and 21899791 to 21899793). Checking a round costs about 228k gas; checking it and answering one request about 392k.

## Credits and license

- `src/vendor/` is randa-mu's [bls-solidity](https://github.com/randa-mu/bls-solidity) (commit 11af179), MIT (see `src/vendor/LICENSE-bls-solidity`), itself based on Kevin Charm's [bls-bn254](https://github.com/kevincharm/bls-bn254).
- `src/HoodRand.sol` and the tests are under the Business Source License 1.1: see [LICENSE](LICENSE).
