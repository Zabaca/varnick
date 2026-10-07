// What every reader of a relay's or Tailscale's JSON needs: nothing about a shape is taken on trust.

export type Json = Record<string, unknown>;

export const isObject = (value: unknown): value is Json => typeof value === "object" && value !== null && !Array.isArray(value);

/** The objects of a list; anything else in it, or no list at all, is nothing. */
export const objects = (value: unknown): Json[] => (Array.isArray(value) ? value.filter(isObject) : []);
