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
  /** The Secrets file to decrypt. Defaults to `secrets.yaml` beside the clone. */
  secretsFile?: string;
  /** An age key file for sops, for tests that carry their own. */
  ageKeyFile?: string;
}

// The field the Secrets file holds the Credential under.
const FIELD = "credential";

export function credentialKind(value: string): CredentialKind {
  return value.startsWith("sk-ant-") ? "apiKey" : "oauthToken";
}

export async function readCredential(options: ReadCredentialOptions = {}): Promise<Credential> {
  const secretsFile = options.secretsFile ?? `${Deno.cwd()}/secrets.yaml`;

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
