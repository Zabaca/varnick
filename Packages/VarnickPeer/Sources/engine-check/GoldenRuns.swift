// Slice 1's writer's output for the Runs `engine-check` builds (fixed ids and dates), taken before slice 2a changed the record: an automation's Run is
// written byte for byte as it was. Only the file's version differs (1 then, 2 now).
let sliceOneRuns = #"""
{
  "runs" : [
    {
      "id" : "22222222-2222-2222-2222-222222222222",
      "input" : {
        "folder" : "/work/x",
        "prompt" : "Say hello"
      },
      "opened" : false,
      "startedAt" : "2026-10-14T17:46:40Z",
      "state" : "running",
      "steps" : [
        {
          "capability" : "claude",
          "conversation" : "moved",
          "launch" : {
            "agent" : "reviewer",
            "allowedTools" : [
              "Bash(git status)",
              "Edit"
            ],
            "dontAsk" : true,
            "folder" : "/work/x",
            "skipPermissions" : false
          },
          "name" : "claude",
          "pane" : "22222222-2222-2222-2222-222222222222",
          "worked" : 90
        }
      ],
      "task" : "Claude prompt",
      "trigger" : {
        "automation" : "11111111-1111-1111-1111-111111111111",
        "late" : true,
        "manual" : false,
        "slot" : "2026-10-14T17:46:40Z"
      }
    },
    {
      "detail" : "Found 3",
      "endedAt" : "2026-10-14T18:06:40Z",
      "id" : "33333333-3333-3333-3333-333333333333",
      "input" : {
        "prompt" : "Say hello"
      },
      "opened" : true,
      "startedAt" : "2026-10-14T18:01:40Z",
      "state" : "message",
      "steps" : [
        {
          "capability" : "claude",
          "name" : "claude",
          "pane" : "33333333-3333-3333-3333-333333333333"
        }
      ],
      "task" : "Claude prompt",
      "trigger" : {
        "automation" : "11111111-1111-1111-1111-111111111111",
        "late" : false,
        "manual" : true,
        "slot" : "2026-10-14T18:01:40Z"
      }
    },
    {
      "count" : 3,
      "detail" : "The last run was still going",
      "id" : "44444444-4444-4444-4444-444444444444",
      "input" : {
        "prompt" : "Say hello"
      },
      "opened" : false,
      "state" : "skipped",
      "steps" : [

      ],
      "task" : "Claude prompt",
      "trigger" : {
        "automation" : "11111111-1111-1111-1111-111111111111",
        "late" : false,
        "manual" : false,
        "slot" : "2026-10-14T18:16:40Z"
      }
    }
  ],
  "version" : 1
}
"""#
