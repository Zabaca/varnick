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

use tauri::Manager;

/// Stop everything this process started.
///
/// **Not `Drop`, because `Drop` never runs.** All four managed values have a
/// `Drop` that kills their children, and one of them says in its own comment
/// that "varnick exiting must not leave a sandboxed agent tree behind it" — an
/// intention nothing honoured. On macOS the event loop ends in `process::exit`,
/// which unwinds nothing, so managed state is dropped on no path at all: not on
/// ⌘Q, not on a signal, not on a crash. Fifteen orphaned harness processes were
/// measured on a developer's machine, the oldest five and a half hours old,
/// several still holding live Claude Code processes.
///
/// Idempotent, because it is called from two places that can both happen: the
/// run callback below, and the signal watcher.
fn shut_down(app: &tauri::AppHandle) {
    // The agent first. It is the tree that matters — a sandboxed Claude Code
    // process with a credential in its environment — and `stop` is a SIGKILL to
    // its whole process group, which is the only thing that ends it: the group
    // is deliberately its own (see agent.rs), so a signal to varnick's group
    // never reaches it.
    let _ = app.state::<agent::AgentProcess>().stop();
    // Then the runtime, which holds the Sandbox and whatever srt started under
    // it. Its own children go when it does — see the parent-death watch in
    // packages/harness/src/serve.ts, which is what covers the exits no handler
    // can see.
    app.state::<bridge::HarnessRuntime>().shut_down();
}

