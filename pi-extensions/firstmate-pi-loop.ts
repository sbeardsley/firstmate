/**
 * firstmate-pi-loop
 *
 * A pi (pi-coding-agent) extension that detects when an LLM session has
 * degenerated into one of three kinds of loop and notifies an external
 * supervisor (Firstmate) so it can take the right recovery action.
 *
 * The extension is a passive sensor plus a one-line notification: it appends
 * a single `loop: <kind> <details>` line to a per-task status file that the
 * supervisor already monitors for wake events. It does NOT restart the agent.
 * Its only active intervention is an optional, best-effort turn abort /
 * tool block (gated behind the FM_LOOP_BLOCK env var; notification-only by
 * default).
 *
 * The three loop kinds and the supervisor action each requests:
 *   - prose     -> short block of sentences/lines repeating consecutively
 *                  -> supervisor relaunches the worker in a fresh session
 *   - tool      -> same tool call (same tool + same normalized args) > 3x in a row
 *                  -> supervisor relaunches the worker in a fresh session
 *   - reasoning -> turn producing reasoning/thinking for too long with no
 *                  text output and no tool call
 *                  -> supervisor steers the agent to wrap up (no relaunch)
 *
 * Environment contract:
 *   FM_HOME    - absolute path to the supervisor's home directory.
 *   FM_TASK_ID - the task identifier string.
 *   Status path: ${FM_HOME}/state/${FM_TASK_ID}.status
 *   FM_LOOP_BLOCK - optional; set to "1" or "true" to enable best-effort
 *                   abort (prose/reasoning) / block (tool) after notifying.
 *
 * If FM_HOME or FM_TASK_ID is unset, the extension is a silent no-op, which
 * makes it safe to load in any pi session (including the supervisor's own
 * primary session and unsupervised pi instances).
 *
 * Loading path: designed for `~/.pi/agent/extensions/firstmate-pi-loop.ts`
 * (user-global auto-discovery, hot-reloadable via /reload) or `pi -e ./firstmate-pi-loop.ts`
 * for quick tests, or Firstmate's per-task launch wiring (CLI `-e` or a
 * user-global path).
 *
 * Content-part type names (discovered from pi's session-format docs):
 *   - text output   -> { type: "text",    text: string }
 *   - reasoning     -> { type: "thinking", thinking: string }
 *   - tool call     -> { type: "toolCall", id, name, arguments }
 *
 * Abort/block API discovered and used (only when FM_LOOP_BLOCK is set):
 *   - prose / reasoning mid-stream: `ctx.abort()` (cancels the current turn).
 *   - tool on the offending repeated call: `tool_call` handler returns
 *     `{ block: true, reason }`.
 *
 * Reasoning re-report cadence:
 *   The prose and tool detectors fire once per turn (each is a discrete event
 *   that the worker can react to). The reasoning detector fires on a cadence:
 *   a stuck turn keeps emitting `loop: reasoning ...` every REASONING_REREPORT_SECS
 *   seconds until firstmate steers the worker or the turn ends. This is what
 *   breaks the loop: the worker cannot ignore a status line that re-surfaces
 *   every minute.
 */

import { appendFileSync } from "node:fs";
import { join } from "node:path";

// ===========================================================================
// Tunables
// ===========================================================================

const PROSE_TAIL_CHARS = 2000;
const PROSE_MIN_SEGMENT_WORDS = 3;
const PROSE_MAX_BLOCK_SIZE = 6;
const PROSE_REPEAT_THRESHOLD = 4;
const MAX_PHRASE_CHARS = 80;

const TOOL_REPEAT_THRESHOLD = 3; // flag on the (3+1)th consecutive identical call
const TOOL_ARGS_MAX_CHARS = 120;

const REASONING_TIMEOUT_SECS = 90;
const REASONING_MAX_CHARS = 12000;

const REASONING_REREPORT_SECS = 60; // cadence for re-emitting reasoning loop lines

const DETAILS_MAX_CHARS = 160; // hard cap on the <details> portion of the line

// ===========================================================================
// Pure helpers (exported for testing)
// ===========================================================================

/** Stable JSON stringification with sorted object keys (deterministic). */
export function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) {
    return "[" + value.map(stableStringify).join(",") + "]";
  }
  const keys = Object.keys(value as Record<string, unknown>).sort();
  return (
    "{" +
    keys
      .map((k) => JSON.stringify(k) + ":" + stableStringify((value as Record<string, unknown>)[k]))
      .join(",") +
    "}"
  );
}

/**
 * Normalize tool args into a short, deterministic string key component.
 * JSON-stable-stringifies with sorted keys, collapses whitespace, truncates.
 */
export function normalizeArgs(args: unknown, max: number): string {
  if (args === null || args === undefined) return "";
  let s: string;
  try {
    s = stableStringify(args);
  } catch {
    try {
      s = String(args);
    } catch {
      return "";
    }
  }
  s = s.replace(/\s+/g, " ").trim();
  return s.slice(0, max);
}

export function truncate(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, max);
}

// --- prose ----------------------------------------------------------------

