// Shared domain types — keep in sync with /shared/types.ts at the repo root.

export type EventKind = "beer" | "loo" | (string & {});

export interface Post {
  id: string;
  pair: string;
  author: string;
  type: "photo" | "event";
  event_kind?: EventKind;
  note?: string;
  media?: string;
  created: string;
}

export interface WidgetFeed {
  state: "ok" | "empty" | "unpaired";
  partner?: { name: string };
  counts?: { beer: number; loo: number };
  post?: {
    id: string;
    type: "photo" | "event";
    event_kind: string;
    note: string;
    created: string;
    media_url: string;
    author: string;
  };
}

export interface PairInvite {
  code: string;
  expires: string;
  deep_link: string;
}

export const EVENT_KINDS = [
  { kind: "beer", emoji: "🍺", label: "Beer" },
  { kind: "loo", emoji: "💩", label: "Loo" },
  { kind: "coffee", emoji: "☕", label: "Coffee" },
] as const;
