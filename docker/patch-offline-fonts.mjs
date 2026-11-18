// Remove @nuxt/fonts from the UI modules for offline/local builds.
//
// @nuxt/fonts fetches fonts.google.com metadata during `nuxt generate`.
// Networks that block Google Fonts cannot complete the build. The dashboard
// already has a system-font fallback in main.css, so skipping the module is
// safe for the all-in-one image.
//
// This script runs inside the builder stage before `pnpm install`, so the
// generated Nuxt types and the production bundle both omit the module.

import { readFileSync, writeFileSync } from 'node:fs'

const configPath = 'packages/ui/nuxt.config.ts'
const source = readFileSync(configPath, 'utf8')

const patched = source.replace(
  /\n[ \t]*'@nuxt\/fonts',[ \t]*(?=\n)/,
  '\n',
)

if (patched === source) {
  console.error(
    '[offline-fonts] could not find the @nuxt/fonts module entry in nuxt.config.ts',
  )
  process.exit(1)
}

writeFileSync(configPath, patched)
console.log('[offline-fonts] disabled @nuxt/fonts for this build')
