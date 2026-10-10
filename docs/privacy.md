# Privacy

Varnick works on your own data, mostly on your Mac. This is everything it reads, records and sends.
The short version is in the [README](../README.md#privacy).

- **It reads the History of every Chrome profile** and copies it into a local archive that only grows,
  and mirrors every profile's bookmarks beside it.
- **It reads every Claude Code transcript under `~/.claude/projects`**, to list your sessions and make your
  prompts searchable, and keeps the last thing Claude wrote after each prompt (cut at 1,000 characters),
  which only the search by meaning reads.
- **Between Macs you have paired, it copies both your Claude prompts and your browsing history to the other
  Mac**, so that Recent and search find them there. The prompts come with each session's folder, title and
  agent, and with the last thing Claude wrote after each. The history is that Mac's whole archive: full page addresses, titles, the names of its Chrome
  profiles, visit counts and last visits, the terms you searched, and each page's description. The other
  Mac keeps what it copied until you remove the Mac from the peer list (or that Mac removes this one).
  Only pair a Mac you would show that history to.
- **It fetches the pages in your history**, one request each and without cookies, to read each page's own
  description, and stores the description. Those requests go to the sites you visited.
- **It records the microphone and the Mac's system audio while Listening is on,** and writes what it
  transcribes, on this Mac, to the day's transcript file.
- **Choosing TypeSafe is consent to send what a feature backed by it needs,** Varnick's own panel and the names
  of your sessions and projects included, and each new kind of data is listed here and in [`SECURITY.md`](../SECURITY.md). Keeping
  things private is the relevance filter's **On this Mac** setting: with it, or with the filter off, none of
  the TypeSafe sending below happens.
- **With a TypeSafe key and the relevance filter on TypeSafe,** it sends each search to TypeSafe's API
  with the title, site and page description of up to 20 results. It does not send full addresses or tags.
  The filter is off by default. With Hey Varnick on, it also sends TypeSafe's Jev the text you
  say after "Hey Varnick", to choose where to look, with no titles, names or results. Then the request is
  searched and filtered as a typed search is, so its search words and the title, site and page description
  of its first 20 pages go to TypeSafe too. This starts before you have quite finished, so if you go on
  speaking, words said so far may be sent and then discarded. With the filter On this Mac or off, nothing leaves.
- **With Point at the screen on** (Settings › Listening, off by default, and only available with the filter on
  TypeSafe and a key), a request that is about the screen also sends TypeSafe the title of the window in
  front and, for each of its first 255 elements, the label, kind and nearby text. That is the window's
  visible text, not only that near its controls: a message list's subjects and senders, an open mail's body in
  Mail, a page's text in Safari, a file's name in a tab, the account's name in a sidebar. The elements never
  hold what is typed in a field. None of this goes to a model server. With Varnick's panel open and in front,
  the panel is such a window too, and is read first: its session titles, folders, projects, Macs' names, page
  titles and problem titles go the same way. A terminal pane's text is not among them. If the elements don't have the thing,
  and Screen Recording is granted, a picture of the window alone is also read on this Mac, and its short
  lines of text (at most 6 words and 60 characters each, at most 150) go too, so more of the window's text
  leaves: every short line, such as a message list's subjects and senders or a chat's names. Lines inside a
  text field the elements find (a native one, or a web page's in Safari or an Electron app), and inside the field with focus, are dropped. But a field Varnick
  can't place is not: a Chrome page's, a canvas app's, a remote desktop's or a virtual machine's, one past
  the limits of the read, or one that moved before the picture was taken. So typed text of 6 words or
  fewer there may reach TypeSafe. The picture, the lines' positions and longer lines never leave the Mac.
- **With Screen access on** (Settings › Claude, off by default), the Claude sessions started or restarted
  after you turn it on can read the window in front, or one they name, and what they read goes to Anthropic
  with the session, and stays in its transcript on this Mac: the window's title, each of its first 255
  controls' label, kind and nearby text, which is the window's visible text, such as a message list's
  subjects and senders or a page's text in Safari, and, for a window that lists nothing or a Chrome page,
  its short lines of text read from a picture of the window on this Mac (at most 6 words and 60 characters
  each, at most 150). The controls never hold what is typed in a field, and a password field is not read. But
  a line in a field Varnick can't place is not dropped (see the item on Point at the screen above), so typed text of 6 words or
  fewer there may be shown to the session, and so reach Anthropic. The picture is never written, logged or
  sent. None of this goes to TypeSafe, and the TypeSafe filter has no part in it. Clicks happen without
  asking. Varnick's own panel is never read or clicked by it.
- **It downloads its models from Hugging Face** when you ask.
- **With Server chosen for Search embeddings or Text generation** (Settings › Models, off until you
  choose it), it sends to an OpenAI-compatible server you name, on your tailnet or this Mac and nowhere
  else: the searches you type, the prompts typed in the panel, the text of every page and session it
  embeds, which for a session includes Claude's last reply to each prompt (the paired Macs' sessions included). With
  Hey Varnick on, the words you say after "Hey Varnick" and the request's search words go to the
  embedding server, and the request and the titles, sites, folders and descriptions of the results it reads out
  go to the Text generation server; words said before you finished may be sent and then discarded. A key
  for that server is kept in the Keychain. Nothing goes to a third party.
- **Peers and the Phone page** talk to the hosts you list, and the Phone page to the devices you list, over
  SSH and Tailscale.

