#!/usr/bin/env python3
"""Zero-footprint e2e of this build's HypowMinter against a LIVE HyperEVM chain.

No deploy, no key, no gas, no transaction: every check is an eth_call.

WHY A SCRIPT AND NOT A `forge test`:
  HyperEVM's L1Read precompiles (0x806/0x80a/0x813) live in the node, not as EVM
  bytecode. A foundry fork fetches account code lazily via eth_getCode, which
  returns empty for a precompile, so on a fork a staticcall to 0x806 succeeds
  with zero returndata and L1Read's abi.decode reverts. The precompiles only
  execute on the live chain.

HOW IT RUNS OUR CODE WITHOUT DEPLOYING:
  `cast call --override-code` injects this build's runtime bytecode at a scratch
  address for one eth_call. capture() and the drand verifier read only storage,
  constants and precompiles (no constructor immutables), so a code override plus
  storage overrides is sufficient.

WHY CAPTURE AND ITS EXPECTED VALUE COME FROM ONE CALL:
  The precompiles read the node's live HyperCore state and ignore the eth_call
  block tag: two calls pinned to the same block return different markPx, and a
  call pinned ~1000 blocks back fails with PrecompileOutOfGas. So capture()
  and the independent position2/markPx reads run in one Multicall3 aggregate3,
  which is the only way they see the same state.

WHAT IT CHECKS (every check paired with a negative control that must fail):
  1. Precompile wiring, per perp dex. Every perp dex the info API lists is
     probed through perpAssetInfo at precompile id dex*10000 + index, and the
     returned coin and szDecimals must match the API's metadata. Control: the id
     one past the last dex must not resolve.
  2. Scaling and capture, per positioned target: the highest-volume live asset of
     the validator dex and of each of HIP3_DEXES, held by the
     recent trader with the largest position.
       - coin/szDecimals match the API. Control: the trading API's id form
         (100000 + dex*10000 + index) does not resolve to the same market.
       - markPx / 10^(6-szDecimals) matches the API mark. Control: the spot
         convention 10^(8-szDecimals) does not.
       - position2 szi matches API szi * 10^szDecimals. Control: a flat
         account's szi does not.
       - capture() from a zero baseline == |szi|*markPx/1e4, from position2 and
         markPx read in the same call. Control: a baseline already at the
         current szi does not capture that value.
       - The lower-of-two-marks rule: from a held baseline (2*szi) whose
         stored mark is half the API mark, the reduction is paid at the stored
         mark, capture == |dszi|*storedMark/1e4; with a stored mark above the
         live one, capture == |dszi|*markPx/1e4. Control: the capped capture is
         not the value at the live mark. A change stores the live mark; an
         unchanged capture only raises the stored mark. The slot is read back
         in the same call.
     Plus: capture() of a flat account is 0. capture() runs with Multicall3
     set as the member's spender by a state override, since only the member or
     its spender may capture. Control: without it, capture reverts.
  3. drand: the minter's own BLS verifier (VerifierHarness, a test-only subclass
     exposing _verifiedSeed) accepts drand evmnet's latest round and yields
     keccak256(signature), using the node's bn254 precompiles 0x06-0x08. Reports
     the verification's gas. Controls: a tampered signature and a wrong round
     must revert.
  4. Collateral. A HIP-3 dex's markPx is quoted in its collateral token, and the
     minter credits it as USD, so a dex on a non-dollar collateral would earn
     credits at the wrong rate (an accepted risk, AUDIT.md V-12). Check 2 can't
     see this, because the API mark is in the same units. Prints each dex's
     collateral (spot token name and id). Every dex with a live
     market must use a $1-pegged token from an explicit list, matched by token
     id.
     Controls: a pretend live dex on a non-pegged token, and a token named USDC
     with another id, must be rejected.

NOT COVERED: spend + settle. settle mints through the token, a constructor
immutable, which is zeroed in the runtime bytecode an override injects.

Usage:
  script/live-e2e.py
  RPC=<url> script/live-e2e.py     # RPC is never printed
"""

import json
import os
import re
import subprocess
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from pathlib import Path

