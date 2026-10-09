import Foundation

/// The hooks that make work links (ADR 0019), as shell for `ClaudeCommand.hookSettings`. POSIX sh with grep, cut, tail and git, no jq, run by
/// whatever shell claude gives hooks (sh, bash, zsh, dash), on every host. The rules for all of them, in `docs/agents/where-it-breaks.md`:
/// they print nothing (except SessionStart's line, which goes to Claude), exit 0 whatever happens, never block a tool, and write by rename.
///
/// A hook finds the pane folder from `LAUNCHY_SESSION_FILE`, as the turn hooks do. A JSON key is matched only after `{` or `,` with its
/// quote raw, so text inside a string being written (whose quotes are escaped) can't pass for a key. A subagent's call has `agent_id`;
/// it names a file only if it is letters, digits, dashes and underscores.
enum WorkHooks {
    /// Before Write, Edit, MultiEdit and NotebookEdit: a file under `docs/problems/<slug>/`, or under `.scratch/<slug>/` of an existing
    /// problem, links whoever writes it to that problem. It never replaces an option record. Always exits 0, prints nothing.
    static let writeMatcher = "Write|Edit|MultiEdit|NotebookEdit"

    static var autoLink: String {
        quiet(entry + #"""
        case "$inp" in *docs/problems/*|*.scratch/*) ;; *) exit 0;; esac
        """# + "\n" + helpers + #"""
        fp=$(field file_path); [ -n "$fp" ] || fp=$(field notebook_path)
        case "$fp" in
        /*) ;;
        ?*) c=$(field cwd); case "$c" in /*) fp="$c/$fp";; *) exit 0;; esac;;
        *) exit 0;;
        esac
        origin=
        case "$fp" in
        */docs/problems/*/*)
          rest=${fp#*/docs/problems/}; slug=${rest%%/*}; root=${fp%%/docs/problems/*}
          [ "$rest" = "$slug/problem.md" ] && [ ! -e "$fp" ] && origin=origin;;
        */.scratch/*/*)
          rest=${fp#*/.scratch/}; slug=${rest%%/*}; root=${fp%%/.scratch/*}
          [ -f "$root/docs/problems/$slug/problem.md" ] || exit 0;;
        *) exit 0;;
        esac
        case "$slug" in ""|.*|*[!A-Za-z0-9._-]*) exit 0;; esac
        [ -n "$root" ] || exit 0
        c=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)
        case "$c" in /*) ;; ?*) c="$root/$c";; esac
        case "$c" in */.git) root=${c%/.git};; esac
        cur=$(head -n 1 "$rec" 2>/dev/null)
        [ -z "$cur" ] && [ -n "$aid" ] && cur=$(head -n 1 "$d/work" 2>/dev/null)
        case "$cur" in option\ *) ;; *) put problem "$slug" "$root";; esac
        logit problem "$slug" "$root" "$origin"
        """#)
    }

    /// After Bash: the `/work` script's marker line in the output, `LAUNCHY-WORK|<pane id>|<kind>|<value>|<repo>|`, writes the record of
    /// whoever ran it, the subagent when the call carries `agent_id`. The pane id in it keeps text that merely quotes a marker, in a
    /// document or another pane's output, from linking anything. The last marker wins.
    static let markMatcher = "Bash"

    static var mark: String {
        quiet(entry + #"""
        case "$inp" in *"LAUNCHY-WORK|${d##*/}|"*) ;; *) exit 0;; esac
        """# + "\n" + helpers + #"""
        m=$(printf '%s' "$inp" | grep -o 'LAUNCHY-WORK|'"${d##*/}"'|[a-z]*|[^|"\]*|[^|"\]*|' | tail -n 1)
        [ -n "$m" ] || exit 0
        kind=$(printf '%s' "$m" | cut -d'|' -f3); value=$(printf '%s' "$m" | cut -d'|' -f4); root=$(printf '%s' "$m" | cut -d'|' -f5)
        case "$kind" in
        none) put none; logit none; exit 0;;
        problem) slug=$value;;
        option) slug=${value%/*}; num=${value##*/}
          case "$num" in ""|*[!0-9]*) exit 0;; esac;;
        *) exit 0;;
        esac
        case "$slug" in ""|.*|*[!A-Za-z0-9._-]*) exit 0;; esac
        case "$root" in /*) ;; *) exit 0;; esac
        put "$kind" "$value" "$root"
        logit "$kind" "$value" "$root"
        """#)
    }

    /// At a subagent's end: its record goes, and the log says so, which is what makes the app read the records again.
    static var subagentStop: String {
        quiet(entry + #"""
        case "$inp" in *agent_id*) ;; *) exit 0;; esac
        """# + "\n" + helpers + #"""
        [ -n "$aid" ] && [ -f "$d/work.$aid" ] || exit 0
        rm -f "$d/work.$aid"
        chg=1; logit end
        """#)
    }

    /// At every session start, in a repository that has both problems and the `/work` skill: one line for Claude about `/work`, and the
    /// open problems by slug and title. Where either is missing it prints nothing.
    static let sessionStart = #"""
        r="$LAUNCHY_PROJECT"
        { [ -n "$r" ] && [ -f "$r/.claude/skills/work/SKILL.md" ] && [ -d "$r/docs/problems" ]; } 2>/dev/null || exit 0
        printf '%s\n' "Launchy work links: this session and its subagents each keep one link to a problem or an option, so the board shows who works on what. Writing under a problem's folders links you to it; \
        run /work option <slug>/<NN> when you build an option, /work problem <slug> to work on a problem without writing its files, /work none to clear, /work to show. Open problems:"
        for f in "$r"/docs/problems/*/problem.md; do
          [ -f "$f" ] || continue
          s=${f%/problem.md}; s=${s##*/}
          awk -v s="$s" 'NR==1{if($0!="---")exit;next} $0=="---"{exit} /^title:/{sub(/^title:[ \t]*/,"");t=$0} /^status:/{sub(/^status:[ \t]*/,"");st=$0} END{if(t~/^\042.*\042$/||t~/^\047.*\047$/)t=substr(t,2,length(t)-2);if(st!="closed")printf "- %s: %s\n",s,substr(t,1,80)}' "$f"
        done | head -n 25
        exit 0
        """#

    // MARK: Shared pieces

    /// Runs the body in a subshell with no output, then exits 0 whatever it did.
    private static func quiet(_ body: String) -> String {
        "(\n" + body + "\n) >/dev/null 2>&1; exit 0"
    }

    /// The pane folder, from the variable the turn hooks use, and the hook's input.
    private static let entry = #"""
        d="${LAUNCHY_SESSION_FILE%/*}"
        [ -n "$LAUNCHY_SESSION_FILE" ] && [ -d "$d" ] || exit 0
        inp=$(cat)

        """#

    /// `field <key>` is the first string value of a top-level or tool-input key; `aid` and `atype` are the subagent's; `rec` is whose record this
    /// call writes. `put <kind> [value repo]` writes it by rename if it differs and sets `chg`. `logit <kind> [value repo flag]` appends a line to
    /// the log unless that line was written among the last twenty and no record changed (the log's date is how the app learns of a change).
    private static let helpers = #"""
        field() { printf '%s' "$inp" | grep -o '[{,]"'"$1"'":"[^"\]*"' | head -n 1 | cut -d'"' -f4; }
        aid=$(field agent_id)
        case "$aid" in *[!A-Za-z0-9_-]*) exit 0;; esac
        atype=$(field agent_type)
        case "$atype" in *[!A-Za-z0-9_.:-]*) atype=;; esac
        rec="$d/work"; [ -n "$aid" ] && rec="$d/work.$aid"
        chg=
        put() {
          if [ "$1" = none ]; then b=none; else b=$(printf '%s %s\nrepo %s' "$1" "$2" "$3"); fi
          [ -n "$aid" ] && [ -n "$atype" ] && b=$(printf '%s\nagent %s' "$b" "$atype")
          [ "$(cat "$rec" 2>/dev/null)" = "$b" ] && return 0
          printf '%s\n' "$b" > "$d/.tmp-work.$$" && mv "$d/.tmp-work.$$" "$rec" && chg=1
        }
        logit() {
          line=$(printf '%s\t%s\t%s\t%s\t%s\t%s' "${aid:--}" "${atype:--}" "$1" "${2:--}" "${3:--}" "$4")
          [ -z "$chg" ] && tail -n 20 "$d/work-log" 2>/dev/null | cut -f2- | grep -qxF -- "$line" && return 0
          printf '%s\t%s\n' "$(date +%s)" "$line" >> "$d/work-log"
        }

        """#
}
