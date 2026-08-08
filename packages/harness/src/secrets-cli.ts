// `bun run secret` — the whole of the Secrets Store's developer interface.
//
// The Secrets Store has no UI in v1 and no state machine (ticket 10); it is a
// Harness capability the agent reaches through the code it writes. That leaves a
// developer needing some way to put a key into it, and this is it.
//
// A value is read from stdin, never from argv. `/bin/ps` is not on the sandbox
// policy's denied list, so an agent that caught a value on another process's
// command line would have read a secret it is never meant to see — the same
// reason `securityKeychain` writes through `security -i`.

import {
  describeSecretsForAgent,
  openSecretsStore,
  SECRET_ADD_COMMAND,
  SECRET_REMOVE_COMMAND,
  SECRETS_KEYCHAIN_SERVICE,
  SecretsError,
  securityKeychain,
  type SecretsStore,
} from './secrets.ts'

const USAGE = `varnick secrets — keys the agent can name and never read.

  bun run secret list              the names, which is what the agent is given
  bun run secret brief             the exact text the agent is handed
  ${SECRET_ADD_COMMAND}        reads the value from stdin
  bun run secret rename <OLD> <NEW>
  ${SECRET_REMOVE_COMMAND}

Values are kept in the system keychain under the "${SECRETS_KEYCHAIN_SERVICE}"
service, one item per secret. The agent is told the names and never a value.

Measured rather than assumed: inside the Sandbox the login keychain is not in
the search list and its file cannot be opened, because it lives under the denied
home directory. Note what that does *not* say — the Sandbox does not stop the
agent running /usr/bin/security, and denying a binary's bytes never stopped it
running. See packages/harness/src/sandbox.boundary.test.ts and ADR-0003.`

/**
 * Read the value.
 *
 * Piped in, it is whatever arrived, with one trailing newline removed — so
 * `echo` and a here-doc both work. Typed at a terminal, echo is suppressed:
 * a key on screen is a key in the scrollback of a session someone may be
 * sharing.
 */
async function readValue(name: string): Promise<string> {
  const stdin = process.stdin

  if (!stdin.isTTY) {
    let data = ''
    stdin.setEncoding('utf8')
    for await (const chunk of stdin) data += chunk
    return data.replace(/\r?\n$/, '')
  }

  process.stdout.write(`Value for ${name} (not echoed, not stored in shell history): `)
  return new Promise<string>((resolve, reject) => {
    let typed = ''
    stdin.setRawMode(true)
    stdin.setEncoding('utf8')
    stdin.resume()

    const finish = (settle: () => void) => {
      stdin.setRawMode(false)
      stdin.pause()
      stdin.off('data', onData)
      process.stdout.write('\n')
      settle()
    }

    // Raw mode means nothing is interpreted for us — not the signal, not the
    // backspace. Named rather than written as literal control characters,
    // which would be invisible in a diff.
    const END_OF_TEXT = String.fromCharCode(3)
    const END_OF_TRANSMISSION = String.fromCharCode(4)
    const DELETE = String.fromCharCode(127)

    const onData = (chunk: string) => {
      for (const character of chunk) {
        if (character === '\r' || character === '\n') return finish(() => resolve(typed))
        if (character === END_OF_TEXT || character === END_OF_TRANSMISSION) {
          return finish(() => reject(new SecretsError('Cancelled. Nothing was stored.')))
        }
        if (character === DELETE || character === '\b') typed = typed.slice(0, -1)
        else typed += character
      }
    }

    stdin.on('data', onData)
  })
}

function oneName(rest: string[], shape: string): string {
  const [only] = rest
  if (rest.length !== 1 || only === undefined) {
    throw new SecretsError(`Usage: bun run secret ${shape}`)
  }
  return only
}

function twoNames(rest: string[], shape: string): [string, string] {
  const [first, second] = rest
  if (rest.length !== 2 || first === undefined || second === undefined) {
    throw new SecretsError(`Usage: bun run secret ${shape}`)
  }
  return [first, second]
}

async function main(argv: string[]): Promise<number> {
  const [command, ...rest] = argv

  if (command === undefined || command === 'help' || command === '--help') {
    process.stdout.write(`${USAGE}\n`)
    return command === undefined ? 1 : 0
  }

  let store: SecretsStore
  try {
    store = await openSecretsStore({ keychain: securityKeychain() })
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
    return 1
  }

  switch (command) {
    case 'list': {
      const names = store.names()
      if (names.length === 0) {
        process.stdout.write(`No secrets stored. Add one with \`${SECRET_ADD_COMMAND}\`.\n`)
        return 0
      }
      process.stdout.write(`${names.join('\n')}\n`)
      return 0
    }

    case 'brief': {
      process.stdout.write(`${describeSecretsForAgent(store.names())}\n`)
      return 0
    }

    case 'add': {
      const name = oneName(rest, 'add <NAME>')
      await store.store(name, await readValue(name))
      // The name, never the value, and never a length — a length is a clue.
      process.stdout.write(`Stored ${name}. The agent will be told the name only.\n`)
      return 0
    }

    case 'rename': {
      const [from, to] = twoNames(rest, 'rename <OLD> <NEW>')
      await store.rename(from, to)
      process.stdout.write(`Renamed ${from} to ${to}.\n`)
      return 0
    }

    case 'remove': {
      const name = oneName(rest, 'remove <NAME>')
      await store.remove(name)
      process.stdout.write(`Removed ${name}.\n`)
      return 0
    }

    default:
      process.stderr.write(`Not a secret command: ${command}\n\n${USAGE}\n`)
      return 1
  }
}

const code = await main(process.argv.slice(2)).catch((error: unknown) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  return 1
})
process.exit(code)
