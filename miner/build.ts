/**
 * Build what the package runs, into dist/:
 * - the CLI, cli.js and its search-worker.js, as JavaScript, since Node won't
 *   strip types from files under node_modules, where an installed package lives;
 * - the browser miner, one self-contained script, hypow-miner.js, next to
 *   cli.html, the page the CLI serves it in to authorize its key. Its search
 *   worker is bundled first and inlined as text, since a page loading one
 *   script file has no second file to start a worker from. A copy goes next to
 *   the website, ../site/index.html, which loads it.
 */
import { copyFileSync, readFileSync } from 'node:fs';
import { build, type BuildOptions } from 'esbuild';

const at = (path: string) => new URL(path, import.meta.url).pathname;
const { version } = JSON.parse(readFileSync(at('./package.json'), 'utf8'));

const browser: BuildOptions = {
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: 'es2022',
  minify: true,
  // text.ts's DEBUG switch is a CLI environment variable; a page has none.
  define: { 'process.env.DEBUG': 'undefined' },
};

await build({
  bundle: true,
  format: 'esm',
  platform: 'node',
  target: 'node22',
  packages: 'external',
  entryPoints: [at('./src/cli.ts'), at('./src/search-worker.ts')],
  outdir: at('./dist'),
});

const worker = await build({ ...browser, entryPoints: [at('./web/search-worker.ts')], write: false });
await build({
  ...browser,
  entryPoints: [at('./web/main.ts')],
  outfile: at('./dist/hypow-miner.js'),
  define: {
    ...browser.define,
    SEARCH_WORKER: JSON.stringify(worker.outputFiles[0].text),
    VERSION: JSON.stringify(version),
  },
});
copyFileSync(at('./web/cli.html'), at('./dist/cli.html'));
copyFileSync(at('./dist/hypow-miner.js'), at('../site/hypow-miner.js'));