API = "https://api.hyperliquid.xyz/info"
# The HIP-3 dexes whose positions are captured. "io" is dex 10, whose precompile
# ids (100000+) overlap the trading API's HIP-3 id form, so it guards the
# encoding where a mix-up would silently read another market.
HIP3_DEXES = ["xyz", "io"]
# The $1-pegged collateral tokens, spot tokenId -> name, read from spotMeta on
# 2026-09-25. A live dex on any other collateral fails the run (check 4).
PEGGED = {
    "0x6d1e7cde53ba9467b783cb7c530ce054": "USDC",
    "0x54e00a5988577cb0b0c9ab0cb6ef7f4b": "USDH",
    "0x25faedc3f054130dbb4e4203aca63567": "USDT0",
    "0x2e6d84f2d7ca82e6581e03523e4389f7": "USDE",
}
DRAND_LATEST = "https://api.drand.sh/v2/beacons/evmnet/rounds/latest"

MARK_PX = "0x0000000000000000000000000000000000000806"
PERP_INFO = "0x000000000000000000000000000000000000080a"
POSITION2 = "0x0000000000000000000000000000000000000813"
MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11"
SCRATCH = "0x000000000000000000000000000000000000aBc1"
FLAT = "0x000000000000000000000000000000000000bEEF"
TRADERS_PROBED = 10
# The API and the chain are read moments apart, so trades and price ticks move
# them slightly. A scaling bug is off by a power of ten.
TOLERANCE = Decimal("0.05")

if len(sys.argv) != 1:
    sys.exit("usage: live-e2e.py")
RPC = os.environ.get("RPC", "https://rpc.hyperliquid.xyz/evm")
# cast reads ETH_RPC_URL, which keeps a keyed URL off every argv.
ENV = {**os.environ, "ETH_RPC_URL": RPC}

passed = failed = 0


def check(ok, msg):
    global passed, failed
    print(f"  {'PASS' if ok else 'FAIL'}  {msg}")
    passed, failed = passed + ok, failed + (not ok)


def control(still_passes, msg):
    """A negative control: the check applied to a deliberately wrong input must fail."""
    check(not still_passes, f"control: {msg} -> rejected")


def info(payload):
    req = urllib.request.Request(API, json.dumps(payload).encode(), {"content-type": "application/json"})
    return json.load(urllib.request.urlopen(req))


def cast(*args):
    """(ok, stdout-or-error). The error text is redacted of the RPC URL."""
    r = subprocess.run(["cast", *args], env=ENV, capture_output=True, text=True, check=False)
    out = (r.stdout if r.returncode == 0 else r.stderr).strip().replace(RPC, "<rpc>")
    return r.returncode == 0, out


def encode(sig, *args):
    """Raw abi.encode with NO selector, as L1Read calls the precompiles."""
    return cast("abi-encode", sig, *map(str, args))[1]


def words(hexdata):
    h = hexdata[2:]
    return [int(h[i : i + 64], 16) for i in range(0, len(h), 64)]


def perp_info(asset_id):
    """(coin, szDecimals, maxLeverage) as L1Read decodes it, or None if the precompile errors."""
    ok, out = cast("call", PERP_INFO, encode("x(uint32)", asset_id))
    if not ok:
        return None
    w = words(out)
    o = w[0] // 32
    coin_at = o + w[o] // 32
    coin = bytes.fromhex(out[2:][64 * (coin_at + 1) :])[: w[coin_at]].decode()
    return coin, w[o + 2], w[o + 3]


