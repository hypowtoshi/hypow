import { styleText } from 'node:util';

type Style = Parameters<typeof styleText>[0];

/** Labels that must stand out; every other label is dim. */
const LABEL_STYLES: Record<string, Style> = {
  captured: 'green',
  ticket: 'cyan',
  error: 'red',
  lost: 'red',
  missed: 'red',
  'gas low': 'yellow',
  subaccounts: 'yellow',
  pooled: 'yellow',
};
// Closest ANSI to the brand red-orange.
const BLOCK_STYLE: Style = ['bold', 'redBright'];
/** A warning the user should act on: its label, or its message, starts with ⚠. */
const ALARM_STYLE: Style = ['bold', 'red'];
const alarm = (label: string, message: string) => label.startsWith('⚠') || message.startsWith('⚠');

/** `text` in `style` when stdout is a color terminal (NO_COLOR and FORCE_COLOR respected), else as is. */
export function paint(style: Style, text: string): string {
  return styleText(style, text, { stream: process.stdout });
}

/**
 * One aligned terminal line: local time, a fixed-width label, then the message.
 * Whatever follows the message's first " · " is secondary detail and dimmed.
 * A block found, and a warning (⚠), are colored whole instead.
 */
export function format(label: string, message: string): string {
  const time = paint('dim', new Date().toTimeString().slice(0, 8));
  const padded = label.padEnd(11);
  if (label.startsWith('BLOCK')) return `${time}  ${paint(BLOCK_STYLE, `${padded} ${message}`)}`;
  if (alarm(label, message)) return `${time}  ${paint(ALARM_STYLE, `${padded} ${message}`)}`;
  const cut = message.indexOf(' · ');
  const body = cut < 0 ? message : `${message.slice(0, cut)}${paint('dim', message.slice(cut))}`;
  return `${time}  ${paint(LABEL_STYLES[label] ?? 'dim', padded)} ${body}`;
}

export function line(label: string, message: string): void {
  console.log(format(label, message));
}
