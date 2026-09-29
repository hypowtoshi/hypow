import { describe, type Line } from '../src/text.ts';

/** A slash command: typed as /name, or picked from the menu an empty prompt opens. */
export type Command = { name: string; desc: string; run: () => Promise<void> };

export type Terminal = {
  line: Line;
  clear: () => void;
  /**
   * Print a picker into the log: ↑↓ or j/k move, enter or a number picks, esc
   * cancels. Resolves to the picked index, or -1 when cancelled. Once answered
   * it collapses to one line, as a typed answer would.
   */
  choose: (title: string, options: string[]) => Promise<number>;
  /** Whether a picker is on screen. */
  picking: () => boolean;
  /** Close the picker on screen, if any, unanswered, noting `why` in its place. */
  cancel: (why: string) => void;
  /**
   * Show `prompt ›` and hand what is typed to `onEnter`, except /commands, which
   * run from `commands`, suggested as they are typed. The answer is echoed into
   * the log as `shown` makes it, for answers that carry a secret.
   */
  ask: (prompt: string, onEnter: (value: string) => Promise<void>, commands: Command[], shown?: (value: string) => string) => void;
  /** The picker of `commands`, then the picked one run. */
  menu: (commands: Command[]) => Promise<void>;
  /** Run `fn` with the prompt ignoring enter meanwhile; a failure becomes an error line. */
  exclusive: (fn: () => Promise<void>) => Promise<void>;
  /** A block set apart from the log lines, to close it: a title over a few sentences. */
  note: (title: string, text: string[]) => void;
};

/** Labels that must stand out, as the CLI colors them; every other label is dim. */
const TONES: Record<string, string> = {
  captured: 'good',
  ticket: 'info',
  error: 'bad',
  lost: 'bad',
  missed: 'bad',
  'gas low': 'warn',
  subaccounts: 'warn',
  pooled: 'warn',
  'no wallet': 'warn',
};
const MAX_LINES = 500;

export function el<T extends HTMLElement>(id: string): T {
  const e = document.getElementById(id);
  if (!e) throw new Error(`hypow miner: the page has no #${id}`);
  return e as T;
}

export function span(className: string, text: string): HTMLSpanElement {
  const s = document.createElement('span');
  s.className = className;
  s.textContent = text;
  return s;
}

const now = () => new Date().toTimeString().slice(0, 8);
const commandLabel = (c: Command) => `/${c.name.padEnd(8)} ${c.desc}`;

/**
 * The miner's terminal, in elements the page provides: #miner-log (the log),
 * #miner-suggest (slash suggestions), #miner-line holding #miner-prompt and
 * #miner-input (the prompt).
 */
