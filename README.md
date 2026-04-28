# GMEngine
Generate visible, honest on-chain activity across multiple EVM networks.
Daily GM, contract deployments, NFT minting, streaks, and automated relaying.
This repository contains **Solidity smart contracts** used on [GMEngine.xyz](https://www.gmengine.xyz) platform.
They are designed for **daily on-chain activity** (GM, deploy, mint, streaks) and optional **relayer automation**
using **EIP-712** signatures.

## Contracts
- **`GMContract.sol`**
  - Daily **GM** tracker with streaks and totals.
  - Supports **manual GM** (`gmSelf()`) and **AutoGM** relayed GM.
  - Authorization is based on **EIP-712** messages `{ user, nonce, deadline }`.

- **`DeployFactory.sol`**
  - Daily **deployment streak** tracker.
  - Supports **manual deploy** (`deploySelf()`) and **AutoDeploy** relayed deploy.
  - Deploys user-owned minimal contracts on demand.

- **`MinimalContract.sol`**
  - Minimal per-user contract used for explorer visibility.
  - Stores `owner`, `deployedAt`.
  - Provides interaction method: a free `ping()` that increments counters and emits `Ping`.

- **`MinimalContractPayable.sol`**
  - Paid version of `MinimalContract`.
  - `ping()` is **payable** and requires the fee, set by the deployer.
  - Owner can update `pingPriceWei` and withdraw accumulated funds via `rescueFunds()`.

- **`WarmupNFT.sol`**
  - NFTs.

- **`WarmupSBT.sol`**
  - Soulbound NFTs.

## Deployed
- **Solidity**: `0.8.30+commit.73712a01`
- **EVM Version**: `Osaka`
- **Optimization**: `false`
- **Dependencies**: `OpenZeppelin@5.6.1`

## License
MIT
