// The host process. Outside the sandbox by construction, which is what lets it
// hold the things the agent must never reach: the credential it reads from the
// system keychain and injects as an environment variable, and the Secrets Store
// it resolves when running code the agent wrote.
//
// See docs/adr/0003-containment-wraps-the-process-tree.md and
// docs/adr/0006-agents-author-secret-use-never-hold-secrets.md.

mod agent;
mod bridge;
mod credential;
mod mint;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // One command for the whole Harness — see bridge.rs. The credential and
        // everything downstream of it are answered here: storing one, minting
        // one, the agent process it is injected into, and the Turns, plan-usage
        // reads and Compactions that ride that process's Session. What is
        // forwarded to the Harness runtime is what needs the Sandbox or a
        // filesystem — the sandbox check and both directions of the Session
        // mirror. `route_of` is where that split is decided, and it is a unit
        // test rather than a convention.
        .manage(credential::CredentialStore::default())
        .manage(bridge::HarnessRuntime::default())
        // The agent process. Held here rather than in the runtime because the
        // spawn needs the credential, which never leaves this process.
        .manage(agent::AgentProcess::default())
        // Minting a subscription token, which is the other way a credential
        // comes into existence. Held here for the same reason storing one is:
        // the value goes from the command that printed it into the keychain
        // without leaving this process. See mint.rs.
        .manage(mint::Minting::default())
        .invoke_handler(tauri::generate_handler![bridge::harness_call])
        .run(tauri::generate_context!())
        .expect("error while running varnick");
}