/// Take down the tree when the operating system asks us to stop.
///
/// `SIGTERM` is what `kill` sends and what most tooling sends, and it is the
/// exit this app took most often during development — every restart left a
/// runtime and an agent behind.
///
/// The handler itself does nothing but set a flag, which is the whole of what
/// is async-signal-safe: no allocation, no locks, no Tauri. A thread waits on
/// the flag and does the work, then exits the process itself, because a signal
/// that is handled no longer ends anything on its own.
#[cfg(unix)]
fn watch_for_signals(app: tauri::AppHandle) {
    use std::sync::atomic::{AtomicBool, Ordering};

    static ASKED: AtomicBool = AtomicBool::new(false);

    extern "C" fn note(_signal: libc::c_int) {
        ASKED.store(true, Ordering::SeqCst);
    }

    // SAFETY: `note` touches one atomic and nothing else, which is the rule for
    // a signal handler. `SIG_DFL` is restored by the process ending.
    unsafe {
        // Through a pointer rather than straight to an integer: a function
        // item is not a value, and the direct cast is a warning in this
        // edition rather than a shorthand.
        let handler = note as *const () as libc::sighandler_t;
        libc::signal(libc::SIGTERM, handler);
        libc::signal(libc::SIGINT, handler);
        libc::signal(libc::SIGHUP, handler);
    }

    std::thread::spawn(move || loop {
        if ASKED.load(Ordering::SeqCst) {
            shut_down(&app);
            // 128 + SIGTERM, the shell's convention for "ended by a signal".
            // Reported rather than exiting 0, so a supervisor can still tell a
            // deliberate stop from a clean finish.
            std::process::exit(143);
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    });
}

#[cfg(not(unix))]
fn watch_for_signals(_app: tauri::AppHandle) {}

/// Where every rendering is, as a menu id.
///
/// Three renderings ship (CLAUDE.md: the bare page and the states page are
/// product code, not scaffolding) and until ticket 41 two of them were
/// unreachable. `#/bare` and `#/states` each render a nav; `#/designed` renders
/// none and is where the window opens — so the pages that could navigate were
/// the two nobody could get to.
///
/// The hash rather than a navigation: `App.tsx` listens for `hashchange`, so
/// switching costs no reload and loses no state. The route strings are
/// duplicated from there, which is the one thing to keep an eye on — a route
/// renamed in Core and not here is a menu item that goes nowhere. Cheap to
/// notice, and the alternative is Rust reading a TypeScript constant.
const ROUTES: [(&str, &str, &str, &str); 3] = [
    ("route-designed", "Chat", "#/designed", "CmdOrCtrl+1"),
    ("route-bare", "Bare", "#/bare", "CmdOrCtrl+2"),
    ("route-states", "States", "#/states", "CmdOrCtrl+3"),
];

/// The window's own controls: reload the page, restart the app, and go to a
/// rendering.
///
/// **Reload and Restart are two different repairs and the labels must not blur
/// them.** A reload restarts the renderer only — the runtime channel and the
/// agent process are managed state in *this* process and survive it untouched,
/// so it fixes a stuck window and does nothing for a stuck host. Restart is the
/// one that replaces everything, and it is only reasonable to offer because the
/// agent now resumes its conversation (ticket 33).
///
/// A native menu rather than a key handler in the webview, and that is the
/// point: the case you need this in most is a window that is not answering, and
/// a renderer that cannot paint cannot handle a keystroke either. It is also
/// why the route switcher lives here rather than as a nav bar on the chat —
/// a route switcher on the designed rendering would put developer chrome in the
/// product, and the whole argument for three renderings is that the designed
/// one is the app rather than a demo of itself.
///
/// Added to the default menu rather than replacing it. ⌘Q, Copy and Paste all
/// come from the default, and building a menu from scratch would silently drop
/// them.
fn install_menu(app: &tauri::AppHandle) -> tauri::Result<()> {
    use tauri::menu::{MenuItemBuilder, PredefinedMenuItem, SubmenuBuilder};

    let menu = tauri::menu::Menu::default(app)?;
    let mut view = SubmenuBuilder::new(app, "View")
        .item(
            &MenuItemBuilder::with_id("reload", "Reload")
                .accelerator("CmdOrCtrl+R")
                .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id("restart", "Restart varnick")
                .accelerator("Shift+CmdOrCtrl+R")
                .build(app)?,
        )
        .item(&PredefinedMenuItem::separator(app)?);
    for (id, label, _, accelerator) in ROUTES {
        view = view.item(
            &MenuItemBuilder::with_id(id, label)
                .accelerator(accelerator)
                .build(app)?,
        );
    }
    let view = view.build()?;
    menu.append(&view)?;
    app.set_menu(menu)?;
    Ok(())
}

/// The route a menu id means, or `None` for an id that is not one.
///
/// Split out so the lookup is a unit test rather than a `match` arm nobody can
/// reach without a window — the same reason `route_of` in bridge.rs is its own
/// function.
fn route_for(id: &str) -> Option<&'static str> {
    ROUTES
        .iter()
        .find(|(menu_id, _, _, _)| *menu_id == id)
        .map(|(_, _, route, _)| *route)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        // One command for the whole Harness — see bridge.rs. The credential and
        // everything downstream of it are answered here: storing one, minting
        // one, the agent process it is injected into, and the Turns that ride
        // that process's Session. What is forwarded to the Harness runtime is
        // what needs the Sandbox or a filesystem — the sandbox check and both
        // directions of the Session mirror. `route_of` is where that split is
        // decided, and it is a unit test rather than a convention.
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
        .setup(|app| {
            install_menu(app.handle())?;
            watch_for_signals(app.handle().clone());
            Ok(())
        })
        .on_menu_event(|app, event| match event.id().as_ref() {
            // The renderer, from the top. Rust-side state is untouched — see
            // install_menu.
            "reload" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.eval("window.location.reload()");
                }
            }
            // Everything, from the top. The teardown runs first: `restart`
            // replaces this process image, and anything still alive at that
            // moment is orphaned by it.
            "restart" => {
                shut_down(app);
                app.restart();
            }
            // A rendering. Nothing is torn down and nothing reloads: the hash
            // is what `App.tsx` routes on, so the window changes page with its
            // machines still running.
            id => {
                if let Some(route) = route_for(id) {
                    if let Some(window) = app.get_webview_window("main") {
                        // `route` comes from the constant above and never from
                        // anything the window said, so there is no string here
                        // a caller could put something else in.
                        let _ = window.eval(format!("window.location.hash = '{route}'"));
                    }
                }
            }
        })
        // `build` rather than `run`, for the callback below. It is the only
        // place an exit can be observed at all.
        .build(tauri::generate_context!())
        .expect("error while building varnick");

    app.run(|app, event| {
        if matches!(event, tauri::RunEvent::Exit) {
            shut_down(app);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_rendering_the_window_ships_has_a_way_in() {
        // The defect this closes: two of the three renderings were product code
        // with no route to them. Asserted by route rather than by count, so
        // dropping one from the menu fails here instead of quietly shipping a
        // page nobody can open again.
        assert_eq!(route_for("route-designed"), Some("#/designed"));
        assert_eq!(route_for("route-bare"), Some("#/bare"));
        assert_eq!(route_for("route-states"), Some("#/states"));
    }

    #[test]
    fn a_menu_id_that_is_not_a_rendering_is_not_one() {
        // The route arm is the fall-through of `on_menu_event`, so every id the
        // menu has that is *not* a route reaches it. It has to say no rather
        // than guess — a default menu item that navigated the window would be a
        // Copy that changed the page.
        assert_eq!(route_for("reload"), None);
        assert_eq!(route_for("restart"), None);
        assert_eq!(route_for(""), None);
    }

    #[test]
    fn no_route_can_carry_anything_but_a_hash() {
        // The route is interpolated into a line of JavaScript. It comes from
        // the constant above and never from the window, and this is what keeps
        // that true if someone adds a fourth: a route with a quote in it would
        // end the string literal.
        for (_, _, route, _) in ROUTES {
            assert!(route.starts_with("#/"), "{route} is not a hash route");
            assert!(!route.contains('\''), "{route} could close the literal");
            assert!(!route.contains('\\'), "{route} could escape the literal");
        }
    }
}
