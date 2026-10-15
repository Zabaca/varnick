import Foundation
import TaskHarness
import WebKit

// The Task pane's page bridge (option 01 of tasks-cant-be-handed-to-varnick): reading and acting in the pane's web view, and peeking at links,
// all as scripts in an isolated content world of the web view's own, so the page's scripts can't see or change them. Nothing is posted to
// the system or the window and no app is brought forward.

/// The scripts of a Task pane. Which fields are secret is `SecretField`'s rule (ADR 0039); the page script applies it before anything leaves the
/// page, and sends a secret field's state (filled or not), never its value.
enum TaskScript {
    static let world = WKContentWorld.world(name: "varnick-task")
    static let handlerName = "varnickTask"

    /// In every frame: the person's own clicks and keys pause the task, wherever in the page they are made. Trusted events only, so the harness's
    /// own script clicks never count.
    static let touchSource = #"""
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.varnickTask.postMessage(m) } catch (e) {} };
      for (const type of ['pointerdown', 'keydown']) addEventListener(type, (e) => { if (e.isTrusted) post({ touched: type }) }, true);
    })();
    """#

    /// In the main frame, in the page's own world: while the harness fills fields, a form's `submit()` and `requestSubmit()` do nothing but mark
    /// the form as held (an isolated world's changes to the built-ins are invisible to the page, so this one has to be the page's). The lock is
    /// an attribute the harness's world sets on the document element.
    static let guardSource = #"""
    (() => {
      for (const name of ['submit', 'requestSubmit']) {
        const original = HTMLFormElement.prototype[name];
        Object.defineProperty(HTMLFormElement.prototype, name, {
          configurable: true, writable: true,
          value: function (...args) {
            if (document.documentElement && document.documentElement.hasAttribute('data-varnick-task-lock')) { this.setAttribute('data-varnick-task-held', name); return }
            return original.apply(this, args);
          },
        });
      }
    })();
    """#

    /// In the main frame, in the harness's world: the snapshot, the acts and the peek.
    static let source = #"""
    (() => {
      if (window.__vt) return;
      // Every element gets an id once, for as long as the document lives, so a field a form reveals moves no other: positions would shift.
      const ids = new WeakMap();
      const token = Math.random().toString(36).slice(2, 6);
      let counter = 0;
      const idOf = (el, prefix) => { let id = ids.get(el); if (!id) { id = prefix + (++counter) + '.' + token; ids.set(el, id) } return id };
      let els = {};

      // A field that is a password stays one if the page turns it into a text box, or swaps it for another input (a "show password" button).
      const everPassword = new WeakSet(), secretNames = new Set(), secretIds = new Set(), secretParents = new WeakSet();
      const markSecret = (el) => { everPassword.add(el); if (el.name) secretNames.add(el.name); if (el.id) secretIds.add(el.id) };
      new MutationObserver((records) => {
        for (const r of records) {
          if (r.type === 'attributes' && (r.oldValue || '').toLowerCase() === 'password' && r.target.tagName === 'INPUT') markSecret(r.target);
          for (const n of r.removedNodes) {
            if (n.nodeType !== 1) continue;
            for (const i of (n.tagName === 'INPUT' ? [n] : n.querySelectorAll('input'))) {
              if (i.type === 'password' || everPassword.has(i)) { markSecret(i); if (r.target.nodeType === 1) secretParents.add(r.target) }
            }
          }
          for (const n of r.addedNodes) {
            if (n.nodeType !== 1 || !secretParents.has(r.target)) continue;
            for (const i of (n.tagName === 'INPUT' ? [n] : n.querySelectorAll('input'))) markSecret(i);
          }
        }
      }).observe(document, { attributes: true, attributeOldValue: true, attributeFilter: ['type'], childList: true, subtree: true });

      // A submit the page makes as a field is filled (its own onchange handler) is held: see guardSource for `submit()`.
      addEventListener('submit', (e) => {
        if (document.documentElement.hasAttribute('data-varnick-task-lock')) {
          e.preventDefault(); e.stopImmediatePropagation();
          if (e.target.setAttribute) e.target.setAttribute('data-varnick-task-held', 'submit');
        }
      }, true);

      const text = (el) => ((el.innerText !== undefined ? el.innerText : el.textContent) || '').replace(/\s+/g, ' ').trim();
      const visible = (el) => {
        if (!el.getClientRects().length) return false;
        const s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none';
      };
      const regionOf = (el) => el.closest('header,[role=banner]') ? 'banner' : el.closest('footer,[role=contentinfo]') ? 'contentinfo'
        : el.closest('nav,[role=navigation]') ? 'navigation' : 'main';

      // A search box is a form with role search, a search element, or a form whose only text field is a search input. A form with a search input
      // among other fields (a checkout with an address lookup) is not one: its submit asks.
      const textFields = (form) => [...form.querySelectorAll('input, textarea')].filter((i) => !['hidden', 'submit', 'button', 'reset', 'image', 'checkbox', 'radio', 'file', 'range', 'color'].includes((i.type || '').toLowerCase()));
      const searchForm = (form) => !!form && (form.matches('[role=search]') || !!form.closest('search, [role=search]') || (() => { const t = textFields(form); return t.length === 1 && t[0].type === 'search' })());
      const inSearch = (el) => !!el.closest('[role=search], search') || searchForm(el.form);

      const autocompleteOf = (el) => (el.getAttribute('autocomplete') || '').toLowerCase();
      const isSecret = (el) => {
        if (el.type === 'password') markSecret(el);
        if (autocompleteOf(el).split(/\s+/).some((t) => t === 'current-password' || t === 'new-password' || t === 'one-time-code' || t.startsWith('cc-'))) markSecret(el);
        return everPassword.has(el) || (!!el.name && secretNames.has(el.name)) || (!!el.id && secretIds.has(el.id));
      };
      const labelOf = (el) => {
        if (el.labels && el.labels.length) return text(el.labels[0]);
        const aria = el.getAttribute('aria-label');
        if (aria) return aria;
        const by = el.getAttribute('aria-labelledby');
        if (by) { const t = by.split(/\s+/).map((i) => document.getElementById(i)).filter(Boolean).map(text).join(' '); if (t) return t }
        return el.getAttribute('placeholder') || el.name || el.id || '';
      };
      const errorOf = (el) => {
        let t = '';
        const d = el.getAttribute('aria-describedby') || el.getAttribute('aria-errormessage');
        if (el.getAttribute('aria-invalid') === 'true' && d) t = d.split(/\s+/).map((i) => (document.getElementById(i) || {}).textContent || '').join(' ');
        if (!t) { try { if (el.matches(':user-invalid')) t = el.validationMessage } catch (e) {} }
        t = t.replace(/\s+/g, ' ').trim();
        return t || null;
      };
      const nearby = (el) => { const p = el.closest('p, fieldset, li'); return p ? text(p).slice(0, 120) : '' };
      const blocks = 'p, li, h1, h2, h3, h4, h5, h6, td, th, dd, dt, blockquote, figcaption, pre, [role=alert], [role=status]';

      const snapshot = () => {
        els = {};
        const out = { address: location.href.split('#')[0], title: document.title, links: [], buttons: [], fields: [], texts: [] };
        for (const a of document.querySelectorAll('a[href], a[role=button]')) {
          if (out.links.length >= 300) break;
          const raw = a.getAttribute('href') || '';
          if (/^(mailto|tel):/i.test(raw) || !visible(a)) continue;
          // A link with no address to go to (#, javascript:, a button in a link's clothes) is listed, and asks: its click does what the page's script says.
          const noAddress = !raw || raw.startsWith('#') || /^javascript:/i.test(raw) || a.getAttribute('role') === 'button';
          let u = null;
          if (!noAddress) { try { u = new URL(a.href) } catch (e) { continue } }
          const label = text(a) || a.getAttribute('aria-label') || a.title || ((a.querySelector('img') || {}).alt) || '';
          const id = idOf(a, 'l'); els[id] = a;
          out.links.push({ id, label, href: u ? u.href.split('#')[0] : '', inBody: regionOf(a) === 'main', sameSite: !!u && u.origin === location.origin,
                           isSelf: !!u && u.href.split('#')[0] === location.href.split('#')[0], navigates: !noAddress });
        }
        for (const b of document.querySelectorAll('button, input[type=submit], input[type=button], input[type=image], [role=button]:not(a)')) {
          if (!visible(b)) continue;
          const isInput = b.tagName === 'INPUT';
          const label = (isInput ? b.value : text(b)) || b.getAttribute('aria-label') || b.title || '';
          const kind = (b.getAttribute('type') || (b.tagName === 'BUTTON' ? 'submit' : '')).toLowerCase();
          const submits = !!b.form && (kind === 'submit' || kind === 'image');
          const id = idOf(b, 'b'); els[id] = b;
          out.buttons.push({ id, label, submits, isSearch: inSearch(b) });
        }
        const seenRadio = new Set();
        for (const el of document.querySelectorAll('input, select, textarea')) {
          const t = (el.type || el.tagName).toLowerCase();
          if (['hidden', 'submit', 'button', 'reset', 'image'].includes(t) || !visible(el)) continue;
          const secret = isSecret(el);
          const base = { name: el.name || '', placeholder: el.getAttribute('placeholder') || '', autocomplete: autocompleteOf(el), nearby: nearby(el),
                         required: el.required, error: errorOf(el), wasPassword: secret, isSearch: inSearch(el) };
          if (t === 'radio') {
            if (!el.name || seenRadio.has(el.name)) continue;
            seenRadio.add(el.name);
            const group = [...document.querySelectorAll('input[type=radio]')].filter((r) => r.name === el.name && (r.form || null) === (el.form || null));
            const fs = el.closest('fieldset'); const legend = fs && fs.querySelector('legend');
            const id = idOf(group[0], 'f'); els[id] = group;
            const checked = group.find((r) => r.checked);
            out.fields.push({ ...base, id, label: legend ? text(legend) : el.name, type: 'radio', options: group.map(labelOf), value: checked ? labelOf(checked) : '', required: true });
            continue;
          }
          const id = idOf(el, 'f'); els[id] = el;
          if (secret) { out.fields.push({ ...base, id, label: labelOf(el), type: t, filled: el.value.length > 0 }); continue }
          if (t === 'checkbox') { out.fields.push({ ...base, id, label: labelOf(el), type: t, checked: el.checked }); continue }
          if (el.tagName === 'SELECT') {
            const options = [...el.options];
            const shown = options.filter((o, i) => !(i === 0 && o.value === '')).map(text);
            out.fields.push({ ...base, id, label: labelOf(el), type: 'select', options: shown, value: el.value === '' ? '' : text(el.options[el.selectedIndex]) });
            continue;
          }
          out.fields.push({ ...base, id, label: labelOf(el), type: t === 'textarea' ? 'textarea' : t, value: el.value });
        }
        let k = 0;
        for (const el of document.querySelectorAll(blocks)) {
          if (k >= 150) break;
          if (el.querySelector(blocks) || el.querySelector('input, select, textarea, button') || !visible(el)) continue;
          const t = text(el);
          if (!t) continue;
          out.texts.push({ id: 't' + (++k), text: t.slice(0, 500), region: regionOf(el) });
        }
        return JSON.stringify(out);
      };

      const nativeSet = (el, value) => {
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
      };
      const events = (el) => {
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        el.dispatchEvent(new FocusEvent('focusout', { bubbles: true }));
        el.dispatchEvent(new FocusEvent('blur'));
      };
      const fill = (id, value) => {
        const el = els[id];
        if (!el) throw new Error('no such field');
        const first = Array.isArray(el) ? el[0] : el;
        if (isSecret(first)) throw new Error('a secret field is only ever the person\'s');
        if (Array.isArray(el)) {
          const wanted = el.find((r) => labelOf(r) === value);
          if (!wanted) throw new Error('no such option');
          wanted.click();
        } else if (el.type === 'checkbox') {
          if (el.checked !== (value === 'true')) el.click();
        } else if (el.tagName === 'SELECT') {
          const option = [...el.options].find((o) => text(o) === value);
          if (!option) throw new Error('no such option');
          nativeSet(el, option.value); events(el);
        } else {
          nativeSet(el, value); events(el);
        }
      };
      const settle = (quiet, max) => new Promise((resolve) => {
        let timer;
        const done = () => { obs.disconnect(); resolve(true) };
        const obs = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(done, quiet) });
        obs.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
        timer = setTimeout(done, quiet);
        setTimeout(done, max);
      });

      window.__vt = {
        snapshot,
        click(id) {
          const el = els[id];
          if (!el) throw new Error('no such element');
          if (el.tagName === 'A' && el.target && el.target !== '_self') el.target = '_self';
          el.click();
        },
        // Fills one field with the document's submits locked: a submit the page makes meanwhile is held, and the result says whether one was.
        async fill(id, value, quiet) {
          document.querySelectorAll('[data-varnick-task-held]').forEach((f) => f.removeAttribute('data-varnick-task-held'));
          document.documentElement.setAttribute('data-varnick-task-lock', '1');
          try { fill(id, value); await settle(quiet, 2500) } finally { document.documentElement.removeAttribute('data-varnick-task-lock') }
          return !!document.querySelector('[data-varnick-task-held]');
        },
        // Lets the held submit through, once the person has allowed it.
        releaseHeld() {
          const form = document.querySelector('[data-varnick-task-held]');
          if (!form) return false;
          form.removeAttribute('data-varnick-task-held');
          form.requestSubmit();
          return true;
        },
        mark(needle) {
          const want = needle.replace(/\s+/g, ' ').trim().slice(0, 500);
          for (const el of document.querySelectorAll(blocks)) {
            if (el.querySelector(blocks) || text(el).slice(0, 500) !== want) continue;
            el.style.outline = '2px solid #f5a623'; el.style.background = 'rgba(245, 166, 35, 0.25)';
            el.scrollIntoView({ block: 'center' });
            return true;
          }
          return false;
        },
        settle,
        async peek(hrefs) {
          const out = new Array(hrefs.length).fill(null);
          let next = 0;
          const one = async (i) => {
            try {
              const u = new URL(hrefs[i], location.href);
              if (u.origin !== location.origin) return;
              const c = new AbortController(); const timer = setTimeout(() => c.abort(), 6000);
              const r = await fetch(u.href, { credentials: 'same-origin', signal: c.signal });
              const body = await r.text(); clearTimeout(timer);
              const doc = new DOMParser().parseFromString(body, 'text/html');
              doc.querySelectorAll('script, style, noscript, input[type=password]').forEach((x) => x.remove());
              const main = doc.querySelector('main') || doc.body;
              const clean = (x) => (x.textContent || '').replace(/\s+/g, ' ').trim();
              const lines = [...main.querySelectorAll('h1, h2, p, li')].filter((x) => !x.querySelector('h1, h2, p, li')).map(clean).filter(Boolean).slice(0, 6);
              const links = [...main.querySelectorAll('a')].map(clean).filter(Boolean).slice(0, 10);
              out[i] = { title: doc.title, lines, links };
            } catch (e) {}
          };
          // Six at a time on one site.
          await Promise.all(Array.from({ length: Math.min(6, hrefs.length) }, async () => { while (next < hrefs.length) await one(next++) }));
          return JSON.stringify(out);
        },
      };
    })();
    """#
}

enum TaskPageError: Error, LocalizedError {
    case script(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .script(let m): m
        case .unreadable: "the page could not be read"
        }
    }
}

/// Receives the person's clicks and keys in the page (trusted events only).
final class TaskTouchHandler: NSObject, WKScriptMessageHandler {
    var onTouch: @MainActor () -> Void = {}

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in self.onTouch() }
    }
}

/// The Task pane's page for the harness: `TaskPage` over its web view.
@MainActor
final class TaskWebPage: TaskPage {
    private let web: WKWebView

    /// Installs the scripts and the handler in `configuration`, before its web view is made.
    static func install(in configuration: WKWebViewConfiguration, touch: TaskTouchHandler) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: TaskScript.touchSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: TaskScript.world))
        controller.addUserScript(WKUserScript(source: TaskScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: TaskScript.world))
        controller.addUserScript(WKUserScript(source: TaskScript.guardSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.add(touch, contentWorld: TaskScript.world, name: TaskScript.handlerName)
    }

    init(web: WKWebView) { self.web = web }

    private func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        do {
            return try await web.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: TaskScript.world)
        } catch {
            throw TaskPageError.script(error.localizedDescription)
        }
    }

    /// The loads that are under way have finished and, with `quiet`, the page has made no change for that many milliseconds (at most 2.5 s): an
    /// act is followed by one, a plain read by none.
    private func settle(waitingForNavigation: Bool, quiet: Int? = nil) async {
        if waitingForNavigation { try? await Task.sleep(for: .milliseconds(150)) }
        let began = Date()
        while web.isLoading, Date().timeIntervalSince(began) < 12, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        if let quiet { _ = try? await call("return await window.__vt.settle(quiet, 2500)", ["quiet": quiet]) }
    }

    private struct Snapshot: Decodable {
        struct Link: Decodable { var id: String; var label: String; var href: String; var inBody: Bool; var sameSite: Bool; var isSelf: Bool; var navigates: Bool }
        struct Button: Decodable { var id: String; var label: String; var submits: Bool; var isSearch: Bool }
        struct Field: Decodable {
            var id: String; var label: String; var type: String; var name: String?; var placeholder: String?; var autocomplete: String?
            var nearby: String?; var required: Bool?; var options: [String]?; var value: String?; var checked: Bool?; var error: String?
            var wasPassword: Bool?; var filled: Bool?; var isSearch: Bool?
        }
        struct Text: Decodable { var id: String; var text: String; var region: String }
        var address: String; var title: String
        var links: [Link]; var buttons: [Button]; var fields: [Field]; var texts: [Text]
    }

    func snapshot() async throws -> PageSnapshot {
        await settle(waitingForNavigation: false)
        guard let json = try await call("return window.__vt.snapshot()") as? String, let data = json.data(using: .utf8),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { throw TaskPageError.unreadable }
        // A secret field arrives without its value; `PageField` drops one that did arrive.
        return PageSnapshot(
            address: Self.shown(s.address), title: s.title,
            links: s.links.map { PageLink(id: $0.id, label: $0.label, href: $0.href, inBody: $0.inBody, sameSite: $0.sameSite, isSelf: $0.isSelf, navigates: $0.navigates) },
            buttons: s.buttons.map { PageButton(id: $0.id, label: $0.label, submits: $0.submits, isSearch: $0.isSearch) },
            fields: s.fields.map {
                PageField(id: $0.id, label: $0.label, type: $0.type, name: $0.name ?? "", placeholder: $0.placeholder ?? "", autocomplete: $0.autocomplete ?? "",
                          nearby: $0.nearby ?? "", required: $0.required ?? false, options: $0.options ?? [], value: $0.value, checked: $0.checked,
                          error: $0.error, wasPassword: $0.wasPassword ?? false, filled: $0.filled, isSearch: $0.isSearch ?? false)
            },
            texts: s.texts.map { TextBlock(id: $0.id, text: $0.text, region: $0.region) })
    }

    /// How an address is shown in the steps and the trail: no scheme.
    private static func shown(_ address: String) -> String {
        address.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    func click(_ id: String) async throws {
        _ = try await call("window.__vt.click(id)", ["id": id])
        await settle(waitingForNavigation: true, quiet: 250)
    }

    func fill(field id: String, value: String) async throws -> Bool {
        let held = try await call("return await window.__vt.fill(id, value, 120)", ["id": id, "value": value]) as? Bool ?? false
        await settle(waitingForNavigation: false)
        return held
    }

    func releaseBlockedSubmit() async throws {
        _ = try await call("return window.__vt.releaseHeld()")
        await settle(waitingForNavigation: true, quiet: 250)
    }

    func mark(_ text: String) async {
        _ = try? await call("return window.__vt.mark(text)", ["text": text])
    }

    func goBack() async throws {
        guard web.canGoBack else { return }
        web.goBack()
        await settle(waitingForNavigation: true, quiet: 250)
    }

    func open(_ href: String) async throws {
        guard let url = URL(string: href), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw TaskPageError.unreadable }
        web.load(URLRequest(url: url))
        await settle(waitingForNavigation: true, quiet: 250)
    }

    func peek(_ hrefs: [String]) async -> [LinkPreview?] {
        guard !hrefs.isEmpty, let json = try? await call("return await window.__vt.peek(hrefs)", ["hrefs": hrefs]) as? String,
              let data = json.data(using: .utf8), let items = JSON.parse(data)?.items else { return hrefs.map { _ in nil } }
        return items.map { item in
            guard let title = item["title"]?.string else { return nil }
            return LinkPreview(title: title, lines: item["lines"]?.items?.compactMap(\.string) ?? [], links: item["links"]?.items?.compactMap(\.string) ?? [])
        }
    }
}
