import { getAddress, toHex, type Address, type Hex } from 'viem';
import { minterAbi, type Reader, type SpenderAuth } from '../src/chain.ts';
import { status } from '../src/core.ts';
import { covers } from '../src/network.ts';
import { hype, short, type Line } from '../src/text.ts';

/** An EIP-1193 provider, as far as this page uses one. */
export type Provider = { request: (args: { method: string; params?: unknown[] }) => Promise<unknown> };
/** A browser wallet; `icon` is the data URI it announces over EIP-6963. */
export type Wallet = { name: string; icon: string | undefined; provider: Provider };

/** How long the owner's signature stays valid: it is submitted once the HYPE transfer after it lands. */
const SIGNATURE_TTL_S = 3600;

// EIP-6963: every installed wallet announces itself, so one extension claiming
// window.ethereum can't hide the others. Listening from load catches wallets
// that announce before we ask.
const announced = new Map<string, Wallet>();
window.addEventListener('eip6963:announceProvider', (e) => {
  const { info, provider } = (e as CustomEvent<{ info: { uuid: string; name: string; icon?: string }; provider: Provider }>).detail;
  announced.set(info.uuid, { name: info.name, icon: info.icon || undefined, provider });
});

/** The browser's wallets: every EIP-6963 announcement, else window.ethereum. */
export async function discover(): Promise<Wallet[]> {
  window.dispatchEvent(new Event('eip6963:requestProvider'));
  // Wallets answer synchronously in practice; this lets a slow one land.
  await new Promise((resolve) => setTimeout(resolve, 200));
  if (announced.size > 0) return [...announced.values()];
  const eth = (window as { ethereum?: Provider }).ethereum;
  return eth ? [{ name: 'Browser wallet', icon: undefined, provider: eth }] : [];
}

/** The account the wallet connects as. */
export async function account(provider: Provider): Promise<Address> {
  const [a] = (await provider.request({ method: 'eth_requestAccounts' })) as string[];
  if (!a) throw new Error('the wallet returned no account');
  return getAddress(a);
}

/** Put the wallet on `c`'s chain, adding the chain first if the wallet doesn't know it. */
async function onChain(provider: Provider, c: Reader): Promise<void> {
  const chainId = toHex(c.net.chainId);
  if ((await provider.request({ method: 'eth_chainId' })) === chainId) return;
  try {
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId }] });
  } catch (err) {
    if ((err as { code?: number }).code !== 4902) throw err;
    await provider.request({
      method: 'wallet_addEthereumChain',
      params: [
        {
          chainId,
          chainName: c.net.name,
          nativeCurrency: { name: 'HYPE', symbol: 'HYPE', decimals: 18 },
          rpcUrls: [c.net.walletRpc],
        },
      ],
    });
  }
}

/** Send the key `gas` HYPE from the wallet's account `from`, and wait for it to land. */
export async function fund(c: Reader, provider: Provider, from: Address, gas: bigint, line: Line): Promise<void> {
  await onChain(provider, c);
  line('gas', `confirm sending ${hype(gas)} HYPE to the miner key in your wallet · ${covers(c.net, gas)} · you'll be asked to top up when it runs low`);
  const hash = (await provider.request({
    method: 'eth_sendTransaction',
    params: [{ from, to: c.account.address, value: toHex(gas) }],
  })) as Hex;
  line('gas', `HYPE sent · tx ${short(hash)} · waiting for HyperEVM`);
  const receipt = await c.read.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error(`the HYPE transfer failed · tx ${hash}`);
}

/**
 * Have the owner sign a SetSpender authorization, fund the key from the
 * owner's wallet if it lacks HYPE for fees, then `submit` the signature from
 * the key (setSpenderBySig), so the wallet sends at most one transaction.
 * Signing comes first: it is free and says what the owner agrees to, so
 * declining it spends nothing. Each step is skipped if the chain already
 * shows it done. `keyName` names the key in the log.
 */
export async function authorize(
  c: Reader,
  provider: Provider,
  owner: Address,
  opts: { gas: bigint; keyName: string; submit: (auth: SpenderAuth) => Promise<Hex> },
  line: Line,
): Promise<void> {
  const key = c.account.address;
  const s = await status(c, owner);
  const auth = s.spender ? undefined : await sign(c, provider, owner, line);

  if (!s.gas) {
    await fund(c, provider, owner, opts.gas, line);
    line('funded', `the miner key holds ${hype(await c.read.getBalance({ address: key }))} HYPE for fees`);
  }

  if (auth) {
    const hash = await opts.submit(auth);
    line('authorized', `${opts.keyName} mines for ${short(owner)} · tx ${short(hash)}`);
  }
}

/** The owner's SetSpender signature for `c`'s key, from their wallet. */
async function sign(c: Reader, provider: Provider, owner: Address, line: Line): Promise<SpenderAuth> {
  const nonce = await c.read.readContract({ address: c.net.minter, abi: minterAbi, functionName: 'nonces', args: [owner] });
  const deadline = BigInt(Math.floor(Date.now() / 1000) + SIGNATURE_TTL_S);
  line(
    'authorize',
    `sign to let the miner key play your attempts · it can't trade, move funds or touch your Hyperliquid account · rewards always go to ${short(owner)} · a signature, not a transaction`,
  );
  await onChain(provider, c);
  const signature = await signSetSpender(provider, c, owner, c.account.address, nonce, deadline);
  return { owner, nonce, deadline, signature };
}

async function signSetSpender(
  provider: Provider,
  c: Reader,
  owner: Address,
  spender: Address,
  nonce: bigint,
  deadline: bigint,
): Promise<Hex> {
  const typed = {
    types: {
      EIP712Domain: [
        { name: 'name', type: 'string' },
        { name: 'version', type: 'string' },
        { name: 'chainId', type: 'uint256' },
        { name: 'verifyingContract', type: 'address' },
      ],
      SetSpender: [
        { name: 'owner', type: 'address' },
        { name: 'spender', type: 'address' },
        { name: 'nonce', type: 'uint256' },
        { name: 'deadline', type: 'uint256' },
      ],
    },
    primaryType: 'SetSpender',
    // HypowMinter's DOMAIN_SEPARATOR.
    domain: { name: 'HypowMinter', version: '5', chainId: c.net.chainId, verifyingContract: c.net.minter },
    message: { owner, spender, nonce: nonce.toString(), deadline: deadline.toString() },
  };
  const sig = (await provider.request({ method: 'eth_signTypedData_v4', params: [owner, JSON.stringify(typed)] })) as Hex;
  // The minter takes v as 27 or 28; some hardware wallets return 0 or 1.
  const v = parseInt(sig.slice(-2), 16);
  return v < 27 ? `${sig.slice(0, -2)}${(v + 27).toString(16)}` as Hex : sig;
}
