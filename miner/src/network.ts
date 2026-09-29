import { parseEther, type Address } from 'viem';
import { count } from './text.ts';

export type Network = {
  name: string;
  chainId: number;
  minter: Address;
  deployBlock: bigint;
  /** Public endpoints in fallback order. */
  rpcs: string[];
  /** The public endpoint the authorize page gives a wallet that doesn't know the chain: the least rate-limited one. */
  walletRpc: string;
  /** RPCs that serve eth_getLogs ranges correctly (drpc rejects them). */
  logRpcs: string[];
  hyperliquidInfo: string;
  hyperliquidWs: string;
  /** HYPE the authorize page sends the miner key by default. */
  gasFund: bigint;
  /** Below this the key is treated as unfunded: roughly ten mining transactions. */
  minGas: bigint;
  /** Rough HYPE in fees for one ticket, played and cashed: what "about N tickets" is counted in. */
  ticketFee: bigint;
  /** Coins registered at setup, so a first trade in them counts in full. */
  starterCoins: string[];
};

/** What `gas` HYPE buys the miner key, in words. */
export function covers(net: Network, gas: bigint): string {
  return `it pays the fees for about ${count(gas / net.ticketFee)} tickets`;
}

export const MAINNET: Network = {
  name: 'HyperEVM mainnet',
  chainId: 999,
  minter: '0x14ae637542b6a125217ee477b756504ff009d506',
  deployBlock: 47234006n,
  rpcs: [
    'https://rpc.hyperliquid.xyz/evm',
    'https://hyperliquid-json-rpc.stakely.io',
    'https://rpc.hypurrscan.io',
    'https://hyperliquid.drpc.org',
  ],
  logRpcs: ['https://rpc.hyperliquid.xyz/evm', 'https://hyperliquid-json-rpc.stakely.io', 'https://rpc.hypurrscan.io'],
  walletRpc: 'https://rpc.hyperliquid.xyz/evm',
  hyperliquidInfo: 'https://api.hyperliquid.xyz/info',
  hyperliquidWs: 'wss://api.hyperliquid.xyz/ws',
  gasFund: parseEther('0.01'),
  minGas: parseEther('0.0005'),
  // Measured in the mainnet rehearsal at 0.1 gwei: spend ~77k gas plus cash ~264k is ~3.4e-5 HYPE. Rounded up.
  ticketFee: parseEther('0.00005'),
  starterCoins: ['BTC', 'ETH', 'SOL', 'HYPE'],
};
