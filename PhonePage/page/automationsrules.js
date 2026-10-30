// The Automations view's pure rules, with no DOM: the presets, a draft and the fields it becomes, how the page words times and marks, and the address.
// `bun test` checks them (PhonePage/automations.test.ts); the server (automations.ts) holds the same limits. The Mac decides everything else: it checks every
// field as it checks a session's call, and the page shows its lines.

export const limits = {
  name: 80,
  /** The most characters of a prompt one request carries (`PhoneAutomations.promptLimit`). */
  prompt: 20_000,
  rules: 40,
  rule: 300,
  folder: 4096,
  agent: 200,
  workingMin: 5,
  workingMax: 1440,
  workingDefault: 60,
};

export const minuteSteps = [15, 30];
export const hourSteps = [1, 2, 3, 4, 6, 12];
/** The weekdays as the cadence counts them: 1 is Sunday. */
export const weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** The cadence kinds the form offers, with the words on its buttons. */
export const cadenceKinds = [
  { kind: "minutes", title: "Minutes" },
  { kind: "hours", title: "Hours" },
  { kind: "daily", title: "Daily" },
  { kind: "weekdays", title: "Weekdays" },
  { kind: "weekly", title: "Weekly" },
];

/** What the form offers for permissions: the phone never offers Skip. */
export const permissionChoices = [
  { value: "varnick_setting", title: "Varnick's setting", detail: "Follows Settings › Claude's Skip permissions on the Mac, as a prompt typed there does." },
  { value: "ask", title: "Ask", detail: "Its allowed tools run; anything else waits for you (Needs you)." },
  { value: "allowed_tools_only", title: "Allowed tools only", detail: "Anything not allowed is refused with no dialog." },
];

const isWhole = (value, low, high) => Number.isInteger(value) && value >= low && value <= high;

/** Whether a cadence object is one of the presets (the Mac checks again). */
export function validCadence(cadence) {
  if (typeof cadence !== "object" || cadence === null) return false;
  const time = () => isWhole(cadence.hour, 0, 23) && isWhole(cadence.minute, 0, 59);
  switch (cadence.kind) {
    case "minutes": return minuteSteps.includes(cadence.every);
    case "hours": return hourSteps.includes(cadence.every);
    case "daily":
    case "weekdays": return time();
    case "weekly": return isWhole(cadence.weekday, 1, 7) && time();
    default: return false;
  }
}

/** The cadence a kind starts with when the user switches to it, keeping the time of day the form already had. */
export function cadenceOf(kind, before) {
  const hour = isWhole(before?.hour, 0, 23) ? before.hour : 9;
  const minute = isWhole(before?.minute, 0, 59) ? before.minute : 0;
  switch (kind) {
    case "minutes": return { kind, every: minuteSteps.includes(before?.every) ? before.every : 15 };
    case "hours": return { kind, every: hourSteps.includes(before?.every) ? before.every : 1 };
    case "weekly": return { kind, weekday: isWhole(before?.weekday, 1, 7) ? before.weekday : 2, hour, minute };
    default: return { kind, hour, minute };
  }
}

/** A new automation's form: Home, no agent, daily at 9:00, following Varnick's setting, on, the default limit. */
export const blankDraft = () => ({
  name: "", prompt: "", folder: null, agent: null, cadence: cadenceOf("daily"),
  permissions: "varnick_setting", allowedTools: "", workingLimit: limits.workingDefault, enabled: true,
});

/** The form for an automation the Mac listed. Allowed tools are one rule a line. */
export const draftOf = (automation) => ({
  name: automation.name, prompt: automation.prompt, folder: automation.folder, agent: automation.agent, cadence: { ...automation.cadence },
  permissions: automation.permissions, allowedTools: automation.allowedTools.join("\n"), workingLimit: automation.workingLimitMinutes, enabled: automation.enabled,
});

/** The allowed tool rules of a textarea: one a line, blanks dropped. */
export const rulesOf = (text) => text.split(/\r?\n/).map((line) => line.trim()).filter((line) => line !== "");

