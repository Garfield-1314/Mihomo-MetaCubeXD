// Patch the AIO server/UI so the first-run browser session receives the
// managed backend URL, the Clash API secret, and the control token.
//
// The dashboard is statically generated, but the AIO server serves a dynamic
// /config.js route. The UI also ships a static public/config.js placeholder;
// the image removes that placeholder after `nuxt generate` so this route is
// actually reachable.
//
// This patch intentionally fails the build if either source shape changes.

import { readFileSync, writeFileSync } from 'node:fs'

function replaceOnce(file, from, to) {
  const source = readFileSync(file, 'utf8')
  if (!source.includes(from)) {
    console.error(`[aio-config] pattern not found in ${file}`)
    process.exit(1)
  }
  const next = source.replace(from, to)
  writeFileSync(file, next)
  console.log(`[aio-config] patched ${file}`)
}

const serverConfig = 'apps/server/routes/config.js.ts'
replaceOnce(
  serverConfig,
  'const { controlToken, githubToken, defaultBackendURL } = serverEnv()',
  'const { controlToken, clashSecret, githubToken, defaultBackendURL } = serverEnv()',
)
replaceOnce(
  serverConfig,
  'const config: Record<string, unknown> = { defaultBackendURL }',
  [
    'const config: Record<string, unknown> = { defaultBackendURL }',
    '  if (clashSecret) config.defaultBackendSecret = clashSecret',
  ].join('\n'),
)

const useConnect = 'packages/ui/composables/useConnect.ts'

// Insert the secret reader after the defaultBackendURL computed block.
const secretReader = `
  // Injected by the AIO server's dynamic /config.js. Used only for the
  // automatic first-run probe; saved endpoints keep their own secret.
  const defaultBackendSecret = computed(() => {
    if (typeof window !== 'undefined') {
      return (window as any).__METACUBEXD_CONFIG__?.defaultBackendSecret || ''
    }
    return ''
  })
`
replaceOnce(
  useConnect,
  '  return FALLBACK_BACKEND_URL\n  })\n',
  '  return FALLBACK_BACKEND_URL\n  })\n' + secretReader,
)

replaceOnce(
  useConnect,
  "      formData.url = defaultBackendURL.value\n      formData.secret = ''",
  '      formData.url = defaultBackendURL.value\n      formData.secret = defaultBackendSecret.value',
)
