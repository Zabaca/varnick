/**
 * The subset of Markdown an agent actually writes, parsed into a tree.
 *
 * Pure and free of React, so `drive.ts` asserts it at the same seam everything
 * else in this codebase is asserted at, with no DOM. The renderer beside it
 * (components/markdown.tsx) turns this into elements and makes no decisions.
 *
 * ## Why this is hand-written rather than a dependency
 *
 * Two reasons, and the second is the one that settles it.
 *
 * `react-markdown` and `remark-gfm` bring dozens of transitive packages into a
 * repository that has deliberately recorded npm install scripts as an open hole
 * (see packages/harness/src/sandbox.ts). Widening a hole you have written down
 * as open is worse than having it.
 *
 * And **this never produces HTML.** A markdown pipeline renders to a string and
 * then needs sanitising, which makes every agent answer one sanitiser bug away
 * from script execution *in the webview that holds the bridge to the host*. This
 * emits a tree of tagged nodes; the renderer builds React elements from it and
 * never assigns `innerHTML`. There is no injection surface to sanitise, which is
 * a stronger claim than a well-configured sanitiser.
 *
 * ## What it does not do
 *
 * No tables, no footnotes, no nested lists, no HTML passthrough, no reference
 * links, no images. Each of those is a real Markdown feature and none of them
 * appears in a coding agent's answers often enough to earn the parser. When one
 * does, it is added here with a test, rather than the whole of CommonMark being
 * adopted to cover it.
 */

/** A run of text inside a block. */
export type Inline =
  | { readonly kind: 'text'; readonly text: string }
  | { readonly kind: 'code'; readonly text: string }
  | { readonly kind: 'strong'; readonly text: string }
  | { readonly kind: 'em'; readonly text: string }
  /** `href` is shown as well as linked — see the renderer for why. */
  | { readonly kind: 'link'; readonly text: string; readonly href: string }

export type Block =
  | { readonly kind: 'paragraph'; readonly spans: readonly Inline[] }
  | { readonly kind: 'heading'; readonly level: 1 | 2 | 3 | 4 | 5 | 6; readonly spans: readonly Inline[] }
  /** A fenced block. `language` is whatever followed the fence, or `''`. */
  | { readonly kind: 'code'; readonly language: string; readonly text: string }
  | { readonly kind: 'list'; readonly ordered: boolean; readonly items: readonly (readonly Inline[])[] }
  | { readonly kind: 'quote'; readonly spans: readonly Inline[] }
  | { readonly kind: 'rule' }

