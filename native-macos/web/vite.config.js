import { defineConfig } from 'vite'

export default defineConfig({
  base: './',
  plugins: [{
    name: 'offline-webkit-bundle',
    apply: 'build',
    transformIndexHtml: {
      order: 'post',
      // file:// resources cannot use module/CORS loading in WKWebView.
      handler: html => html
        .replace(/\s+type="module"/g, ' defer')
        .replace(/\s+crossorigin(?:="[^"]*")?/g, ''),
    },
  }],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    assetsDir: 'assets',
    modulePreload: false,
    rollupOptions: {
      output: { format: 'iife', inlineDynamicImports: true },
    },
  },
})
