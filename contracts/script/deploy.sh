#!/usr/bin/env bash
#
# HyperEVM mainnet deployment of Hypow contracts.
#
# We deploy via raw `cast send --create` rather than `forge script`, so no
# local EVM simulation runs before broadcasting. forge's simulator lacks
# HyperEVM's L1Read precompiles; the minter's constructor reads none today,
# but `cast send --create` runs every deploy step on the real chain regardless.
#
# Mirrors Deploy.s.sol logic: predicts the minter's address with nonce+1,
# deploys token first with that as the minter parameter, then deploys the
# minter — which lands at the predicted address and references the just-
# deployed token.
#
# Every parameter is required: token/minter wiring and the genesis params are
# immutable once deployed, so nothing is left to a default.
#
#   DEPLOYER_ACCOUNT        foundry keystore account (`cast wallet import <name> --interactive`)
#   RPC_URL                 HyperEVM RPC (chain 999)
#   GENESIS_DIFFICULTY      1 (the floor; a high genesis stalls emission, since
#                           the first retarget only fires after the first win)
#   TARGET_INTERVAL_SECONDS 60 (seconds of block.timestamp, not HyperCore L1
#                           blocks, which run ~13-16 per second)
#   RETARGET_WINDOW         2016 (Bitcoin's cadence)
#
# The drand evmnet beacon is hardcoded in HypowMinter; its parameters are
# pinned below and cross-checked against the live beacon info before deploying,
# so a beacon change is caught before an immutable minter trusts the old key.
#
#   DEPLOYER_ACCOUNT=hypow-deployer RPC_URL=https://rpc.hyperliquid.xyz/evm \
#   GENESIS_DIFFICULTY=1 TARGET_INTERVAL_SECONDS=60 RETARGET_WINDOW=2016 \
#   ./script/deploy.sh

set -euo pipefail

for var in DEPLOYER_ACCOUNT RPC_URL GENESIS_DIFFICULTY TARGET_INTERVAL_SECONDS RETARGET_WINDOW; do
  if [[ -z "${!var:-}" ]]; then
    echo "error: $var env var is required" >&2
    exit 1
  fi
done

cd "$(dirname "$0")/.."

# drand evmnet (mirrors HypowMinter's DRAND_* constants and _DRAND_KEY_*).
DRAND_CHAIN_HASH=04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3
DRAND_PUBLIC_KEY=07e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b3820557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f0095685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b
DRAND_INFO=$(curl -fsS "https://api.drand.sh/v2/beacons/evmnet/info")
if [[ "$(echo "$DRAND_INFO" | jq -r '.chain_hash')" != "$DRAND_CHAIN_HASH" \
   || "$(echo "$DRAND_INFO" | jq -r '.public_key')" != "$DRAND_PUBLIC_KEY" \
   || "$(echo "$DRAND_INFO" | jq -r '.scheme')" != "bls-bn254-unchained-on-g1" \
   || "$(echo "$DRAND_INFO" | jq -r '.period')" != "3" \
   || "$(echo "$DRAND_INFO" | jq -r '.genesis_time')" != "1727521075" ]]; then
  echo "error: live drand evmnet info does not match the pinned beacon parameters" >&2
  exit 1
fi