def capture(member, asset_id, baseline, stored_mark=0, authorized=True):
    """(cents, szi, markPx, markPx stored after): capture(member,[asset]) on this
    build with (member, asset) known at `baseline` and `stored_mark`, position2 +
    markPx read raw, and the slot read back, all in the same eth_call. Only the
    member or its spender may capture, and the caller here is Multicall3, so
    `authorized` makes Multicall3 the member's spender. Unauthorized, returns
    (False, error) instead."""
    # memberSlots is storage slot 0; MemberSlot packs int64 lastSnapshotSzi
    # (bytes 0-7), bool known (byte 8) and uint64 lastMarkPx (bytes 9-16).
    # spender is storage slot 4.
    slot = cast("index", "uint32", str(asset_id), cast("index", "address", member, "0")[1])[1]
    value = "0x%064x" % ((stored_mark << 72) | (1 << 64) | (baseline & (2**64 - 1)))
    overrides = [f"{SCRATCH}:{slot}:{value}"]
    if not authorized:
        # Direct, so the revert reason isn't masked by Multicall3.
        return cast(
            "call",
            "--override-code",
            f"{SCRATCH}:{MINTER_CODE}",
            "--override-state-diff",
            overrides[0],
            SCRATCH,
            "capture(address,uint32[])",
            member,
            f"[{asset_id}]",
        )
    spender_slot = cast("index", "address", member, "4")[1]
    overrides.append(f"{SCRATCH}:{spender_slot}:0x{MULTICALL3[2:].lower():0>64}")
    calls = [
        (SCRATCH, cast("calldata", "capture(address,uint32[])", member, f"[{asset_id}]")[1]),
        (POSITION2, encode("x(address,uint32)", member, asset_id)),
        (MARK_PX, encode("x(uint32)", asset_id)),
        (SCRATCH, cast("calldata", "memberSlots(address,uint32)", member, str(asset_id))[1]),
    ]
    ok, out = cast(
        "call",
        "--override-code",
        f"{SCRATCH}:{MINTER_CODE}",
        "--override-state-diff",
        ",".join(overrides),
        MULTICALL3,
        "aggregate3((address,bool,bytes)[])((bool,bytes)[])",
        "[" + ",".join(f"({to},false,{data})" for to, data in calls) + "]",
    )
    assert ok, out
    cents, szi, mark, slot_words = (words(h) for h in re.findall(r"0x[0-9a-f]+", out))
    # szi is an int64 ABI-encoded sign-extended to 256 bits.
    szi = szi[0] - (1 << 256) if szi[0] >= 1 << 255 else szi[0]
    return cents[0], szi, mark[0], slot_words[2]


def revert_reason(err):
    return err.split("execution reverted: ")[-1].split(",")[0]


def near(x, ref):
    return abs(x - ref) <= abs(ref) * TOLERANCE


def artifact(path):
    return json.loads(Path(path).read_text())["deployedBytecode"]["object"]


# --- gather ------------------------------------------------------------------

os.chdir(Path(__file__).resolve().parent.parent)
print(f"[live-e2e] rpc={'RPC env (redacted)' if 'RPC' in os.environ else RPC}")
print("[live-e2e] building")
subprocess.run(["forge", "build", "--silent"], check=True)
MINTER_CODE = artifact("out/HypowMinter.sol/HypowMinter.json")
VERIFIER_CODE = artifact("out/HypowMinter.t.sol/VerifierHarness.json")

dex_names = [d["name"] if d else "" for d in info({"type": "perpDexs"})]
metas = info({"type": "allPerpMetas"})
universes = [m["universe"] for m in metas]
assert len(universes) == len(dex_names), "allPerpMetas and perpDexs disagree on the dex count"
spot_tokens = {t["index"]: t for t in info({"type": "spotMeta"})["tokens"]}


def pick_target(dex):
    """The dex's highest-volume live asset and the recent trader holding the most of it."""
    meta, ctxs = info({"type": "metaAndAssetCtxs", "dex": dex_names[dex]})
    index = max(
        (float(c["dayNtlVlm"]), i) for i, (a, c) in enumerate(zip(meta["universe"], ctxs)) if not a.get("isDelisted")
    )[1]
    coin = meta["universe"][index]["name"]
    traders = list(dict.fromkeys(u for t in info({"type": "recentTrades", "coin": coin}) for u in t["users"]))
    held = []
    for user in traders[:TRADERS_PROBED]:
        state = info({"type": "clearinghouseState", "user": user, "dex": dex_names[dex]})
        held += [
            (abs(Decimal(p["position"]["szi"])), user, p["position"]["szi"])
            for p in state["assetPositions"]
            if p["position"]["coin"] == coin
        ]
    assert held, f"no recent trader of {coin} holds a position"
    _, member, api_szi = max(held)
    return {
        "dex": dex,
        "id": dex * 10000 + index,
        "coin": coin,
        "member": member,
        "api_szi": Decimal(api_szi),
        "api_mark": Decimal(ctxs[index]["markPx"]),
        "sz_dec": meta["universe"][index]["szDecimals"],
    }


