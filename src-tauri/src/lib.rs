// The host process. Outside the sandbox by construction, which is what lets it
// hold the things the agent must never reach: the credential it reads from the
// system keychain and injects as an environment variable, and the Secrets Store
// it resolves when running code the agent wrote.
//
// See docs/adr/0003-containment-wraps-the-process-tree.md and
// docs/adr/0006-agents-author-secret-use-never-hold-secrets.md.

mod bridge;
mod credential;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // One command for the whole Harness — see bridge.rs. The credential is
        // answered in this process; everything else is forwarded to the Harness
        // runtime, which is the process that holds the Sandbox.
        .manage(credential::CredentialStore::default())
        .manage(bridge::HarnessRuntime::default())
        .invoke_handler(tauri::generate_handler![bridge::harness_call])
        .run(tauri::generate_context!())
        .expect("error while running varnick");
}
