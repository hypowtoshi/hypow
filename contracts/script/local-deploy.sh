#!/usr/bin/env bash
#
# Local deployment of Hypow contracts to a fresh Anvil instance.
# Etches mock L1Read precompiles at their canonical addresses so the mining
# flow (capture → spend → settle) can be exercised end-to-end. Settle verifies
# real drand evmnet signatures: fetch the target round's signature from
# https://api.drand.sh/v2/beacons/evmnet/rounds/<round> once it is published.
#
# Usage:
#   ./script/local-deploy.sh                # starts anvil, deploys, prints addresses
#   ANVIL_RPC=http://127.0.0.1:8545 ./script/local-deploy.sh --no-start
#
# Anvil's default account #0 is used as the deployer. Its private key is the
# well-known Anvil default; safe to commit.

set -euo pipefail

RPC="${ANVIL_RPC:-http://127.0.0.1:8545}"
CHAIN_ID=31337
START_ANVIL=1
if [[ "${1:-}" == "--no-start" ]]; then START_ANVIL=0; fi

# Default Anvil deployer (account #0).
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER_ADDR=0xf39Fd6e51aad88F6F4ce6aB8827279cfFFb92266

# HyperEVM L1Read precompile addresses actually used by v1 (mirror src/lib/L1Read.sol).
# Legacy POSITION (0x800) and forward-looking SPOT_BALANCE (0x801) intentionally
# omitted — the v1 minter doesn't read them.
ADDR_MARK_PX=0x0000000000000000000000000000000000000806
ADDR_PERP_ASSET_INFO=0x000000000000000000000000000000000000080a
ADDR_POSITION2=0x0000000000000000000000000000000000000813

cd "$(dirname "$0")/.."

if [[ $START_ANVIL -eq 1 ]]; then
  pkill -f "anvil --chain-id $CHAIN_ID" 2>/dev/null || true
  sleep 1
  anvil --chain-id "$CHAIN_ID" --silent > /tmp/hypow-anvil.log 2>&1 &
  ANVIL_PID=$!
  echo "[local-deploy] started anvil pid=$ANVIL_PID, log=/tmp/hypow-anvil.log"
  sleep 2
fi

echo "[local-deploy] building"
forge build --silent

echo "[local-deploy] deploying MockPrecompiles template"
MP_ADDR=$(forge create test/mocks/MockPrecompiles.sol:MockPrecompiles \
  --private-key "$DEPLOYER_KEY" \
  --rpc-url "$RPC" \
  --broadcast --json | jq -r .deployedTo)
echo "[local-deploy]   template at $MP_ADDR"
MP_CODE=$(cast code "$MP_ADDR" --rpc-url "$RPC")

echo "[local-deploy] etching MockPrecompiles bytecode at canonical addresses"
for ADDR in "$ADDR_MARK_PX" "$ADDR_PERP_ASSET_INFO" "$ADDR_POSITION2"; do
  cast rpc anvil_setCode "$ADDR" "$MP_CODE" --rpc-url "$RPC" > /dev/null
done

echo "[local-deploy] seeding perpAssetInfo for BTC (asset=0, szDecimals=8)"
cast send "$ADDR_PERP_ASSET_INFO" \
  "setPerpAssetInfo(uint32,(string,uint32,uint8,uint8,bool))" \
  0 "(BTC,0,8,50,false)" \
  --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" > /dev/null

# HL's markPx precompile returns price × 10^(6 − szDecimals). For BTC with
# szDecimals=8 the scale is 10^(-2), so $100,000 → 1_000. The cents math in
# _captureDeltaCents uses a constant 10_000 divisor that bakes this in.
echo "[local-deploy] seeding markPx for BTC = 1000 (\$100k at szDecimals=8 HL scaling)"
cast send "$ADDR_MARK_PX" "setMarkPx(uint32,uint64)" 0 1000 \
  --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" > /dev/null

echo "[local-deploy] deploying token + minter via Deploy.s.sol"
export DEPLOYER_PRIVATE_KEY="$DEPLOYER_KEY"
export GENESIS_DIFFICULTY=1
export TARGET_INTERVAL_SECONDS=60
export RETARGET_WINDOW=2016

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC" \
  --broadcast \
  --silent > /dev/null

BROADCAST_FILE="broadcast/Deploy.s.sol/31337/run-latest.json"
TOKEN_ADDR=$(jq -r '.transactions[] | select(.contractName=="HypowToken") | .contractAddress' "$BROADCAST_FILE" | head -1)
MINTER_ADDR=$(jq -r '.transactions[] | select(.contractName=="HypowMinter") | .contractAddress' "$BROADCAST_FILE" | head -1)

echo ""
echo "[local-deploy] done."
echo ""
echo "  Token   : $TOKEN_ADDR"
echo "  Minter  : $MINTER_ADDR"
echo "  Deployer: $DEPLOYER_ADDR"
echo "  RPC     : $RPC"
echo "  Chain   : 31337"
echo ""
echo "Quick checks:"
echo "  cast call $TOKEN_ADDR  'name()(string)'             --rpc-url $RPC"
echo "  cast call $TOKEN_ADDR  'CAP()(uint256)'             --rpc-url $RPC"
echo "  cast call $MINTER_ADDR 'targetIntervalSeconds()(uint64)' --rpc-url $RPC"
echo ""
if [[ $START_ANVIL -eq 1 ]]; then
  echo "Anvil is running in the background (pid=$ANVIL_PID). To stop: kill $ANVIL_PID"
fi