/** Split text into sentence/line segments, trimmed, dropping short ones. */
export function splitSegments(text: string): string[] {
  // Split on sentence terminators (with following space) or newlines.
  const raw = text.split(/(?:\.\s+|\!\s+|\?\s+|\n+)/);
  const out: string[] = [];
  for (let r of raw) {
    r = r.replace(/\s+/g, " ").trim();
    // strip a trailing sentence terminator left over from the final segment
    // (which has no trailing whitespace to split on).
    r = r.replace(/[.!?]+$/, "").trim();
    if (!r) continue;
    if (r.split(/\s+/).length < PROSE_MIN_SEGMENT_WORDS) continue;
    out.push(r);
  }
  return out;
}

function words(s: string): string[] {
  return s.toLowerCase().split(/\s+/).filter(Boolean);
}

/**
 * Conservative segment equality: exact (case-insensitive), or matches after
 * dropping a single leading word from either/both sides. Tolerates the
 * connective-fragment variation ("Hmm.", "Actually,") that precedes a repeat.
 */
function segmentsEqual(a: string, b: string): boolean {
  const la = a.toLowerCase();
  const lb = b.toLowerCase();
  if (la === lb) return true;
  const wa = words(a);
  const wb = words(b);
  const aTail = wa.length >= 2 ? wa.slice(1).join(" ") : null;
  const bTail = wb.length >= 2 ? wb.slice(1).join(" ") : null;
  if (aTail && aTail === lb) return true;
  if (bTail && la === bTail) return true;
  if (aTail && bTail && aTail === bTail) return true;
  return false;
}

/** True if the B-segment blocks at offset `i` and `j` are element-wise equal. */
function blockEquals(segs: string[], i: number, j: number, b: number): boolean {
  for (let k = 0; k < b; k++) {
    if (i + k >= segs.length || j + k >= segs.length) return false;
    if (!segmentsEqual(segs[i + k], segs[j + k])) return false;
  }
  return true;
}

export interface ProseHit {
  phrase: string;
  count: number;
  blockSize: number;
}

/**
 * Find the longest consecutive repeat of a contiguous block of 1..B segments
 * that repeats >= PROSE_REPEAT_THRESHOLD times in the tail of `text`.
 * Returns the highest-scoring hit (by repeated-segment count, then run length).
 */
export function detectProse(text: string): ProseHit | null {
  if (!text) return null;
  const tail = text.length > PROSE_TAIL_CHARS ? text.slice(-PROSE_TAIL_CHARS) : text;
  const segs = splitSegments(tail);
  if (segs.length < PROSE_MIN_SEGMENT_WORDS) return null;

  let best: ProseHit | null = null;

  for (let b = 1; b <= PROSE_MAX_BLOCK_SIZE; b++) {
    // need at least b * PROSE_REPEAT_THRESHOLD segments to even qualify
    if (b * PROSE_REPEAT_THRESHOLD > segs.length) break;
    for (let i = 0; i + b <= segs.length; i++) {
      let count = 1; // the block at position i counts as the first occurrence
      let j = i;
      while (j + b + b <= segs.length && blockEquals(segs, j, j + b, b)) {
        count++;
        j += b;
      }
      if (count >= PROSE_REPEAT_THRESHOLD) {
        const phrase = segs.slice(i, i + b).join(" ");
        const score = count * b; // repeated-segment count
        if (
          !best ||
          score > best.count * best.blockSize ||
          (score === best.count * best.blockSize && count > best.count)
        ) {
          best = { phrase: truncate(phrase, MAX_PHRASE_CHARS), count, blockSize: b };
        }
      }
    }
  }

  return best;
}

// --- message extraction ----------------------------------------------------

/** Concatenate all `type === "text"` content parts of an assistant message. */
export function extractAssistantText(message: any): string {
  if (!message || !Array.isArray(message.content)) return "";
  let out = "";
  for (const part of message.content) {
    if (part && part.type === "text" && typeof part.text === "string") out += part.text;
  }
  return out;
}

/** Sum the length of all `type === "thinking"` content parts (reasoning). */
export function extractReasoningLen(message: any): number {
  if (!message || !Array.isArray(message.content)) return 0;
  let len = 0;
  for (const part of message.content) {
    if (part && part.type === "thinking" && typeof part.thinking === "string") {
      len += part.thinking.length;
    }
  }
  return len;
}

/** Walk the session branch back to the most recent assistant message. */
export function lastAssistantMessage(ctx: any): any {
  try {
    const branch = ctx?.sessionManager?.getBranch?.();
    if (!Array.isArray(branch)) return undefined;
    for (let i = branch.length - 1; i >= 0; i--) {
      const entry = branch[i];
      if (entry && entry.type === "message" && entry.message?.role === "assistant") {
        return entry.message;
      }
    }
  } catch {
    /* ignore */
  }
  return undefined;
}

// ===========================================================================
// Extension factory
// ===========================================================================