const FENCE = /^\s*(?:```|~~~)\s*([\w+-]*)\s*$/
const HEADING = /^(#{1,6})\s+(.*)$/
const BULLET = /^\s*[-*+]\s+(.*)$/
const NUMBERED = /^\s*\d+[.)]\s+(.*)$/
const QUOTE = /^\s*>\s?(.*)$/
const RULE = /^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/

/**
 * Read a Markdown document into blocks.
 *
 * Line-oriented on purpose: an agent's answer arrives as lines, a fence is a
 * line, and a parser that tokenised the whole string would have to reconstruct
 * the one structure that is already there.
 */
export function parseMarkdown(source: string): readonly Block[] {
  const lines = source.split('\n')
  const blocks: Block[] = []
  let paragraph: string[] = []

  const flush = () => {
    if (paragraph.length === 0) return
    blocks.push({ kind: 'paragraph', spans: parseInline(paragraph.join('\n')) })
    paragraph = []
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!

    /*
      A fence first, and everything inside it is text.

      Before any other rule, because a `# comment` or a `- item` inside a code
      block is code. This is the whole reason the parser is line-oriented and
      stateful rather than a set of regexes over the document.
    */
    const fence = FENCE.exec(line)
    if (fence) {
      flush()
      const language = fence[1] ?? ''
      const body: string[] = []
      i++
      // An unterminated fence runs to the end of the message rather than
      // failing: a streamed answer is a partial document by definition, and
      // half a code block is what the developer should see while it arrives.
      while (i < lines.length && !FENCE.test(lines[i]!)) body.push(lines[i++]!)
      blocks.push({ kind: 'code', language, text: body.join('\n') })
      continue
    }

    if (line.trim() === '') {
      flush()
      continue
    }

    if (RULE.test(line)) {
      flush()
      blocks.push({ kind: 'rule' })
      continue
    }

    const heading = HEADING.exec(line)
    if (heading) {
      flush()
      const level = heading[1]!.length as 1 | 2 | 3 | 4 | 5 | 6
      blocks.push({ kind: 'heading', level, spans: parseInline(heading[2]!) })
      continue
    }

    const quote = QUOTE.exec(line)
    if (quote) {
      flush()
      const body = [quote[1]!]
      while (i + 1 < lines.length && QUOTE.test(lines[i + 1]!)) {
        body.push(QUOTE.exec(lines[++i]!)![1]!)
      }
      blocks.push({ kind: 'quote', spans: parseInline(body.join('\n')) })
      continue
    }

    const bullet = BULLET.exec(line)
    const numbered = NUMBERED.exec(line)
    if (bullet || numbered) {
      flush()
      const ordered = numbered !== null && bullet === null
      const items: Inline[][] = [parseInline((bullet ?? numbered)![1]!) as Inline[]]
      // Same marker only. A bulleted list that becomes numbered is two lists,
      // which is what it looks like and what the author meant.
      const same = ordered ? NUMBERED : BULLET
      const other = ordered ? BULLET : NUMBERED
      while (i + 1 < lines.length && same.test(lines[i + 1]!) && !other.test(lines[i + 1]!)) {
        items.push(parseInline(same.exec(lines[++i]!)![1]!) as Inline[])
      }
      blocks.push({ kind: 'list', ordered, items })
      continue
    }

    paragraph.push(line)
  }

  flush()
  return blocks
}

/*
  Inline spans, in one pass, longest marker first.

  `code` is matched before everything else and its contents are never scanned
  again, so `**` inside backticks stays two asterisks. That is the rule a
  developer notices immediately, because half of what an agent writes is a
  path or a flag with punctuation in it.
*/
const INLINE = new RegExp(
  [
    '`([^`]+)`', // code
    '\\*\\*([^*]+)\\*\\*', // strong
    '__([^_]+)__', // strong
    '\\*([^*]+)\\*', // em
    '\\[([^\\]]+)\\]\\(([^)\\s]+)\\)', // link
    '(https?://[^\\s<>()]+)', // bare url
  ].join('|'),
  'g',
)

export function parseInline(source: string): readonly Inline[] {
  const spans: Inline[] = []
  let at = 0

  for (const match of source.matchAll(INLINE)) {
    const start = match.index
    if (start > at) spans.push({ kind: 'text', text: source.slice(at, start) })

    const [, code, strongStar, strongUnder, em, linkText, linkHref, bareUrl] = match
    if (code !== undefined) spans.push({ kind: 'code', text: code })
    else if (strongStar !== undefined) spans.push({ kind: 'strong', text: strongStar })
    else if (strongUnder !== undefined) spans.push({ kind: 'strong', text: strongUnder })
    else if (em !== undefined) spans.push({ kind: 'em', text: em })
    else if (linkText !== undefined && linkHref !== undefined) {
      spans.push({ kind: 'link', text: linkText, href: linkHref })
    } else if (bareUrl !== undefined) spans.push({ kind: 'link', text: bareUrl, href: bareUrl })

    at = start + match[0].length
  }

  if (at < source.length) spans.push({ kind: 'text', text: source.slice(at) })
  // A document with nothing in it still has one span, so a renderer never has
  // to branch on an empty list to keep a blank line's height.
  if (spans.length === 0) spans.push({ kind: 'text', text: '' })
  return spans
}

/**
 * Is this link safe to give an `href`?
 *
 * `javascript:` and `data:` are the two that execute, and this webview is the
 * process holding the bridge to the host. Anything that is not plainly http,
 * https or mailto renders as text — the developer still sees the URL, and
 * nothing is hidden from them, which is the reason link text and href are shown
 * separately when they differ.
 */
export function isSafeHref(href: string): boolean {
  return /^(?:https?:\/\/|mailto:)/i.test(href.trim())
}
