import { BaseError } from 'viem';
import { rateLimited } from '../src/endpoint.ts';
import { describe } from '../src/text.ts';

/** A failed wallet request as one log line. */
export function walletError(err: unknown): string {
  const code = (err as { code?: number } | null)?.code;
  if (code === 4001) return 'declined in the wallet';
  if (code === -32002) return 'the wallet already has a request open · check its window';
  // Wallets reject with plain EIP-1193 errors; a viem error comes from the page's own reads instead.
  if (!(err instanceof BaseError) && rateLimited(err)) {
    return "your wallet's HyperEVM RPC is rate-limited · try again, or pick another RPC in your wallet's network settings";
  }
  return describe(err);
}
