// Run from a frontend checkout with installed dependencies and the AIO wrapper
// copied to vite.config.aio.ts. Does not start a server or contact the backend.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
const require = createRequire(`${process.cwd()}/package.json`);
const { resolveConfig } = await import(pathToFileURL(require.resolve('vite')));
const config = await resolveConfig({ configFile: 'vite.config.aio.ts' }, 'serve');
assert.equal(config.server.port, 3000);
assert.equal(config.server.proxy['^/+picsure(?:/|$)'].target, 'http://gateway:8080');
assert.equal(config.server.proxy['^/+picsure(?:/|$)'].rewrite('/picsure/operations'), '/operations');
assert.equal(config.server.proxy['^/+psama(?:/|$)'].rewrite('/psama/config'), '/auth/config');
for (const [path, target, rewritten] of [
  ['//picsure/operations', 'http://gateway:8080', '/operations'],
  ['//psama/config', 'http://psama:8090', '/auth/config'],
]) {
  const key = Object.keys(config.server.proxy).find((key) => new RegExp(key).test(path));
  assert.ok(key, path);
  assert.equal(config.server.proxy[key].target, target);
  assert.equal(config.server.proxy[key].rewrite(path), rewritten);
}
assert.ok(!Object.keys(config.server.proxy).some((key) => new RegExp(key).test('/picsureX')));
assert.ok(config.test.setupFiles.includes('./tests/component/setup.ts'));
assert.equal(config.build.sourcemap, false);
const plugin = config.plugins.find((p) => p.name === 'aio-docs-visibility');
let middleware;
plugin.configureServer({ middlewares: { use: (m) => { middleware = m; } } });
const docs = ['/picsure/openapi', '/picsure/openapi/swagger-config',
  '/picsure/swagger-ui/index.html', '/psama/v3/api-docs.yaml',
  '//psama//v3/api-docs', '/psama/v3/%61pi-docs?group=x'];
for (const enabled of ['true', 'false']) {
  process.env.GATEWAY_DOCS_ENABLED = enabled;
  for (const url of [...docs, '/picsure/operations', '/psama/config']) {
    let next = false;
    let ended = false;
    const res = { end() { ended = true; } };
    middleware({ url }, res, () => { next = true; });
    const blocked = enabled === 'false' && docs.includes(url);
    assert.equal(next, !blocked, url);
    assert.equal(ended, blocked, url);
    if (blocked) assert.equal(res.statusCode, 404, url);
  }
}
console.log('AIO Vite upstream configuration, proxy and docs middleware tests passed.');
