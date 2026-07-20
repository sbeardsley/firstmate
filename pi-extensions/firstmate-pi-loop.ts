/**
 * firstmate-pi-loop
 *
 * A pi (pi-coding-agent) extension that detects when an LLM session has
 * degenerated into one of several kinds of loop and notifies an external
 * supervisor (Firstmate) so it can take the right recovery action.
 *
 * The extension is a passive sensor plus a one-line notification: it appends
 * a single `loop: <kind> <details>` line to a per-task status file that the
 * supervisor already monitors for wake events. It does NOT restart the agent.
 * Its only active intervention is an optional, best-effort turn abort /
 * tool block (gated behind the FM_LOOP_BLOCK env var; notification-only by
 * default), plus the session-scoped tool ban, which blocks by default
 * independently of FM_LOOP_BLOCK (disable with FM_LOOP_BAN=0).
 *
 * The loop kinds and the supervisor action each requests:
 *   - prose     -> short block of sentences/lines repeating consecutively
 *                  -> supervisor relaunches the worker in a fresh session
 *   - tool      -> same tool call (same tool + same normalized args) > 3x in a row
 *                  -> supervisor relaunches the worker in a fresh session
 *   - reasoning -> turn producing reasoning/thinking for too long with no
 *                  text output and no tool call
 *                  -> supervisor steers the agent to wrap up (no relaunch)
 *   - stagnation -> cross-turn thinking re-derives the same plan across turns
 *                   -> supervisor relaunches the worker in a fresh session
 *   - tool-seq   -> identical tool-call sequence repeats >= threshold times
 *                   -> supervisor relaunches; the offending call is session-banned
 *                   (attempts to re-run a banned call also emit this kind)
 *   - rederive   -> a context event carried thinking that re-derives the plan
 *                   that led to a stagnation hit; the thinking parts are trimmed
 *                   -> informational; no supervisor action requested
 *   - file-scan  -> same absolute path read > FILE_SCAN_LIMIT times (counts
 *                   halve each turn and reset when the file is written/edited)
 *                   -> supervisor relaunches; the offending call is blocked
 *   - search-spiral -> same search pattern repeated across > SEARCH_EXPAND_LIMIT
 *                      distinct locations within a single turn
 *                   -> supervisor relaunches; the offending call is blocked
 *
 * Environment contract:
 *   FM_HOME    - absolute path to the supervisor's home directory.
 *   FM_TASK_ID - the task identifier string.
 *   Status path: ${FM_HOME}/state/${FM_TASK_ID}.status
 *   FM_LOOP_BLOCK - optional; set to "1" or "true" to enable best-effort
 *                   abort (prose/reasoning/stagnation) / block (tool/file-scan/search-spiral)
 *                   after notifying.
 *   FM_LOOP_BAN - optional; set to "0" to disable the session-scoped tool-ban
 *                 (the per-occurrence block under FM_LOOP_BLOCK still fires).
 *                 Default: on.
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
 *   - prose / reasoning / stagnation mid-stream: `ctx.abort()` (cancels the current turn).
 *   - tool on the offending repeated call: `tool_call` handler returns
 *     `{ block: true, reason }`.
 *   - session-banned tool: `tool_call` handler returns `{ block: true, reason }`
 *     regardless of FM_LOOP_BLOCK.
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
import { join, resolve } from "node:path";

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

// --- stagnation / re-derive ------------------------------------------------

const STAGNATION_WINDOW = 4; // number of prior turns' fingerprint sets to compare against
const STAGNATION_THRESHOLD = 0.85; // Jaccard similarity >= this triggers the stagnation line
const REDERIVE_THRESHOLD = 0.85; // Jaccard similarity >= this triggers re-derive trim
const FINGERPRINT_LEN = 60; // per-paragraph fingerprint: first N alnum-normalized chars
const REDERIVE_RESET_EVENTS = 5; // after N context events post-trim, reset the led-to-loop set

// --- tool sequence / session ban -------------------------------------------

const TOOL_SEQ_WINDOW = 3; // size of the sliding window of consecutive tool calls
const TOOL_SEQ_REPEAT_THRESHOLD = 3; // identical W-window repeats >= this triggers the line
const FM_LOOP_BAN_DEFAULT = 1; // 1 = session ban on; 0 = ban off

// --- file scan / search spiral ---------------------------------------------

const FILE_SCAN_LIMIT = 20; // reads of the same absolute path (counts halve each turn, reset on write/edit)
const SEARCH_EXPAND_LIMIT = 8; // distinct locations a single search pattern covers within one turn before spiral

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

// --- stagnation / re-derive ------------------------------------------------

/**
 * Split a string into paragraphs (blank-line or sentence boundaries), then
 * produce a per-paragraph fingerprint: each paragraph is normalized (lowercased,
 * stripped of non-alnum, trimmed) and truncated to FINGERPRINT_LEN chars.
 * Returns the set of per-paragraph fingerprints.
 */
