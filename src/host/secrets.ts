// The Secrets file: `secrets.yaml`, sops-encrypted to your age key, committed.
// It holds the Credential and nothing else (ADR-0005). The Host decrypts it at
// launch and keeps the Credential in memory; it is never written anywhere else.

// An `sk-ant-` API key or an OAuth token from `claude setup-token`.
export type CredentialKind = "apiKey" | "oauthToken";

export interface Credential {
  kind: CredentialKind;
  value: string;
}

export interface ReadCredentialOptions {
  /** The Secrets file to decrypt. Defaults to the one at the tree's root. */
  secretsFile?: string;
  /** An age key file for sops, for tests that carry their own. */
  ageKeyFile?: string;
}

// `secrets.yaml` sits at the root of the tree this Host was launched from, so a
// Preview reads its own Worktree's copy (ADR-0008). Resolving from the module
// finds it whatever the cwd; under `deno desktop` the module can load out of a
// compiled bundle whose path is not on disk, and then the cwd is what is left.
function defaultSecretsFile(): string {
  const beside = new URL("../../secrets.yaml", import.meta.url).pathname;
  try {
    Deno.statSync(beside);
    return beside;
  } catch {
    return `${Deno.cwd()}/secrets.yaml`;
  }
}

// The field the Secrets file holds the Credential under.
const FIELD = "credential";

// Both kinds start `sk-ant-`: an API key is `sk-ant-api…` and a token from
// `claude setup-token` is `sk-ant-oat…`. Only the API key's own prefix decides,
// so a token is never sent as an API key and rejected upstream.
function credentialKind(value: string): CredentialKind {
  return value.startsWith("sk-ant-api") ? "apiKey" : "oauthToken";
}

export async function readCredential(options: ReadCredentialOptions = {}): Promise<Credential> {
  const secretsFile = options.secretsFile ?? defaultSecretsFile();

  let output: Deno.CommandOutput;
  try {
    output = await new Deno.Command("sops", {
      args: ["-d", "--output-type", "json", secretsFile],
      env: options.ageKeyFile ? { SOPS_AGE_KEY_FILE: options.ageKeyFile } : {},
      stdout: "piped",
      stderr: "piped",
    }).output();
  } catch (cause) {
    throw new Error(
      `could not run sops to decrypt ${secretsFile}: ${
        cause instanceof Error ? cause.message : String(cause)
      }`,
      { cause },
    );
  }

  if (!output.success) {
    const stderr = new TextDecoder().decode(output.stderr).trim();
    throw new Error(`sops could not decrypt ${secretsFile}: ${stderr}`);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(output.stdout));
  } catch {
    throw new Error(`${secretsFile} decrypted to something that is not JSON`);
  }

  const value = (parsed as Record<string, unknown> | null)?.[FIELD];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${secretsFile} has no non-empty "${FIELD}" field holding the Credential`);
  }

  return { kind: credentialKind(value), value };
}
