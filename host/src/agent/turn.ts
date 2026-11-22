// A turn of a session: what the harness is answering now. The assistant's
// are made by the host (the owner's words, a host-initiated turn from its
// queue, one the harness started on its own); an agent's are the harness' own
// (a plain reply turn). One shape for both (docs/harness-adapter-design.md step 13).
import type { WechatReplyTarget } from "../channels/types.ts";
import type { Channel } from "../types.ts";

export interface Turn {
  text: string; // what the model sees
  origin: Channel;
  proactive: boolean; // output is filtered for [skip] and routed as a push
  wechat?: WechatReplyTarget;
  implicit?: boolean; // harness started a turn on its own (e.g. a background task finished)
  label?: string;
  uuids?: string[]; // user messages this turn answers
  watchId?: string; // a schedule run: its reply becomes the goal's progress line
  maintenance?: boolean; // housekeeping for the harness (native /compact): nothing shown, nothing pushed
  allyId?: string; // an Ally's message: more from the same Ally joins it while it waits
  pal?: boolean; // a Pal's palo_send: answers work already asked for, so the proactive budget doesn't drop it
}

/** How a turn ended: its result's cost and context size, the error it failed with, the owner messages it answered. */
export interface TurnEnd<P = unknown> {
  costUsd?: number;
  contextTokens?: number;
  error?: string;
  errorCategory?: string;
  answered?: P[];
}

// A turn the harness started by itself is closed if it goes quiet without a
// result (flag implicitQuiet). Tests shorten it.
export const timing = { implicitQuietMs: 90_000 };