targets = [pick_target(dex_names.index(n)) for n in ["", *HIP3_DEXES]]
drand = json.load(urllib.request.urlopen(DRAND_LATEST))
print(f"[live-e2e] block={cast('block-number')[1]}")

# --- 1. precompile wiring, every dex -----------------------------------------

print(f"[1] perpAssetInfo at dex*10000+index for all {len(dex_names)} perp dexes")


def first_live(u):
    return next((i for i, a in enumerate(u) if not a.get("isDelisted")), 0)


probe = [(d, first_live(u)) for d, u in enumerate(universes)]
with ThreadPoolExecutor(8) as pool:
    infos = list(pool.map(lambda p: perp_info(p[0] * 10000 + p[1]), probe))
for (dex, index), got in zip(probe, infos):
    a = universes[dex][index]
    want = (a["name"], a["szDecimals"])
    status = "delisted" if a.get("isDelisted") else "live"
    check(
        got is not None and got[:2] == want and 0 < got[2] and got[1] <= 24,
        f"dex {dex:>3} {dex_names[dex] or '(validator)':<8} id {dex * 10000 + index:>7} {status:<8} -> {got}",
    )
control(perp_info(len(dex_names) * 10000) is not None, f"id {len(dex_names) * 10000} (one dex past the last) resolves")

# --- 2. scaling + capture, positioned targets ---------------------------------

