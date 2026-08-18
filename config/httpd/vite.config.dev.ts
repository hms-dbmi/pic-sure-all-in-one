// Vite dev server config overlay for all-in-one compose.
// Mounted into the frontend container at dev time to enable HMR
// with API proxying to the gateway/psama on the Docker network.

import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig, type PluginOption } from 'vite';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig(async () => {
  const plugins: PluginOption[] = [tailwindcss(), sveltekit()];
  const { svelteTesting } = await import('@testing-library/svelte/vite');
  plugins.push(svelteTesting());

  return {
    server: {
      host: '0.0.0.0',
      port: 3000,
      strictPort: true,
      watch: {
        usePolling: true, // needed for Docker volume mounts
        interval: 1000,
      },
      proxy: {
        '/picsure/': {
          // Prefix stripped: the gateway's routes are /operations, /hpds, etc.
          target: 'http://gateway:8080',
          rewrite: (path: string) => path.replace(/^\/picsure/, ''),
        },
        '/psama': {
          target: 'http://psama:8090',
          rewrite: (path: string) => path.replace(/^\/psama/, '/auth'),
        },
      },
    },
    plugins,
    build: {
      rollupOptions: {
        maxParallelFileOps: 10,
      },
      sourcemap: true,
    },
  };
});
