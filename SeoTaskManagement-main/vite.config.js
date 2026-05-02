import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "dist",
    sourcemap: false,
    // Use esbuild for minification to avoid requiring an extra terser dependency
    // (Vercel environment may not have terser installed). esbuild is faster
    // and the default for Vite.
    minify: "esbuild"
  },
  server: {
    port: 5173,
    strictPort: false
  }
});