export function paragraphFingerprints(text: string): Set<string> {
  const out = new Set<string>();
  // Split on blank lines first, then on sentence boundaries within each chunk.
  const chunks = text.split(/\n\s*\n/);
  for (const chunk of chunks) {
    const sentences = chunk.split(/(?<=[.!?])\s+/);
    for (const sent of sentences) {
      const normalized = sent.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
      if (!normalized) continue;
      out.add(normalized.slice(0, FINGERPRINT_LEN));
    }
  }
  return out;
}

/**
 * Concatenate all `type === "thinking"` content parts of an assistant message
 * into a single string.
 */
export function extractAssistantThinking(message: any): string {
  if (!message || !Array.isArray(message.content)) return "";
  let out = "";
  for (const part of message.content) {
    if (part && part.type === "thinking" && typeof part.thinking === "string") {
      out += part.thinking;
    }
  }
  return out;
}

/**
 * Jaccard similarity between two sets: |intersection| / |union|.
 * Returns 0 when both sets are empty, otherwise returns a value in [0, 1].
 */
export function jaccardSimilarity(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 && b.size === 0) return 0;
  let intersection = 0;
  for (const item of a) {
    if (b.has(item)) intersection++;
  }
  const union = a.size + b.size - intersection;
  return union === 0 ? 0 : intersection / union;
}

/**
 * Compute the union of a list of fingerprint sets.
 */
export function unionOfSets(sets: Set<string>[]): Set<string> {
  const out = new Set<string>();
  for (const s of sets) {
    for (const item of s) out.add(item);
  }
  return out;
}

// --- tool sequence ---------------------------------------------------------

/**
 * Build a key from a tool call: toolName + normalized args.
 */
export function toolCallKey(toolName: string, args: unknown): string {
  return `${toolName}\x00${normalizeArgs(args, TOOL_ARGS_MAX_CHARS)}`;
}

/**
 * Detect a repeating tool-call sequence: given a history of tool call keys
 * (ordered by time), check whether the last `windowSize` calls repeat
 * identically >= `repeatThreshold` times consecutively.
 *
 * Returns the detected run info or null if no sequence loop is found.
 */
export function detectToolSequence(
  history: string[],
  windowSize: number,
  repeatThreshold: number,
): { key: string; count: number } | null {
  if (history.length < windowSize) return null;
  const tail = history.slice(-windowSize);
  const key = tail.join(",");
  // Walk backwards from the end, counting consecutive identical W-windows.
  let count = 1;
  let i = history.length - windowSize;
  while (i - windowSize >= 0) {
    const prev = history.slice(i - windowSize, i).join(",");
    if (prev === key) {
      count++;
      i -= windowSize;
    } else {
      break;
    }
  }
  if (count >= repeatThreshold) {
    return { key, count };
  }
  return null;
}

// --- file scan -------------------------------------------------------------

/**
 * Normalize a read path to absolute form (resolve relative paths against the
 * given cwd). Returns the absolute path string.
 */
export function normalizeReadPath(filePath: string, cwd: string): string {
  if (!filePath) return "";
  if (resolve(filePath) === filePath) return filePath;
  return resolve(cwd, filePath);
}

/**
 * Track a read call: increment the per-path count in the map.
 * Returns the new total count for that path.
 */
export function trackFileRead(
  fileReads: Map<string, number>,
  filePath: string,
  cwd: string,
): number {
  if (!filePath) return 0;
  const abs = normalizeReadPath(filePath, cwd);
  const n = (fileReads.get(abs) ?? 0) + 1;
  fileReads.set(abs, n);
  return n;
}

// --- search spiral ---------------------------------------------------------

/**
 * Track a search call: record the pattern and add the location to the pattern's
 * set. Returns the current distinct-location count for that pattern.
 */