WALLET=(--account "$DEPLOYER_ACCOUNT")
DEPLOYER_ADDR=$(cast wallet address "${WALLET[@]}")
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
BAL_WEI=$(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_URL")

if [[ "$BAL_WEI" == "0" ]]; then
  echo "error: deployer $DEPLOYER_ADDR has zero balance, fund it before deploying" >&2
  exit 1
fi

# Creating the minter takes ~4.3M gas, but HyperEVM's small blocks hold 3M, so
# the create only fits in a big block. An address opts in through a HyperCore
# action it signs itself: `evmUserModify {usingBigBlocks: true}`, e.g. the
# Hyperliquid Python SDK's `Exchange(account, url).use_big_blocks(True)`.
if [[ "$(cast rpc eth_usingBigBlocks "$DEPLOYER_ADDR" --rpc-url "$RPC_URL")" != "true" ]]; then
  echo "error: deployer $DEPLOYER_ADDR is not using big blocks; the minter create needs one (enable with evmUserModify)" >&2
  exit 1
fi

BLK_HEX=$(cast call 0x0000000000000000000000000000000000000809 --rpc-url "$RPC_URL")
if [[ -z "$BLK_HEX" || "$BLK_HEX" == "0x" ]]; then
  echo "error: L1_BLOCK_NUMBER precompile returned no data — not a HyperEVM RPC?" >&2
  exit 1
fi

echo "[deploy] deployer             = $DEPLOYER_ADDR"
echo "[deploy] balance              = $(cast from-wei "$BAL_WEI") HYPE"
echo "[deploy] rpc                  = $RPC_URL"
echo "[deploy] chain id             = $CHAIN_ID"
echo "[deploy] genesisDifficulty    = $GENESIS_DIFFICULTY"
echo "[deploy] targetIntervalSecs  = $TARGET_INTERVAL_SECONDS"
echo "[deploy] retargetWindow       = $RETARGET_WINDOW"
echo "[deploy] drand beacon         = evmnet (chain hash $DRAND_CHAIN_HASH)"
read -r -p "Deploy with these immutable parameters? Type 'deploy' to continue: " CONFIRM
if [[ "$CONFIRM" != "deploy" ]]; then
  echo "aborted" >&2
  exit 1
fi

forge build --silent

NONCE=$(cast nonce "$DEPLOYER_ADDR" --rpc-url "$RPC_URL")
PREDICTED_MINTER=$(cast compute-address "$DEPLOYER_ADDR" --nonce $((NONCE + 1)) | awk '{print $NF}')
echo "[deploy] nonce=$NONCE predicted minter=$PREDICTED_MINTER"

# Deploys init code and prints the receipt JSON, failing on a reverted tx.
create() {
  local tx status
  tx=$(cast send --rpc-url "$RPC_URL" "${WALLET[@]}" --create "$1" --json)
  status=$(echo "$tx" | jq -r '.status')
  if [[ "$status" != "0x1" ]]; then
    echo "error: deploy tx failed (status=$status)" >&2
    exit 1
  fi
  echo "$tx"
}

# 1. HypowToken, bound to the predicted minter address.
TOKEN_INIT="$(jq -r '.bytecode.object' out/HypowToken.sol/HypowToken.json)$(cast abi-encode 'constructor(address)' "$PREDICTED_MINTER" | sed 's/^0x//')"
TOKEN_ADDR=$(create "$TOKEN_INIT" | jq -r '.contractAddress')
echo "[deploy] token deployed: $TOKEN_ADDR"

# 2. HypowMinter with the token address + genesis params.
MINTER_INIT="$(jq -r '.bytecode.object' out/HypowMinter.sol/HypowMinter.json)$(cast abi-encode 'constructor(address,uint128,uint64,uint32)' \
  "$TOKEN_ADDR" "$GENESIS_DIFFICULTY" "$TARGET_INTERVAL_SECONDS" "$RETARGET_WINDOW" | sed 's/^0x//')"
MINTER_TX=$(create "$MINTER_INIT")
MINTER_ADDR=$(echo "$MINTER_TX" | jq -r '.contractAddress')
echo "[deploy] minter deployed: $MINTER_ADDR"

# Sanity: predicted == actual; token <-> minter link.
lower() { tr '[:upper:]' '[:lower:]'; }
if [[ "$(echo "$MINTER_ADDR" | lower)" != "$(echo "$PREDICTED_MINTER" | lower)" ]]; then
  echo "error: minter landed at $MINTER_ADDR but predicted $PREDICTED_MINTER" >&2
  exit 1
fi
TOKEN_BOUND_MINTER=$(cast call "$TOKEN_ADDR" 'minter()(address)' --rpc-url "$RPC_URL")
if [[ "$(echo "$TOKEN_BOUND_MINTER" | lower)" != "$(echo "$MINTER_ADDR" | lower)" ]]; then
  echo "error: token.minter() = $TOKEN_BOUND_MINTER, expected $MINTER_ADDR" >&2
  exit 1
fi

# The minter's deploy block is where log readers (the miner, explorers) start
# their `eth_getLogs` walk.
MINTER_BLOCK=$(cast to-dec "$(echo "$MINTER_TX" | jq -r '.blockNumber')")

echo ""
echo "[deploy] done."
echo "  Minter      : $MINTER_ADDR"
echo "  Token       : $TOKEN_ADDR"
echo "  Deploy block: $MINTER_BLOCK"