/** What is wrong with a form before it is sent, one line each. The Mac checks folders, agents and the rest and says so. */
export function draftProblems(draft) {
  const problems = [];
  if (draft.name.trim() === "") problems.push("Give it a name.");
  else if (draft.name.trim().length > limits.name) problems.push(`The name is at most ${limits.name} characters.`);
  if (draft.prompt.trim() === "") problems.push("Write the prompt Claude is asked.");
  else if (draft.prompt.length > limits.prompt) problems.push(`The prompt is at most ${limits.prompt} characters from the phone.`);
  if (!validCadence(draft.cadence)) problems.push("Choose when it runs.");
  if (!isWhole(Number(draft.workingLimit), limits.workingMin, limits.workingMax)) problems.push(`The working limit is ${limits.workingMin} to ${limits.workingMax} minutes.`);
  const rules = rulesOf(draft.allowedTools);
  if (rules.length > limits.rules) problems.push(`At most ${limits.rules} allowed tools.`);
  if (rules.some((rule) => rule.length > limits.rule)) problems.push(`A rule is at most ${limits.rule} characters.`);
  return problems;
}

/** The body of a save: the fields in the names the Mac's session tools take, as JSON values. Home is `folder: null` and no agent is `agent: null`. */
export function saveBody(id, draft) {
  return {
    kind: "save",
    ...(id ? { id } : {}),
    fields: {
      name: draft.name.trim(),
      prompt: draft.prompt,
      folder: draft.folder,
      agent: draft.agent,
      cadence: draft.cadence,
      permissions: draft.permissions,
      allowed_tools: rulesOf(draft.allowedTools),
      working_limit_minutes: Number(draft.workingLimit),
      enabled: draft.enabled,
    },
  };
}

/** "9:00 AM" style time of a cadence in the phone's own locale. */
export function timeText(hour, minute) {
  return new Date(2000, 0, 1, hour, minute).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

/** Unix seconds as the phone's locale shows a moment: the time today, else the day and the time. */
export function whenText(seconds, now = Date.now()) {
  const date = new Date(seconds * 1000);
  const time = date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  const sameDay = (a, b) => a.toDateString() === b.toDateString();
  const today = new Date(now);
  if (sameDay(date, today)) return time;
  const tomorrow = new Date(now + 86_400_000);
  if (sameDay(date, tomorrow)) return `Tomorrow ${time}`;
  return `${date.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" })} ${time}`;
}

/** The row's second line: when it next runs, or that it is off, then how the last run ended. */
export function statusText(automation, now = Date.now()) {
  const parts = [];
  if (!automation.enabled) parts.push("Off");
  else if (typeof automation.nextRun === "number") parts.push(`Next ${whenText(automation.nextRun, now)}`);
  if (automation.going) parts.push("Running now");
  const last = automation.last;
  if (last) parts.push(`Last: ${last.detail && last.state === "Message" ? last.detail : last.state}`);
  return parts.join(" · ");
}

/** What a mark says: who changed it and when, in the words the Mac's own list uses. */
export function markText(mark, now = Date.now()) {
  const who = mark.via === "phone" ? "The phone" : "A session";
  return `${who}: ${mark.what} by “${mark.by}” · ${whenText(mark.at, now)}`;
}

/** The folder as the phone names it: Home, or the project's last part. */
export const folderName = (folder) => (folder === null ? "Home" : folder.split("/").filter(Boolean).pop() ?? folder);

/** A line saying how the permissions read, for the detail. */
export function permissionsText(automation, skipPermissions) {
  switch (automation.permissions) {
    case "ask": return "Ask";
    case "allowed_tools_only": return "Allowed tools only";
    case "skip": return "Skip permissions (set on the Mac)";
    default: return `Varnick's setting (Skip is ${skipPermissions ? "on" : "off"})`;
  }
}

const uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const hashPattern = new RegExp(`^#automations(?:=(new|${uuid})(/edit)?)?$`, "i");

/** `#automations` is the list, `#automations=<id>` one automation, `#automations=<id>/edit` its form and `#automations=new` the empty form. Null: not this view. */
export function parseAutomationsHash(hash) {
  const match = hashPattern.exec(hash);
  if (!match) return null;
  const id = match[1] ? match[1].toLowerCase() : null;
  if (id === "new") return match[2] ? null : { id: null, editing: true, isNew: true };
  if (id === null) return match[2] ? null : { id: null, editing: false, isNew: false };
  return { id, editing: match[2] === "/edit", isNew: false };
}

export const automationsHash = (id, editing = false) => (id === null ? "#automations" : id === "new" ? "#automations=new" : `#automations=${id}${editing ? "/edit" : ""}`);
