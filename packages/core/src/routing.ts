/**
 * Where the window is, read out of the hash.
 *
 * Pure and free of the DOM, so `drive.ts` can assert it at the same seam the
 * app uses. Routing is three lines of logic and would not deserve a module,
 * except that the states page needs to address a *card* — and there is exactly
 * one hash, so the card cannot have its own.
 *
 * ## Why a card is a path segment rather than an anchor
 *
 * The obvious way to link to a card is `href="#cold-start"`, which is what a
 * browser scrolls to for free. It cannot work here: this app routes on the
 * hash, so an anchor would replace the route and unmount the page the card is
 * on. One hash, two jobs.
 *
 * So the route swallows the card: `#/states/cold-start` is the states page,
 * scrolled to `cold-start`. That is also what {@link StatesPage}'s own doc
 * comment has claimed since it was written — *"the surface a ticket points at:
 * `#/states → turn.failed` resolves to a card rather than to a copy of the
 * design"* — which was true of the page and not of any link, because there were
 * no per-card links to point at.
 */

export const ROUTES = ['#/designed', '#/states'] as const
export type Route = (typeof ROUTES)[number]

/** The rendering a hash names. Anything unrecognised is the chat. */
export function routeOf(hash: string): Route {
  // Longest first, so `#/states/cold-start` is not answered by a shorter route
  // that happens to prefix it. Nothing does today; the sort is what keeps that
  // from becoming an accident when a route is added.
  const match = [...ROUTES]
    .sort((a, b) => b.length - a.length)
    .find((route) => hash === route || hash.startsWith(`${route}/`))
  return match ?? '#/designed'
}

/**
 * The card a hash names, or `null` for the page itself.
 *
 * Only the states page has cards. A card segment on any other route is a hash
 * nobody wrote, and answering it would invent an addressable thing on a page
 * that has none.
 */
export function cardOf(hash: string): string | null {
  if (routeOf(hash) !== '#/states') return null
  const rest = hash.slice('#/states'.length)
  if (!rest.startsWith('/')) return null
  const card = rest.slice(1)
  return card.length === 0 ? null : card
}

/** The link to one card, and the one place that shape is written down. */
export function linkToCard(id: string): string {
  return `#/states/${id}`
}
