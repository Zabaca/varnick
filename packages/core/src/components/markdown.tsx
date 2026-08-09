import { parseMarkdown, parseInline, isSafeHref, type Block, type Inline } from '../markdown.ts'

/**
 * An agent's answer, rendered.
 *
 * Elements only. This never assigns `innerHTML` and never receives HTML — the
 * parser hands it tagged nodes and it hands React a tree, so there is nothing
 * here for a sanitiser to get wrong. See ../markdown.ts for why that is the
 * design rather than a precaution.
 *
 * ## Staying inside the design system
 *
 * DESIGN.md is unusually strict and this component is where a Markdown renderer
 * would break it by habit: bigger headings, rounded code blocks, a second font.
 * None of that happens. Headings are the same 13px as the body and are told
 * apart by weight and colour, which is The Quiet Chrome Rule — *"a heading is a
 * heading because of what it says and where it sits, never because it is
 * larger"*. Code blocks are `ground-raised` with a 1px `rule` border and square
 * corners, which is the entire elevation vocabulary the system has.
 *
 * The one thing that scrolls is a code block. Prose wraps at 110ch per The Wide
 * Measure Rule; a diff or a stack trace must not wrap at all, so it takes its
 * own horizontal scroll rather than making the window wider.
 */
export function Markdown({ text }: { text: string }) {
  const blocks = parseMarkdown(text)
  return (
    <div className="min-w-0">
      {blocks.map((block, i) => (
        <BlockView key={i} block={block} />
      ))}
    </div>
  )
}

/** Vertical rhythm: the transcript's own gutter, and nothing on the first block. */
const GAP = 'mt-2 first:mt-0'

function BlockView({ block }: { block: Block }) {
  switch (block.kind) {
    case 'paragraph':
      // `whitespace-pre-wrap`, because a single newline inside a paragraph is a
      // line the agent meant. CommonMark would fold it into a space, which is
      // right for prose and wrong for an answer that lays out steps.
      return (
        <p className={`${GAP} min-w-0 whitespace-pre-wrap break-words`}>
          <Spans spans={block.spans} />
        </p>
      )

    case 'heading':
      return (
        <div
          className={`${GAP} min-w-0 break-words font-bold`}
          style={{ color: 'var(--fg)' }}
          role="heading"
          aria-level={block.level}
        >
          <Spans spans={block.spans} />
        </div>
      )

    case 'code':
      return (
        <pre
          className={`${GAP} overflow-x-auto p-2 text-[13px]`}
          style={{ background: 'var(--ground-raised)', border: '1px solid var(--rule)' }}
        >
          <code>{block.text}</code>
        </pre>
      )

    case 'list':
      return (
        <ul className={`${GAP} min-w-0 space-y-0.5`}>
          {block.items.map((item, i) => (
            <li key={i} className="flex min-w-0 gap-2">
              {/* The marker is drawn rather than left to a list-style, so an
                  ordered list's numbers sit in the same column as a bullet's
                  glyph and neither is indented by the browser's own rules. */}
              <span aria-hidden className="shrink-0" style={{ color: 'var(--fg-faint)' }}>
                {block.ordered ? `${i + 1}.` : '•'}
              </span>
              <span className="min-w-0 whitespace-pre-wrap break-words">
                <Spans spans={item} />
              </span>
            </li>
          ))}
        </ul>
      )

    case 'quote':
      return (
        <blockquote
          className={`${GAP} min-w-0 whitespace-pre-wrap break-words pl-2`}
          style={{ borderLeft: '1px solid var(--rule)', color: 'var(--fg-dim)' }}
        >
          <Spans spans={block.spans} />
        </blockquote>
      )

    case 'rule':
      return <hr className={GAP} style={{ border: 0, borderTop: '1px solid var(--rule)' }} />
  }
}

function Spans({ spans }: { spans: readonly Inline[] }) {
  return (
    <>
      {spans.map((span, i) => (
        <SpanView key={i} span={span} />
      ))}
    </>
  )
}

function SpanView({ span }: { span: Inline }) {
  switch (span.kind) {
    case 'text':
      return <>{span.text}</>

    case 'strong':
      return <strong className="font-bold">{span.text}</strong>

    case 'em':
      // Italic in a monospace stack is often a synthesised slant and reads
      // badly at 13px, so emphasis is carried by colour instead — the same
      // move the rest of the product makes.
      return <span style={{ color: 'var(--fg)' }}>{span.text}</span>

    case 'code':
      return (
        <code
          className="break-words px-1"
          style={{ background: 'var(--ground-raised)', color: 'var(--fg)' }}
        >
          {span.text}
        </code>
      )

    case 'link': {
      /*
        A link that is not plainly http, https or mailto is rendered as text.

        `javascript:` and `data:` execute, and this is the webview that holds
        the bridge to the host. The URL is still shown — nothing is hidden from
        the developer, it simply is not clickable.
      */
      if (!isSafeHref(span.href)) return <>{span.text}</>
      return (
        <a
          href={span.href}
          target="_blank"
          rel="noreferrer noopener"
          style={{ color: 'var(--accent)' }}
        >
          {span.text}
        </a>
      )
    }
  }
}

/** Exported for the one place a caller has a line rather than a document. */
export function InlineMarkdown({ text }: { text: string }) {
  return <Spans spans={parseInline(text)} />
}