export function trackSearch(
  searchPaths: Map<string, Set<string>>,
  pattern: string,
  location: string,
): number {
  const set = searchPaths.get(pattern) ?? new Set<string>();
  set.add(location);
  searchPaths.set(pattern, set);
  return set.size;
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
  const banEnabled = String(process.env.FM_LOOP_BAN ?? "").length === 0
    ? FM_LOOP_BAN_DEFAULT
    : /^(1|true|yes)$/i.test(String(process.env.FM_LOOP_BAN ?? ""))
      ? 1
      : 0;
  const cwd = process.cwd();

  // per-turn state
  let reportedKind: string | null = null;
  let lastReportMs = 0;
  let turnStartMs = 0;
  let producedText = false;
  let producedTool = false;
  let reasoningChars = 0;
  let lastToolKey: string | null = null;
  let toolRun = 0;

  // --- stagnation / re-derive state --------------------------------------
  // Each entry is the set of paragraph fingerprints for one turn's assistant
  // thinking. We keep a sliding window of the last STAGNATION_WINDOW entries.
  const stagnationWindow: Set<string>[] = [];
  // The fingerprint set that led to the most recent stagnation detection;
  // used to trim re-derived thinking on the next context event.
  let ledToLoop: Set<string> | null = null;
  let rederiveEventCount = 0;

  // --- tool sequence / session ban state ---------------------------------
  // Ordered history of tool-call keys (one per call).
  const toolCallHistory: string[] = [];
  // Session-scoped ban set: keys that proved they loop.
  const bannedTools: Set<string> = new Set<string>();

  // --- file scan / search spiral state -----------------------------------
  const fileReads: Map<string, number> = new Map<string, number>();
  const searchPaths: Map<string, Set<string>> = new Map<string, Set<string>>();

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
      // Decay file-read counts each turn so occasional legitimate re-reads
      // never accumulate into a permanent block; only sustained scanning
      // faster than the decay trips FILE_SCAN_LIMIT.
      for (const [path, count] of fileReads) {
        const next = Math.floor(count / 2);
        if (next <= 0) fileReads.delete(path);
        else fileReads.set(path, next);
      }
      // Search-spiral detection is scoped to a single turn.
      searchPaths.clear();
    } catch {
      /* ignore */
    }
  });

  // --- tool_call: tool loop + sequence loop + session ban + file-scan +
  // search-spiral. A single handler so block returns never depend on how pi
  // orders or combines multiple handlers for the same event.
  pi.on("tool_call", async (event: any, ctx: any) => {
    try {
      if (!statusPath) return;
      producedTool = true; // a tool call is progress; suppresses reasoning-kind

      const toolName = event?.toolName ?? event?.name ?? "<unknown>";
      // pi uses event.input for tool parameters; tolerate event.args too.
      const args = event?.input ?? event?.args ?? event?.arguments ?? undefined;
      const norm = normalizeArgs(args, TOOL_ARGS_MAX_CHARS);
      const key = toolCallKey(toolName, args);

      // Record in history for sequence detection.
      toolCallHistory.push(key);
      if (toolCallHistory.length > TOOL_SEQ_WINDOW * TOOL_SEQ_REPEAT_THRESHOLD + 1) {
        toolCallHistory.shift();
      }

      // --- session ban: blocks regardless of FM_LOOP_BLOCK --------------
      if (bannedTools.has(key)) {
        report("tool-seq", `${toolName} session-banned`);
        if (banEnabled) {
          return { block: true, reason: "loop: banned for this session" };
        }
      }

      // --- per-call adjacency detector (existing) -----------------------
      if (key === lastToolKey) {
        toolRun += 1;
      } else {
        lastToolKey = key;
        toolRun = 1;
      }

      // --- sequence detector: sliding window of identical calls ---------
      const seqHit = detectToolSequence(
        toolCallHistory,
        TOOL_SEQ_WINDOW,
        TOOL_SEQ_REPEAT_THRESHOLD,
      );
      if (seqHit) {
        const argPreview = truncate(normalizeArgs(args, 80), 80);
        report("tool-seq", `${toolName} ${argPreview ? `"${argPreview}"` : "(no args)"} x${seqHit.count}`);
        // Add to session ban set.
        bannedTools.add(key);
        if (blockEnabled) {
          return { block: true, reason: `loop: tool sequence repeated x${seqHit.count}` };
        }
      } else if (toolRun > TOOL_REPEAT_THRESHOLD) {
        // --- single-call detector (existing) ----------------------------
        const argPreview = truncate(norm, 80);
        report("tool", `${toolName} ${argPreview ? `"${argPreview}"` : "(no args)"} x${toolRun}`);
        if (blockEnabled) {
          return { block: true, reason: `loop: tool repeated x${toolRun}` };
        }
      }

      const input = args && typeof args === "object" ? (args as any) : undefined;

      // --- write/edit: a modified file is fresh content; reset its count -
      if (input && (toolName === "write" || toolName === "edit")) {
        const target =
          input.filePath ?? input.path ?? input.file ?? input.target ?? undefined;
        if (target) fileReads.delete(normalizeReadPath(target, cwd));
      }

      // --- file-scan: structured `read` calls only, not bash ------------
      if (input && toolName === "read") {
        const filePath =
          input.filePath ?? input.path ?? input.file ?? input.target ?? undefined;
        if (filePath) {
          const total = trackFileRead(fileReads, filePath, cwd);
          if (total > FILE_SCAN_LIMIT) {
            report("file-scan", `${filePath} read ${total} times`);
            if (blockEnabled) {
              return { block: true, reason: `loop: file-scan ${filePath} read ${total} times` };
            }
          }
        }
      }

      // --- search-spiral: structured `grep` calls only, not bash --------
      if (input && toolName === "grep") {
        const pattern =
          input.pattern ?? input.query ?? input.search ?? input.term ?? undefined;
        const location =
          input.path ?? input.location ?? input.target ?? input.directory ?? undefined;
        if (pattern && location) {
          const distinct = trackSearch(searchPaths, pattern, location);
          if (distinct > SEARCH_EXPAND_LIMIT) {
            report("search-spiral", `${pattern} across ${distinct} locations`);
            if (blockEnabled) {
              return { block: true, reason: `loop: search-spiral ${pattern} across ${distinct} locations` };
            }
          }
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

  // --- turn_end: stagnation + reasoning backstop --------------------------
  pi.on("turn_end", async (event: any, ctx: any) => {
    try {
      if (!statusPath) return;

      // --- stagnation: fingerprint this turn's thinking -----------------
      const msg = event?.message ?? lastAssistantMessage(ctx);
      if (msg) {
        const thinking = extractAssistantThinking(msg);
        if (thinking) {
          const fpSet = paragraphFingerprints(thinking);
          stagnationWindow.push(fpSet);
          if (stagnationWindow.length > STAGNATION_WINDOW) {
            stagnationWindow.shift();
          }
          // Compare against the union of prior turns' sets.
          if (stagnationWindow.length >= 2) {
            const prior = unionOfSets(stagnationWindow.slice(0, -1));
            const sim = jaccardSimilarity(fpSet, prior);
            if (sim >= STAGNATION_THRESHOLD) {
              report(
                "stagnation",
                `${Math.round(sim * 100)}% similar across last ${stagnationWindow.length} turns`,
              );
              ledToLoop = fpSet;
              rederiveEventCount = 0;
              if (blockEnabled) {
                try {
                  ctx?.abort?.();
                } catch {
                  /* ignore */
                }
              }
            }
          }
        }
      }

      // --- prose backstop (existing) ------------------------------------
      if (msg) {
        const text = extractAssistantText(msg);
        if (text) {
          const hit = detectProse(text);
          if (hit) report("prose", `repeating "${hit.phrase}" x${hit.count}`);
        }
      }

      // --- reasoning backstop (existing) --------------------------------
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

  // --- context: re-derive trim --------------------------------------------
  pi.on("context", async (event: any, _ctx: any) => {
    try {
      if (!statusPath) return;
      // Only trim when we have a led-to-loop set to compare against.
      if (!ledToLoop || ledToLoop.size === 0) return;

      let trimmed = 0;
      for (const message of event.messages) {
        if (!message || !Array.isArray(message.content)) continue;
        // Only look at assistant messages.
        if (message.role !== "assistant") continue;
        // Gather thinking parts.
        const thinkingParts: any[] = [];
        for (const part of message.content) {
          if (part && part.type === "thinking" && typeof part.thinking === "string") {
            thinkingParts.push(part);
          }
        }
        if (thinkingParts.length === 0) continue;
        // Concatenate and fingerprint each thinking part individually.
        const allFingerprints = new Set<string>();
        for (const tp of thinkingParts) {
          const fp = paragraphFingerprints(tp.thinking);
          for (const f of fp) allFingerprints.add(f);
        }
        const sim = jaccardSimilarity(allFingerprints, ledToLoop);
        if (sim >= REDERIVE_THRESHOLD) {
          // Trim each thinking part (empty the thinking string) but leave
          // the message and non-thinking parts intact.
          for (const tp of thinkingParts) {
            tp.thinking = "";
          }
          trimmed += thinkingParts.length;
        }
      }
      if (trimmed > 0) {
        report("rederive", `trimmed ${trimmed} re-derived thinking parts`);
        ledToLoop = null;
        rederiveEventCount = 0;
      } else {
        rederiveEventCount += 1;
        if (rederiveEventCount >= REDERIVE_RESET_EVENTS) {
          ledToLoop = null;
          rederiveEventCount = 0;
        }
      }
    } catch {
      /* never propagate */
    }
  });

}