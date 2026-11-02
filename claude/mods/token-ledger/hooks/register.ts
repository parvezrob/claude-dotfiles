import type { Register } from 'claude-code'

// token-ledger: counts every model request's tokens (main conversation and
// subagents) as it finishes, and keeps them in a small per-session JSON file,
// <config>/token-ledger/<session-id>.json, that the status line reads instead
// of re-scanning the whole transcript. Writes are debounced; nothing here
// awaits inside a request, and every failure leaves the numbers out.

type Bucket = { in: number; out: number; cr: number; cw: number; req: number }
type Usage = {
  input_tokens: number
  output_tokens: number
  cache_read_input_tokens: number
  cache_creation_input_tokens: number
  model?: string
}
type Seed =
  | { state: 'pending' }
  | { state: 'running'; at: number }
  | { state: 'done'; at: number; main: Bucket | null; sub: Bucket | null }
  | { state: 'failed'; at: number; reason: string }
export type Ledger = {
  v: 1
  sessionId: string
  // Epoch ms from which this mod counts; the one-time seed sums what the
  // transcript recorded before it.
  since: number
  updatedAt: number
  live: { main: Bucket; sub: Bucket }
  seed: Seed
  // Output tokens of the latest main-conversation requests, oldest first.
  recent: number[]
  model?: string
  // Epoch ms of the latest main-conversation request: the cache countdown's start.
  lastMainRequestAt?: number
  // The session's working directory, so other tools can name the session.
  cwd?: string
}

const RECENT = 16
const FLUSH_MS = 2_000
const SEED_STALE_MS = 15 * 60_000
const SEED_TIMEOUT_MS = 10 * 60_000

const zero = (): Bucket => ({ in: 0, out: 0, cr: 0, cw: 0, req: 0 })
const n = (x: unknown): number => (typeof x === 'number' && Number.isFinite(x) && x > 0 ? x : 0)

export function addUsage(b: Bucket, u: Usage): void {
  b.in += n(u.input_tokens)
  b.out += n(u.output_tokens)
  b.cr += n(u.cache_read_input_tokens)
  b.cw += n(u.cache_creation_input_tokens)
  b.req += 1
}

function addBucket(into: Bucket, from: Bucket): void {
  into.in += from.in
  into.out += from.out
  into.cr += from.cr
  into.cw += from.cw
  into.req += from.req
}

function isBucket(x: unknown): x is Bucket {
  const b = x as Bucket
  return !!b && typeof b === 'object' && ['in', 'out', 'cr', 'cw', 'req'].every(k => typeof (b as any)[k] === 'number')
}

export function parseLedger(text: string, sessionId: string): Ledger | undefined {
  try {
    const l = JSON.parse(text) as Ledger
    const ok =
      l && l.v === 1 && l.sessionId === sessionId && typeof l.since === 'number' &&
      isBucket(l.live?.main) && isBucket(l.live?.sub) && Array.isArray(l.recent) &&
      l.seed && typeof l.seed.state === 'string'
    return ok ? l : undefined
  } catch {
    return undefined
  }
}

export function parseSeed(stdout: string): { main: Bucket | null; sub: Bucket | null } | undefined {
  try {
    const s = JSON.parse(stdout.trim())
    const main = isBucket(s?.main) ? s.main : null
    const sub = isBucket(s?.sub) ? s.sub : null
    return { main, sub }
  } catch {
    return undefined
  }
}

type Pending = { main: Bucket; sub: Bucket; recent: number[]; model?: string; lastMainAt?: number }

export const freshPending = (): Pending => ({ main: zero(), sub: zero(), recent: [] })

export function countStep(p: Pending, u: Usage, isSubagent: boolean): void {
  if (isSubagent) return addUsage(p.sub, u)
  addUsage(p.main, u)
  p.recent.push(n(u.output_tokens))
  if (p.recent.length > RECENT) p.recent.shift()
  if (u.model) p.model = u.model
}

function mergePending(a: Pending, b: Pending): Pending {
  addBucket(a.main, b.main)
  addBucket(a.sub, b.sub)
  const lastMainAt = Math.max(a.lastMainAt ?? 0, b.lastMainAt ?? 0) || undefined
  return { main: a.main, sub: a.sub, recent: [...a.recent, ...b.recent].slice(-RECENT), model: b.model ?? a.model, lastMainAt }
}

export function foldInto(l: Ledger, p: Pending): void {
  addBucket(l.live.main, p.main)
  addBucket(l.live.sub, p.sub)
  if (p.recent.length) l.recent = [...l.recent, ...p.recent].slice(-RECENT)
  if (p.model) l.model = p.model
  if (p.lastMainAt && p.lastMainAt > (l.lastMainRequestAt ?? 0)) l.lastMainRequestAt = p.lastMainAt
}