export function terminal(): Terminal {
  const log = el('miner-log');
  const suggest = el('miner-suggest');
  const promptLine = el('miner-line');
  const promptLabel = el('miner-prompt');
  const input = el<HTMLInputElement>('miner-input');

  // The log follows new lines, and keeps following through resizes, unless the
  // user has scrolled up to read.
  let following = true;
  const follow = () => {
    if (following) log.scrollTop = log.scrollHeight;
  };
  log.addEventListener('scroll', () => {
    following = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
  });
  new ResizeObserver(follow).observe(log);

  const append = (node: HTMLElement) => {
    log.append(node);
    while (log.childElementCount > MAX_LINES) log.firstElementChild!.remove();
    follow();
  };

  /** A log row laid out like the CLI's: time, label, message, detail after " · " dimmed. */
  const row = (label: string, message: string, tone: string | undefined) => {
    const r = document.createElement('div');
    r.className = 'row';
    if (tone) r.dataset.tone = tone;
    const cut = message.indexOf(' · ');
    const text = span('message', cut < 0 ? message : message.slice(0, cut));
    if (cut >= 0) text.append(span('dim', message.slice(cut)));
    r.append(span('time', now()), span('label', label), text);
    return r;
  };
  /** A block found, a warning the user should act on (⚠, the CLI's red line), or the label's tone. */
  const tone = (label: string, message: string) =>
    label.startsWith('BLOCK') ? 'win' : label.startsWith('⚠') || message.startsWith('⚠') ? 'alarm' : TONES[label];
  const line: Line = (label, message) => append(row(label, message, tone(label, message)));
  /** What the user answered, echoed into the log. */
  const echo = (label: string, answer: string) => append(row(label, answer, 'cmd'));

  let picker: { items: HTMLButtonElement[]; i: number; done: (i: number, why?: string) => void } | undefined;
  const paint = () => picker!.items.forEach((b, k) => b.setAttribute('aria-selected', String(k === picker!.i)));

  const choose = (title: string, options: string[]) =>
    new Promise<number>((resolve) => {
      const box = document.createElement('div');
      box.className = 'menu';
      box.setAttribute('role', 'listbox');
      box.setAttribute('aria-label', title);
      box.append(span('t', title));
      const items = options.map((label, k) => {
        const b = document.createElement('button');
        b.type = 'button';
        b.setAttribute('role', 'option');
        b.textContent = `${k + 1}. ${label}`;
        b.addEventListener('mouseenter', () => {
          picker!.i = k;
          paint();
        });
        b.addEventListener('click', () => picker?.done(k));
        return b;
      });
      box.append(...items, span('hint', '↑↓ to move · enter to pick · esc to cancel'));
      append(box);
      promptLine.hidden = true;
      input.blur();
      picker = {
        items,
        i: 0,
        done: (k, why = 'cancelled') => {
          picker = undefined;
          const answer = row('', `${title} › ${k < 0 ? why : options[k]}`, 'cmd');
          box.replaceWith(answer);
          promptLine.hidden = false;
          input.focus({ preventScroll: true });
          resolve(k);
        },
      };
      paint();
    });

  document.addEventListener('keydown', (e) => {
    // Keys belong to the picker only while it is on screen and not typing in the prompt.
    if (!picker || e.target === input || log.offsetParent === null) return;
    const n = picker.items.length;
    if (e.key === 'ArrowDown' || e.key === 'j') picker.i = (picker.i + 1) % n;
    else if (e.key === 'ArrowUp' || e.key === 'k') picker.i = (picker.i - 1 + n) % n;
    else if (e.key === 'Enter') picker.done(picker.i);
    else if (e.key === 'Escape') picker.done(-1);
    else if (/^[1-9]$/.test(e.key) && Number(e.key) <= n) picker.done(Number(e.key) - 1);
    else return;
    e.preventDefault();
    if (picker) paint();
  });

  let step: { prompt: string; onEnter: (value: string) => Promise<void>; commands: Command[]; shown: (value: string) => string } | undefined;
  let busy = false;
  let suggestions: Command[] = [];
  let pick = 0;

  const run = async (fn: () => Promise<void>) => {
    busy = true;
    try {
      await fn();
    } catch (err) {
      line('error', describe(err));
    } finally {
      busy = false;
    }
  };
  const menu = async (commands: Command[]) => {
    const k = await choose('Commands', commands.map(commandLabel));
    if (k >= 0) await commands[k].run();
  };
  const command = async (typed: string, commands: Command[]) => {
    const c = commands.find((c) => c.name === typed.slice(1).toLowerCase());
    if (c) await c.run();
    else line('error', `unknown command ${typed} · type / for the list`);
  };

  const paintSuggestions = () => {
    const v = input.value;
    suggestions = step && v.startsWith('/') ? step.commands.filter((c) => c.name.startsWith(v.slice(1).toLowerCase())) : [];
    if (pick >= suggestions.length) pick = 0;
    suggest.hidden = suggestions.length === 0;
    suggest.replaceChildren(
      ...suggestions.map((c, k) => {
        const b = document.createElement('button');
        b.type = 'button';
        b.textContent = commandLabel(c);
        b.setAttribute('aria-selected', String(k === pick));
        // mousedown, so the input keeps focus and the click isn't lost to blur.
        b.addEventListener('mousedown', (e) => {
          e.preventDefault();
          input.value = '';
          paintSuggestions();
          echo(`${step!.prompt} ›`, `/${c.name}`);
          if (!busy) void run(c.run);
        });
        return b;
      }),
    );
  };
  input.addEventListener('input', () => {
    pick = 0;
    paintSuggestions();
  });

  input.addEventListener('keydown', (e) => {
    if (suggestions.length > 0) {
      const n = suggestions.length;
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        pick = (pick + (e.key === 'ArrowDown' ? 1 : n - 1)) % n;
        return paintSuggestions();
      }
      if (e.key === 'Tab') {
        e.preventDefault();
        input.value = `/${suggestions[pick].name}`;
        return paintSuggestions();
      }
      if (e.key === 'Escape') {
        input.value = '';
        return paintSuggestions();
      }
      if (e.key === 'Enter') input.value = `/${suggestions[pick].name}`;
    }
    if (e.key !== 'Enter' || busy || !step) return;
    e.preventDefault();
    const v = input.value.trim();
    input.value = '';
    paintSuggestions();
    if (v) echo(`${step.prompt} ›`, step.shown(v));
    const { onEnter, commands } = step;
    void run(() => (v.startsWith('/') && commands.length > 0 ? command(v, commands) : onEnter(v)));
  });

  // A click anywhere in the terminal types into the prompt, unless it selected text.
  log.parentElement!.addEventListener('click', () => {
    if (!picker && !getSelection()?.toString()) input.focus({ preventScroll: true });
  });

  return {
    line,
    clear: () => log.replaceChildren(),
    choose,
    picking: () => picker !== undefined,
    cancel: (why) => picker?.done(-1, why),
    menu,
    exclusive: run,
    note: (title, text) => {
      const box = document.createElement('div');
      box.className = 'note';
      box.append(
        span('t', title),
        ...text.map((sentence) => {
          const p = document.createElement('p');
          p.textContent = sentence;
          return p;
        }),
      );
      append(box);
    },
    ask: (prompt, onEnter, commands, shown = (v) => v) => {
      step = { prompt, onEnter, commands, shown };
      promptLabel.textContent = `${prompt} ›`;
      input.placeholder = commands.length > 0 ? 'enter for commands · / to type one' : 'press enter';
      paintSuggestions();
    },
  };
}
