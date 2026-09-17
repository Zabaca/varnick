# Actors live in the Host behind one Door

Every Machine's actor runs in the Host, once. The Host exposes one loopback HTTP API, the Door: post an Event, read a Snapshot, subscribe to Snapshots. The page renders Snapshots and sends Events through it; the agent in the Sandbox reaches it by a URL in its environment; a test drives it against a temp git repo with no window open. Deno Desktop's bindings and `executeJs` are not used, because a second door private to the page is exactly what would let the page know something an agent cannot.

This inverts the previous version, where the machines ran in the webview and the host was a service they called, which is why nothing but a click could drive it. The reason for the inversion is stated plainly: an agent should be able to drive varnick alongside you, and that requires the app's surface to be Events rather than clicks.

Consequences: `@xstate/react` is unnecessary; the page holds no machine. A Preview is a separate Host with its own Door, and a Session opened by a Preview drives that Preview.
