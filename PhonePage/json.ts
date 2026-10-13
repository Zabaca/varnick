// What every reader of a relay's or Tailscale's JSON needs: nothing about a shape is taken on trust.

export type Json = Record<string, unknown>;

export const isObject = (value: unknown): value is Json => typeof value === "object" && value !== null && !Array.isArray(value);

/** A conversation's, tab's or session's id. */
export const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The objects of a list; anything else in it, or no list at all, is nothing. */
export const objects = (value: unknown): Json[] => (Array.isArray(value) ? value.filter(isObject) : []);
