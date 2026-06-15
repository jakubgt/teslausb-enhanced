import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Static SPA served by nginx on the Pi at "/". Relative base so assets resolve
// regardless of mount path. The heavy multi-cam Viewer is lazy-loaded (see
// App.tsx) so the dashboard loads fast on low-power clients.
export default defineConfig({
  base: '/',
  plugins: [react()],
  build: {
    outDir: 'dist',
    target: 'es2019',
    chunkSizeWarningLimit: 2000,
    rollupOptions: {
      output: {
        manualChunks: {
          cloudscape: ['@cloudscape-design/components', '@cloudscape-design/global-styles'],
          react: ['react', 'react-dom', 'react-router-dom'],
        },
      },
    },
  },
});