export const newLedger = (sessionId: string, since: number): Ledger => ({
  v: 1,
  sessionId,
  since,
  updatedAt: since,
  live: { main: zero(), sub: zero() },
  seed: { state: 'pending' },
  recent: [],
})

// A seed runs once: again only when a run was left 'running' long ago (its
// process went away mid-run).
export function needsSeed(s: Seed, now: number): boolean {
  if (s.state === 'pending') return true
  return s.state === 'running' && now - s.at >= SEED_STALE_MS
}

export const register: Register = on => {
  // Set by session.start: they close over its `$` (a hook's `$` is never
  // passed around), so timers and the other hooks reach the engine through them.
  let kick: (() => void) | undefined // schedule a debounced write
  let flushNow: (() => Promise<void>) | undefined // write now (session end)

  let ledger: Ledger | undefined
  // Counted since the last write, not yet folded into `ledger`.
  let pending = freshPending()
  let pendingSince = 0 // when the current uncommitted session started counting
  let sessionCwd: string | undefined

  on('session.start', async ($, e, next) => {
    try {
      pendingSince = await $.clock.now()
      sessionCwd = e.cwd
      const home = await $.env.get('HOME')
      const conf = await $.env.get('CLAUDE_CONFIG_DIR')
      const cfg = conf || (home ? `${home}/.claude` : undefined)
      if (!cfg) return next(e)
      const dir = `${cfg}/token-ledger`
      const seedScript = `${$.plugin.root}/bin/seed.sh`
      const fileOf = (id: string) => `${dir}/${id}.json`
      let timer: { cancel(): void } | undefined
      let isFlushing = false
      let isSeeding = false

      const open = async (id: string): Promise<Ledger> => {
        const text = await $.fs.read(fileOf(id)).catch(() => undefined)
        const found = text === undefined ? undefined : parseLedger(text, id)
        if (found) return found
        return newLedger(id, pendingSince || (await $.clock.now()))
      }

      const write = async (l: Ledger): Promise<void> => {
        l.updatedAt = await $.clock.now()
        await $.fs.write(fileOf(l.sessionId), JSON.stringify(l) + '\n')
      }

      // One run per session: sums what the transcript holds from before `since`.
      const maybeSeed = (l: Ledger): void => {
        if (isSeeding || !needsSeed(l.seed, l.updatedAt)) return
        isSeeding = true
        l.seed = { state: 'running', at: l.updatedAt }
        const id = l.sessionId
        const argv = ['/usr/bin/nice', '-n', '15', '/bin/sh', seedScript, cfg, id, new Date(l.since).toISOString()]
        $.clock.after(0, async () => {
          let seed: Seed
          try {
            const r = await $.process.run(argv, { timeoutMs: SEED_TIMEOUT_MS })
            const parsed = r.exitCode === 0 ? parseSeed(r.stdout) : undefined
            seed = parsed
              ? { state: 'done', at: await $.clock.now(), ...parsed }
              : { state: 'failed', at: await $.clock.now(), reason: `exit ${r.exitCode}` }
          } catch (err) {
            seed = { state: 'failed', at: 0, reason: String(err).slice(0, 200) }
          }
          isSeeding = false
          if (ledger && ledger.sessionId === id) {
            ledger.seed = seed
            await write(ledger).catch(() => undefined)
          }
        })
      }

      const flush = async (): Promise<void> => {
        timer = undefined
        if (isFlushing) return kick?.()
        isFlushing = true
        const p = pending
        pending = freshPending()
        try {
          const id = await $.session.id()
          if (!ledger || ledger.sessionId !== id) {
            try {
              ledger = await open(id)
            } catch {
              pending = mergePending(p, pending) // keep the counts for the next try
              return
            }
          }
          foldInto(ledger, p)
          if (sessionCwd) ledger.cwd = sessionCwd
          await write(ledger)
          maybeSeed(ledger)
        } catch {
          // Fail closed: the in-memory ledger keeps the counts; the next write retries.
        } finally {
          isFlushing = false
        }
      }

      kick = () => {
        if (timer) return
        timer = $.clock.after(FLUSH_MS, () => {
          void flush()
        })
      }
      flushNow = async () => {
        timer?.cancel()
        await flush()
      }
      // Open (or create) the ledger now, so the status line has it before the
      // first request and a resumed session gets its seed.
      kick()
    } catch {
      kick = undefined
      flushNow = undefined
    }
    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    const result = yield* next(e)
    try {
      const u = result?.usage
      if (u) {
        countStep(pending, u, e.agentId !== undefined)
        if (e.agentId === undefined) pending.lastMainAt = await $.clock.now()
        kick?.()
      }
    } catch {
      // Counting never touches the request.
    }
    return result
  })

  on('session.end', async ($, e, next) => {
    try {
      await flushNow?.()
      // After /clear or /resume the process goes on under another id.
      ledger = undefined
      pendingSince = await $.clock.now()
    } catch {
      // ignore
    }
    return next(e)
  })
}