export default function (pi: any) {
  const taskId = process.env.FM_TASK_ID;
  const home = process.env.FM_HOME;
  const statusPath = taskId && home ? join(home, "state", `${taskId}.status`) : null;
  const blockEnabled = /^(1|true|yes)$/i.test(String(process.env.FM_LOOP_BLOCK ?? ""));

  // per-turn state
  let reportedKind: string | null = null;
  let lastReportMs = 0;
  let turnStartMs = 0;
  let producedText = false;
  let producedTool = false;
  let reasoningChars = 0;
  let lastToolKey: string | null = null;
  let toolRun = 0;

  const resetTurn = () => {
    reportedKind = null;
    lastReportMs = 0;
    turnStartMs = Date.now();
    producedText = false;
    producedTool = false;
    reasoningChars = 0;
    lastToolKey = null;
    toolRun = 0;
  };

  /** Append one sanitized status line. */
  const report = (kind: string, details: string) => {
    if (!statusPath) return;
    const clean = details.replace(/\s+/g, " ").trim().slice(0, DETAILS_MAX_CHARS);
    try {
      appendFileSync(statusPath, `loop: ${kind} ${clean}\n`);
    } catch {
      /* never let file IO crash the session */
    }
  };

  // --- turn_start: reset --------------------------------------------------
  pi.on("turn_start", () => {
    try {
      resetTurn();
    } catch {
      /* ignore */
    }
  });

  // --- tool_call: tool loop detection + optional block --------------------
  pi.on("tool_call", async (event: any, ctx: any) => {
    try {
      if (!statusPath) return;
      producedTool = true; // a tool call is progress; suppresses reasoning-kind

      const toolName = event?.toolName ?? event?.name ?? "<unknown>";
      // pi uses event.input for tool parameters; tolerate event.args too.
      const args = event?.input ?? event?.args ?? event?.arguments ?? undefined;
      const norm = normalizeArgs(args, TOOL_ARGS_MAX_CHARS);
      const key = `${toolName}\x00${norm}`;

      if (key === lastToolKey) {
        toolRun += 1;
      } else {
        lastToolKey = key;
        toolRun = 1;
      }

      if (toolRun > TOOL_REPEAT_THRESHOLD) {
        const argPreview = truncate(norm, 80);
        report("tool", `${toolName} ${argPreview ? `"${argPreview}"` : "(no args)"} x${toolRun}`);
        if (blockEnabled) {
          // best-effort block of the offending repeated call
          return { block: true, reason: `loop: tool repeated x${toolRun}` };
        }
      }
    } catch {
      /* never propagate */
    }
    return undefined;
  });

  // --- message_update: prose + reasoning (streaming) ----------------------
  pi.on("message_update", async (_event: any, _ctx: any) => {
    try {
      if (!statusPath) return;
      const event = _event;
      if (!event || !event.message) return;

      const text = extractAssistantText(event.message);
      if (text) producedText = true;
      // event.message is the full accumulating message, so assign (not +=)
      // to avoid double-counting reasoning chars across updates.
      reasoningChars = extractReasoningLen(event.message);

      // prose: detect on the tail regardless of producedText, because a prose
      // loop can begin after the turn already produced some normal text.
      if (text) {
        const hit = detectProse(text);
        if (hit) {
          report("prose", `repeating "${hit.phrase}" x${hit.count}`);
          if (blockEnabled) {
            try {
              _ctx?.abort?.();
            } catch {
              /* ignore */
            }
          }
        }
      }

      // reasoning: only when NO text output and NO tool call this turn.
      // First emit at threshold, then re-emit on a cadence so a stuck turn
      // keeps surfacing until firstmate steers the worker.
      if (!producedText && !producedTool) {
        const elapsed = (Date.now() - turnStartMs) / 1000;
        const now = Date.now();
        if (elapsed >= REASONING_TIMEOUT_SECS || reasoningChars >= REASONING_MAX_CHARS) {
          const needsFirstEmit = reportedKind !== "reasoning";
          const needsReReport =
            reportedKind === "reasoning" &&
            now - lastReportMs >= REASONING_REREPORT_SECS * 1000;
          if (needsFirstEmit || needsReReport) {
            report(
              "reasoning",
              `${Math.round(elapsed)}s thinking with no output or tool call`,
            );
            lastReportMs = now;
            if (blockEnabled) {
              try {
                _ctx?.abort?.();
              } catch {
                /* ignore */
              }
            }
          }
        }
      }
    } catch {
      /* never propagate */
    }
  });

  // --- turn_end: backstop for prose + reasoning --------------------------
  pi.on("turn_end", async (event: any, ctx: any) => {
    try {
      if (!statusPath) return;
      const msg = event?.message ?? lastAssistantMessage(ctx);
      if (!msg) return;

      const text = extractAssistantText(msg);
      if (text) {
        const hit = detectProse(text);
        if (hit) report("prose", `repeating "${hit.phrase}" x${hit.count}`);
      }

      if (!producedText && !producedTool && reasoningChars >= REASONING_MAX_CHARS) {
        report(
          "reasoning",
          `finalized after ${reasoningChars} reasoning chars with no output or tool call`,
        );
      }
    } catch {
      /* never propagate */
    }
  });
}