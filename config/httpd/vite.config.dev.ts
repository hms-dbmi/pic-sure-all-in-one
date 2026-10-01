// Extend the checked-out frontend config instead of replacing its plugins,
// tests and build policy. Verified against frontend 0b727304 (Node 24.19.0).
import { defineConfig, mergeConfig } from 'vite';
import upstream from './vite.config';

export default defineConfig(async (env) => {
  const base = typeof upstream === 'function' ? await upstream(env) : await upstream;
  // The upstream development proxies target its mock API, not this AIO stack.
  if (base.server) delete base.server.proxy;
  return mergeConfig(base, {
    plugins: [{
      name: 'aio-docs-visibility',
      configureServer(server) {
        server.middlewares.use((req, res, next) => {
          if (process.env.GATEWAY_DOCS_ENABLED === 'true') return next();
          let path: string;
          try {
            path = decodeURIComponent((req.url || '/').split('?')[0]).replace(/\/+/g, '/');
          } catch {
            res.statusCode = 400;
            res.end();
            return;
          }
          if (/^\/picsure\/(openapi|swagger-ui)(\/|$)/.test(path) ||
              /^\/psama\/v3\/api-docs(\.yaml)?(\/|$)/.test(path)) {
            res.statusCode = 404;
            res.end();
            return;
          }
          next();
        });
      },
    }],
    server: {
      host: '0.0.0.0',
      port: 3000,
      strictPort: true,
      watch: { usePolling: true, interval: 1000 },
      proxy: {
        '^/+picsure(?:/|$)': {
          target: 'http://gateway:8080',
          rewrite: (path: string) => path.replace(/^\/+picsure/, ''),
        },
        '^/+psama(?:/|$)': {
          target: 'http://psama:8090',
          rewrite: (path: string) => path.replace(/^\/+psama/, '/auth'),
        },
      },
    },
  });
});