for t in targets:
    print(f"[2] {t['coin']} (dex {t['dex']}, precompile id {t['id']}) member={t['member']}")
    got = perp_info(t["id"])
    check(got is not None and got[:2] == (t["coin"], t["sz_dec"]), f"perpAssetInfo -> {got}")
    trading_id = 100000 + t["id"]
    control(
        perp_info(trading_id) == got, f"id {trading_id} (100000 + id, the trading API's form) reads the same market"
    )

    cents, s, mark, _ = capture(t["member"], t["id"], 0)
    check(
        mark > 0 and near(Decimal(mark).scaleb(t["sz_dec"] - 6), t["api_mark"]),
        f"markPx {mark} / 10^(6-{t['sz_dec']}) ~ API mark {t['api_mark']}",
    )
    control(
        near(Decimal(mark).scaleb(t["sz_dec"] - 8), t["api_mark"]),
        "spot scaling 10^(8-szDecimals) matches the API mark",
    )

    api_szi = t["api_szi"].scaleb(t["sz_dec"])
    check(s != 0 and near(s, api_szi), f"position2 szi {s} ~ API szi {t['api_szi']} * 10^{t['sz_dec']}")
    flat_cents, flat_szi, _, _ = capture(FLAT, t["id"], 0)
    control(near(flat_szi, api_szi), "a flat account's szi matches the API szi")

    expect = abs(s) * mark // 10_000
    check(cents == expect and expect > 0, f"capture from zero {cents} == |szi|*markPx/1e4 {expect} cents")
    held_cents, held_szi, held_mark, held_stored = capture(t["member"], t["id"], s)
    control(
        held_cents == abs(held_szi) * held_mark // 10_000,
        f"capture with the baseline already at szi ({held_cents}) is the full position's value",
    )
    check(held_stored == held_mark, f"an unchanged capture raises a lower stored mark to the live markPx {held_stored}")
    # An active member may have traded since `s` was read; then it is a change.
    _, kept_szi, kept_mark, kept = capture(t["member"], t["id"], s, 2**64 - 1)
    check(
        kept == (2**64 - 1 if kept_szi == s else kept_mark),
        f"an unchanged capture keeps a stored mark above the live {kept_mark} (a change stores the live one)",
    )
    check(flat_cents == 0, "capture of a flat account == 0")
    ok, out = capture(t["member"], t["id"], 0, authorized=False)
    control(
        ok or revert_reason(out) != "not spender",
        f"capture by a caller that is neither the member nor its spender succeeds ({revert_reason(out)})",
    )

    # Baseline 2*szi: a held position whose change is about |szi|. The member
    # may trade between calls, so each expectation uses the szi read in its
    # own call.
    low = int(t["api_mark"].scaleb(6 - t["sz_dec"]) / 2)
    capped, c_szi, c_mark, c_stored = capture(t["member"], t["id"], 2 * s, low)
    c_delta = abs(c_szi - 2 * s)
    check(
        capped == c_delta * low // 10_000 and low < c_mark and c_stored == c_mark,
        f"from a held baseline with stored mark {low}: capture {capped} == |dszi|*stored/1e4, live {c_mark} stored after",
    )
    control(capped == c_delta * c_mark // 10_000, f"the capped capture ({capped}) is the value at the live mark")
    high, h_szi, h_mark, _ = capture(t["member"], t["id"], 2 * s, 2**64 - 1)
    check(
        high == abs(h_szi - 2 * s) * h_mark // 10_000 and high > 0,
        f"from a held baseline with a stored mark above live: capture {high} == |dszi|*markPx/1e4",
    )

# --- 3. drand verification ------------------------------------------------------

rnd, sig = drand["round"], "0x" + drand["signature"]
print(f"[3] drand evmnet round {rnd} through the minter's BLS verifier")


def verify(r, s):
    return cast(
        "call",
        "--override-code",
        f"{SCRATCH}:{VERIFIER_CODE}",
        SCRATCH,
        "verifiedSeed(uint64,bytes)(bytes32)",
        str(r),
        s,
    )


ok, seed = verify(rnd, sig)
check(ok and seed == cast("keccak", sig)[1], f"verifies; seed {seed} == keccak256(signature)")
data = cast("calldata", "verifiedSeed(uint64,bytes)", str(rnd), sig)[1]
overrides = json.dumps({SCRATCH: {"code": VERIFIER_CODE}})
ok, est = cast("rpc", "eth_estimateGas", json.dumps({"to": SCRATCH, "data": data}), "latest", overrides)
assert ok, est
calldata_gas = sum(16 if b else 4 for b in bytes.fromhex(data[2:]))
gas = int(json.loads(est), 16)
print(f"      verify gas: {gas} eth_estimateGas, {gas - 21000 - calldata_gas} after intrinsic+calldata")
tampered = sig[:-2] + "%02x" % (int(sig[-2:], 16) ^ 1)
ok, out = verify(rnd, tampered)
control(ok, f"tampered signature verifies ({revert_reason(out)})")
ok, out = verify(rnd - 1, sig)
control(ok, f"round {rnd - 1} verifies with round {rnd}'s signature ({revert_reason(out)})")

# --- 4. collateral, every dex --------------------------------------------------

print("[4] collateral per perp dex (markPx is quoted in it; the minter reads it as USD)")


def pegged(token):
    return PEGGED.get(token["tokenId"]) == token["name"]


def live_markets(meta):
    return sum(not a.get("isDelisted") for a in meta["universe"])


def unpegged_live(dexes):
    """(name, collateral) of every (name, meta, collateral) dex with a live market on unlisted collateral."""
    return [(name, tok) for name, m, tok in dexes if live_markets(m) and not pegged(tok)]


dexes = [(name or "(validator)", m, spot_tokens[m["collateralToken"]]) for name, m in zip(dex_names, metas)]
on_usdc = []
for dex, (name, m, tok) in enumerate(dexes):
    if m["collateralToken"] == 0:
        on_usdc.append(f"{name}:{live_markets(m)}")
        continue
    print(
        f"      dex {dex:>3} {name:<8} {tok['name']:<7} {tok['tokenId']} "
        f"{'pegged' if pegged(tok) else 'NOT PEGGED':<10} live markets {live_markets(m)}"
    )
print(f"      {len(on_usdc)} dexes on USDC {spot_tokens[0]['tokenId']} (name:live markets): {' '.join(on_usdc)}")
offenders = unpegged_live(dexes)
listed = ", ".join(f"{name} ({tok['name']})" for name, tok in offenders) or "none"
check(not offenders, f"every dex with a live market is on $1-pegged collateral; offenders: {listed}")
fake = ("fake", {"universe": [{"name": "SILVER"}]}, {"name": "XAG", "tokenId": "0x" + "ab" * 16})
control(not unpegged_live([fake]), "a pretend live dex on XAG collateral passes the gate")
control(pegged({"name": "USDC", "tokenId": "0x" + "00" * 16}), "a token named USDC with another token id is pegged")

print(f"[live-e2e] pass={passed} fail={failed}")
sys.exit(failed > 0)
