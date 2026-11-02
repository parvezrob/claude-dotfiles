import { expect, mock, test } from 'claude-code/testing'

const SEED_OUT = '{"main":{"in":10,"out":20,"cr":30,"cw":40,"req":2},"sub":null,"files":1}\n'

type Usage = { input_tokens: number; output_tokens: number; cache_read_input_tokens: number; cache_creation_input_tokens: number; model: string }
const usage = (out: number): Usage => ({ input_tokens: 5, output_tokens: out, cache_read_input_tokens: 100, cache_creation_input_tokens: 7, model: 'claude-test' })

// Engine stubs every test shares; `files` stands for the disk.
function engine(on: any, files: Map<string, string>, opts: { failWrites?: boolean } = {}) {
  const sessionId = 'sid-1'
  const clock = mock.clock(on, { now: 1_000 })
  mock.env(on, { HOME: '/h' })
  const runs: string[][] = []
  on('session.start', () => ({ cwd: '/work' }))
  on('session.end', ($: any, e: any) => ({ sessionId: e.sessionId }))
  on('session.id', () => ({ value: sessionId }))
  on('fs.read', ($: any, e: any) => (files.has(e.path) ? { value: files.get(e.path) } : { deny: 'ENOENT' }))
  on('fs.write', ($: any, e: any) => {
    if (opts.failWrites) return { deny: 'disk full' }
    files.set(e.path, e.text)
    return { value: undefined }
  })
  on('process.run', ($: any, e: any) => {
    runs.push([...e.argv])
    return { value: { exitCode: 0, stdout: SEED_OUT, stderr: '' } }
  })
  return { clock, runs }
}

async function step($: any, out: number, agentId?: string) {
  const s = $.turn.step({ turnId: 't', index: 0, model: 'claude-test', messageCount: 1, ...(agentId ? { agentId } : {}) })
  let r = await s.next()
  while (r.done !== true) r = await s.next()
  return r.value
}

test('counts main and subagent requests into the ledger, seeds once, debounces writes', async ($, on) => {
  const files = new Map<string, string>()
  const { clock, runs } = engine(on, files)
  // The model's answers, in order.
  const outs = [usage(300), usage(50), usage(900)]
  on('turn.step', async function* () {
    return { turnId: 't', index: 0, answer: 'ok', toolUses: [], stopReason: 'end_turn', usage: outs.shift() ?? null }
  })

  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await step($, 0)
  await step($, 0, 'agent-1')
  await step($, 0)
  // Nothing is written inside a request: only after the debounce.
  expect(files.size).toBe(0)
  await clock.advance(2_000)
  await clock.settle()

  const ledger = JSON.parse(files.get('/h/.claude/token-ledger/sid-1.json')!)
  expect(ledger.sessionId).toBe('sid-1')
  expect(ledger.live.main).toEqual({ in: 10, out: 1200, cr: 200, cw: 14, req: 2 })
  expect(ledger.live.sub).toEqual({ in: 5, out: 50, cr: 100, cw: 7, req: 1 })
  expect(ledger.recent).toEqual([300, 900])
  expect(ledger.model).toBe('claude-test')
  // The seed ran once, with the cutoff of when counting began, and landed.
  expect(runs.length).toBe(1)
  expect(runs[0]!.slice(-3)).toEqual(['/h/.claude', 'sid-1', new Date(1_000).toISOString()])
  expect(ledger.seed.state).toBe('done')
  expect(ledger.seed.main).toEqual({ in: 10, out: 20, cr: 30, cw: 40, req: 2 })

  // A later write keeps the seed and does not run it again.
  outs.push(usage(1))
  await step($, 0)
  await clock.advance(2_000)
  await clock.settle()
  expect(runs.length).toBe(1)
  expect(JSON.parse(files.get('/h/.claude/token-ledger/sid-1.json')!).live.main.req).toBe(3)
})

test('a reload continues an existing ledger instead of starting over or re-seeding', async ($, on) => {
  const files = new Map<string, string>()
  const prior = {
    v: 1, sessionId: 'sid-1', since: 500, updatedAt: 900,
    live: { main: { in: 1, out: 2, cr: 3, cw: 4, req: 1 }, sub: { in: 0, out: 0, cr: 0, cw: 0, req: 0 } },
    seed: { state: 'done', at: 600, main: null, sub: null }, recent: [2],
  }
  files.set('/h/.claude/token-ledger/sid-1.json', JSON.stringify(prior))
  const { clock, runs } = engine(on, files)
  on('turn.step', async function* () {
    return { turnId: 't', index: 0, answer: 'ok', toolUses: [], stopReason: 'end_turn', usage: usage(10) }
  })

  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await step($, 0)
  await clock.advance(2_000)
  await clock.settle()

  const ledger = JSON.parse(files.get('/h/.claude/token-ledger/sid-1.json')!)
  expect(ledger.since).toBe(500)
  expect(ledger.live.main).toEqual({ in: 6, out: 12, cr: 103, cw: 11, req: 2 })
  expect(ledger.recent).toEqual([2, 10])
  expect(runs.length).toBe(0)
})

test('a failed write or a missing usage never breaks the request', async ($, on) => {
  const files = new Map<string, string>()
  const { clock } = engine(on, files, { failWrites: true })
  on('turn.step', async function* () {
    return { turnId: 't', index: 0, answer: 'fine', toolUses: [], stopReason: 'end_turn', usage: null }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  const r = await step($, 0)
  expect(r.answer).toBe('fine')
  await clock.advance(2_000)
  await clock.settle()
  expect(files.size).toBe(0)
})

test('records the last main request time and the session cwd; subagent requests leave the time alone', async ($, on) => {
  const files = new Map<string, string>()
  const { clock } = engine(on, files)
  on('turn.step', async function* () {
    return { turnId: 't', index: 0, answer: 'ok', toolUses: [], stopReason: 'end_turn', usage: usage(10) }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work/custom-all' })
  await clock.advance(5_000)
  await step($, 0) // main at 6_000
  await clock.advance(3_000)
  await step($, 0, 'agent-1') // sub at 9_000
  await clock.advance(2_000)
  await clock.settle()
  const ledger = JSON.parse(files.get('/h/.claude/token-ledger/sid-1.json')!)
  expect(ledger.lastMainRequestAt).toBe(6_000)
  expect(ledger.cwd).toBe('/work/custom-all')
})
