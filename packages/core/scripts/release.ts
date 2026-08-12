/**
 * Cut a pre-release. `bun run release <feature-slug>`.
 *
 * The one command a night's work ends with. Everything it decides is in
 * `packages/core/release.ts` and everything it writes is in
 * `packages/core/release-cut.ts`; what is left here is the two things that can
 * only be known by being run — which tree this is, and how to build a frontend.
 *
 * The slug names the run: `.scratch/<slug>/issues` is where the tickets are, and
 * their landed ones are what the changelog entry and the announcement are made
 * from. There is no default, because a release that guessed which queue it was
 * releasing would be a release that announced the wrong night's work.
 *
 * **It does not switch what is served.** The developer's window goes on running
 * whatever it was running; the pre-release is written, recorded and tagged, and
 * promoting it is ticket 08's band and the developer's decision.
 */

import { join } from 'node:path'
import { cloneRootOfScript } from '../dev-server.ts'
import { cutPreRelease } from '../release-cut.ts'

/**
 * The three answers, as exit codes, matching `landing-cli.ts`.
 *
 * `0` cut, `1` refused, `2` could not answer — and the middle one is the
 * distinction worth keeping. A night where every ticket was parked is a real
 * night and a refusal this made on purpose; a build that would not compile is
 * the world failing underneath it. An orchestrator that saw one code for both
 * would either retry a refusal for ever or report a broken toolchain as a quiet
 * evening.
 */
const CUT = 0
const REFUSED = 1
const COULD_NOT = 2

const USAGE = 'usage: bun run release <feature-slug>   (the run to release, as in .scratch/<feature-slug>/issues)'

const cloneRoot = cloneRootOfScript(import.meta.url)
const slug = process.argv[2] ?? ''

if (slug === '' || slug.startsWith('-') || slug.includes('/')) {
  console.error(USAGE)
  process.exit(COULD_NOT)
}

const outcome = await cutPreRelease({
  cloneRoot,
  issuesDirectory: join(cloneRoot, '.scratch', slug, 'issues'),
  now: () => new Date(),
  /*
    The same spawn `scripts/build.ts` makes, and deliberately not a call into
    that file: `bun run build` installs its artifact as `local` and then points
    `served` at it, which is exactly right for a developer who asked for this
    tree now and exactly wrong for a release cut while they are asleep. What is
    shared between the two is the part that must not be written twice — the
    install — and that is `installArtifact`.
  */
  build: async (root) => {
    const built = Bun.spawn(['bun', 'run', '--filter', '@varnick/core', 'build'], {
      cwd: root,
      stdio: ['inherit', 'inherit', 'inherit'],
    })
    const code = await built.exited
    return {
      ok: code === 0,
      distDirectory: join(root, 'packages/core/dist'),
      reason: code === 0 ? undefined : `vite exited ${code}`,
    }
  },
})

if (!outcome.cut) {
  console.error(`nothing cut: ${outcome.reason}`)
  // `kind` rather than a prefix of `reason`: the sentence is prose and would
  // change the exit code the next time somebody rewords it.
  process.exit(outcome.kind === 'environment' ? COULD_NOT : REFUSED)
}

console.log(`\n${outcome.record.announcement}`)
console.log(`artifact ${outcome.record.artifact} written to ${outcome.artifact}, and not served`)
console.log(`tagged ${outcome.record.tag}`)
process.exit(CUT)
