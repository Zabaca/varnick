# Test fixtures

`secrets.yaml` here is a Secrets file encrypted to `test-age-key.txt`, a
throwaway age key committed on purpose so `deno task test` needs no setup. Its
Credential is the literal `sk-ant-api03-test-fixture-not-a-real-key` and authenticates
nothing. The real Secrets file lives at the repo root and is encrypted to your
own key; see the README.
