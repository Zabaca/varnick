import Foundation
import VarnickPeer

// `make check-engine`: the language and the engine of Tasks (option 01 of `work-cant-be-saved-or-chained`, slice 2a) over a table of cases, with no
// Varnick, no clock, no model and no network: the check, the engine with fake adapters, a Judge with stub voices, the schema subset, `task_result`'s
// files in a scratch folder, and the runs file at versions 1, 2 and 3. Neither Varnick nor this package has a test target; this is how `check-slots`
// checks the slot function. One `error:` line a failed case, exit 1 if there was any.

var failures = 0
var cases = 0

func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    guard !ok else { return }
    failures += 1
    FileHandle.standardError.write(Data("error: check-engine: \(name)\(detail().isEmpty ? "" : ": " + detail())\n".utf8))
}

func J(_ text: String) -> TaskValue {
    guard let value = TaskValue(jsonText: text) else { fatalError("bad JSON in the table: \(text)") }
    return value
}

/// `base` with the value at a dotted path replaced (or removed when nil).
func edit(_ base: TaskValue, _ path: String, _ new: TaskValue?) -> TaskValue {
    func go(_ value: TaskValue, _ keys: ArraySlice<String>) -> TaskValue {
        guard let key = keys.first, var object = value.object else { return new ?? .null }
        if keys.count == 1 {
            object[key] = new
        } else {
            object[key] = go(object[key] ?? .object([:]), keys.dropFirst())
        }
        return .object(object)
    }
    return go(base, path.split(separator: ".").map(String.init)[...])
}

let t0 = Date(timeIntervalSince1970: 1_792_000_000)
let schemaText = J(#"{"type":"object","required":["text"],"properties":{"text":{"type":"string"}}}"#)

/// A Task that writes a haiku and has a judge say whether it is one.
let haiku = J(#"""
{
  "name": "Haiku",
  "description": "Writes a haiku until a judge says it is one",
  "input": {"type": "object", "required": ["topic"], "properties": {"topic": {"type": "string"}}},
  "result": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}},
  "start": "write",
  "steps": {
    "write": {"use": "claude", "with": {"prompt": "Write a haiku about {input.topic}."},
              "result": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}},
              "next": {"ok": "check", "failed": "fail"}},
    "check": {"use": "judge", "with": {"noul": "Is `text` a haiku about `topic`?", "state": {"text": "{steps.write.text}", "topic": "{input.topic}"}},
              "next": {"yes": "tell", "no": "write"}},
    "tell": {"use": "notify", "with": {"title": "Haiku ready", "body": "{steps.write.text}"}, "next": {"ok": "end"}}
  },
  "end": {"text": "{steps.write.text}"}
}
"""#)

func checked(_ value: TaskValue, library: TaskLibrary = .empty) -> TaskCheck { TaskDefinition.check(value, library: library) }

func problems(_ name: String, _ value: TaskValue, mention words: [String], library: TaskLibrary = .empty) {
    let found = checked(value, library: library)
    let text = found.problems.joined(separator: "\n")
    expect(name, found.definition == nil && !found.problems.isEmpty && words.allSatisfy { text.contains($0) }, "got: \(text.isEmpty ? "no problems" : text)")
}

// MARK: The schema subset

let subset = TaskSchema.read(J(#"""
{"type": "object", "description": "A shop", "required": ["site", "when"], "properties": {
  "site": {"type": "string", "format": "uri"}, "when": {"type": "string", "format": "date"}, "count": {"type": "integer"}, "price": {"type": "number"},
  "ok": {"type": "boolean"}, "kind": {"type": "string", "enum": ["a", "b"]}, "tags": {"type": "array", "items": {"type": "string"}},
  "inner": {"type": "object", "required": ["x"], "properties": {"x": {"type": "number"}}}}}
"""#), at: "input")
expect("the subset reads", subset.schema != nil && subset.problems.isEmpty, subset.problems.joined(separator: "; "))
if let schema = subset.schema {
    let good = J(#"{"site": "https://shop.example/a", "when": "2026-10-15", "count": 3, "price": 9.5, "ok": true, "kind": "a", "tags": ["x"], "inner": {"x": 1}}"#)
    expect("a value that fits has no problems", schema.problems(of: good).isEmpty, "\(schema.problems(of: good))")
    expect("an optional field may be nothing", schema.problems(of: edit(good, "count", .null)).isEmpty)
    let bad = schema.problems(of: J(#"{"site": "ftp://x", "when": "2026-02-30", "count": 1.5, "price": "9", "ok": "yes", "kind": "c", "tags": [1], "inner": {}, "extra": 1}"#))
    for word in ["site must be an http or https address", "when must be a date", "count must be a whole number", "price must be a number", "ok must be true or false",
                 "kind must be one of a, b", "tags[0] must be text", "inner.x is missing", "extra isn't a field"] {
        expect("a wrong value names \(word)", bad.contains { $0.contains(word) }, bad.joined(separator: "; "))
    }
    expect("a missing required field is named", schema.problems(of: J("{}")).sorted() == ["site is missing", "when is missing"], "\(schema.problems(of: J("{}")))")
    expect("a value that is not an object is refused", schema.problems(of: .text("x")).first?.contains("an object") == true)
    expect("the form lists required fields in required's order, then the rest by name",
           schema.formFields.map(\.name) == ["site", "when", "count", "inner", "kind", "ok", "price", "tags"], "\(schema.formFields.map(\.name))")
    expect("the form says which are required", schema.formFields.map(\.isRequired) == [true, true, false, false, false, false, false, false])
    let written = schema.value
    expect("it writes itself out as JSON Schema and reads back the same", TaskSchema.read(written, at: "x").schema == schema, "\(written.jsonText)")
    expect("the description is kept", schema.summary == "A shop" && (schema.jsonSchema["description"] as? String) == "A shop")
    expect("a form's text becomes the field's type", schema.properties["count"]!.value(fromText: " 4 ").value == .number(4)
           && schema.properties["ok"]!.value(fromText: "yes").value == .bool(true) && schema.properties["site"]!.value(fromText: "  ").value == nil
           && schema.properties["count"]!.value(fromText: "x").problem != nil)
}
for (name, text, word) in [
    ("a pattern", #"{"type": "string", "pattern": "x"}"#, "pattern isn't in the subset"),
    ("a reference", ##"{"$ref": "#/x"}"##, "$ref isn't in the subset"),
    ("a oneOf", #"{"oneOf": []}"#, "oneOf isn't in the subset"),
    ("a null type", #"{"type": "null"}"#, "isn't in the subset"),
    ("a format that is not uri or date", #"{"type": "string", "format": "email"}"#, "only uri and date"),
    ("an enum of numbers", #"{"type": "string", "enum": [1]}"#, "list of strings"),
    ("an array without items", #"{"type": "array"}"#, "items is required"),
    ("required naming a missing field", #"{"type": "object", "required": ["a"], "properties": {}}"#, "isn't in properties"),
    ("items on a string", #"{"type": "string", "items": {"type": "string"}}"#, "doesn't go with type string"),
    ("no type", #"{"description": "x"}"#, "type is required"),
] {
    let read = TaskSchema.read(J(text), at: "s")
    expect("the subset refuses \(name)", read.schema == nil && read.problems.contains { $0.contains(word) }, read.problems.joined(separator: "; "))
}
expect("an integer fits a number and an enum fits text", TaskSchema.number.accepts(TaskSchema(.integer)) && TaskSchema.text.accepts(TaskSchema(.choice(["a"])))
       && !TaskSchema(.integer).accepts(.number) && !TaskSchema.text.accepts(.number))
expect("a template's whole number has no decimal point", TaskValue.number(3).inText == "3" && TaskValue.number(2.5).inText == "2.5"
       && TaskValue.list([.number(1), .text("a")]).inText == #"[1,"a"]"# && TaskValue.object(["a": .bool(true)]).inText == #"{"a":true}"#)

// MARK: The check

let found = checked(haiku)
expect("the haiku Task is valid", found.isValid, found.problems.joined(separator: "; "))
expect("it names its capabilities and its depth", found.definition?.capabilities == [.claude, .judge, .notify] && found.definition?.depth == 0)
expect("its steps are listed in the order a walk meets them", found.definition?.stepOrder == ["write", "check", "tell"], "\(found.definition?.stepOrder ?? [])")

expect("a file that is not an object is refused", checked(.list([])).problems.first?.contains("one JSON object") == true)
problems("an unknown key", edit(haiku, "extra", .text("x")), mention: ["extra isn't a key of a Task"])
problems("no name", edit(haiku, "name", nil), mention: ["name is required"])
problems("a built-in's name", edit(haiku, "name", .text("Claude prompt")), mention: ["built-in Task's name"])
problems("a schema keyword outside the subset", edit(haiku, "input.properties.topic.pattern", .text("x")), mention: ["input.properties.topic.pattern", "isn't in the subset"])
problems("an input that is not an object", edit(haiku, "input", J(#"{"type": "string"}"#)), mention: ["input must be an object schema"])
problems("a start that is not a step", edit(haiku, "start", .text("nowhere")), mention: ["start names \"nowhere\""])
problems("an unknown capability", edit(haiku, "steps.write.use", .text("magic")), mention: ["steps.write.use is \"magic\""])
problems("a parameter the capability doesn't take", edit(haiku, "steps.tell.with.sound", .text("x")), mention: ["steps.tell.with.sound isn't a parameter of a Notify step"])
problems("a missing required parameter", edit(haiku, "steps.write.with.prompt", nil), mention: ["steps.write.with.prompt is required"])
problems("a result on a step that is not Claude's", edit(haiku, "steps.tell.result", schemaText), mention: ["only goes with a Claude step"])
problems("an edge to nowhere", edit(haiku, "steps.write.next.ok", .text("elsewhere")), mention: ["leads to \"elsewhere\", which isn't a step, end or fail"])
problems("a missing branch", edit(haiku, "steps.check.next.no", nil), mention: ["no edge for the outcome \"no\""])
problems("an edge for an outcome the step doesn't have", edit(haiku, "steps.write.next.maybe", .text("end")), mention: ["write has no outcome \"maybe\""])
problems("unsure on a step that is not a Judge", edit(haiku, "steps.write.next.unsure", .text("end")), mention: ["only goes with a Judge"])
problems("a step nothing leads to", edit(haiku, "steps.lonely", J(#"{"use": "notify", "with": {"title": "x"}, "next": {"ok": "end"}}"#)), mention: ["steps.lonely can't be reached"])
problems("a binding to an input field that isn't there", edit(haiku, "steps.write.with.prompt", .text("About {input.topc}")), mention: ["the input has no field \"topc\"", "its fields are topic"])
problems("a binding to a field the step doesn't give", edit(haiku, "end.text", .text("{steps.write.title}")), mention: ["step write gives no field \"title\"", "it gives text"])
problems("a binding to a step that doesn't exist", edit(haiku, "end.text", .text("{steps.zzz.text}")), mention: ["there is no step \"zzz\""])
problems("a binding to a step that has not run yet", edit(haiku, "steps.write.with.prompt", .text("{steps.check.probability}")), mention: ["step check might not have a result before this point"])
problems("a binding that is not one", edit(haiku, "steps.write.with.prompt", .text("About {inputs.topic}")), mention: ["{inputs.topic} isn't a binding"])
expect("braces around something that is not a dotted word are text", checked(edit(haiku, "steps.write.with.prompt", .text(#"Reply as {"a": 1} about {input.topic}"#))).isValid)
problems("a number where text is wanted in the result", edit(haiku, "end.text", .number(3)), mention: ["end.text must be text"])
problems("a result field the end leaves out", edit(haiku, "end.text", nil), mention: ["end.text is missing"])
problems("a result field the schema doesn't have", edit(haiku, "end.extra", .text("x")), mention: ["end.extra isn't a field"])
problems("no step leads to end", edit(haiku, "steps.tell.next.ok", .text("fail")), mention: ["end can't be reached"])
problems("a Website step arrives in the next build",
         edit(haiku, "steps.look", J(#"{"use": "website", "with": {"site": "https://x.example", "goal": "g"}, "next": {"found": "end", "finished": "end", "gave up": "fail"}}"#)),
         mention: ["steps.look: Website steps arrive in the next build"])
problems("a Score question isn't in this build", edit(haiku, "steps.check.with", J(#"{"score": "How good?", "state": {}}"#)), mention: ["Score question isn't in this build"])
problems("a Judge with two questions", edit(haiku, "steps.check.with.choice", .text("x")), mention: ["exactly one question"])
let choiceWith = #"{"choice": "Which?", "options": [{"label": "a", "criterion": "is a"}, {"label": "b", "criterion": "is b"}], "state": {}}"#
expect("a Choice judge is valid with its labels as edges",
       checked(edit(edit(haiku, "steps.check.with", J(choiceWith)), "steps.check.next", J(#"{"a": "tell", "b": "write"}"#))).isValid)
problems("a Choice label used twice", edit(edit(haiku, "steps.check.with", J(#"{"choice": "Which?", "options": [{"label": "a", "criterion": "x"}, {"label": "a", "criterion": "y"}]}"#)),
                                          "steps.check.next", J(#"{"a": "tell"}"#)), mention: ["used twice or reserved"])
problems("a Choice label that is reserved", edit(edit(haiku, "steps.check.with", J(#"{"choice": "Which?", "options": [{"label": "else", "criterion": "x"}]}"#)),
                                               "steps.check.next", J(#"{"else": "tell"}"#)), mention: ["used twice or reserved"])

// else never catches failed, and a failed outcome with no edge travels up: both are valid files.
let elseTask = edit(edit(haiku, "steps.write.next", J(#"{"ok": "check", "else": "fail"}"#)), "steps.check.next", J(#"{"yes": "tell", "else": "write"}"#))
expect("else covers an outcome, and failed needs no edge", checked(elseTask).isValid, checked(elseTask).problems.joined(separator: "; "))

// A field on one path only: two steps that each give a different field, and a step after both.
let branching = J(#"""
{
  "name": "Branching",
  "description": "x",
  "input": {"type": "object", "properties": {"a": {"type": "string"}}},
  "result": {"type": "object", "required": ["r"], "properties": {"r": {"type": "string"}, "note": {"type": "string"}}},
  "start": "ask",
  "steps": {
    "ask": {"use": "judge", "with": {"noul": "Is it so?"}, "next": {"yes": "left", "no": "right"}},
    "left": {"use": "claude", "with": {"prompt": "left"}, "result": {"type": "object", "required": ["x"], "properties": {"x": {"type": "string"}, "opt": {"type": "string"}}}, "next": {"ok": "join"}},
    "right": {"use": "claude", "with": {"prompt": "right"}, "result": {"type": "object", "required": ["y"], "properties": {"y": {"type": "string"}, "opt": {"type": "string"}}}, "next": {"ok": "join"}},
    "join": {"use": "notify", "with": {"title": "joined"}, "next": {"ok": "end"}}
  },
  "end": {"r": "done"}
}
"""#)
expect("branches that each give a field are valid when nothing reads it", checked(branching).isValid, checked(branching).problems.joined(separator: "; "))
problems("a binding to a step on one path only", edit(branching, "end.r", .text("{steps.left.x}")), mention: ["step left might not have a result before this point"])
problems("a binding to a step on one path only, in text", edit(branching, "steps.join.with.title", .text("got {steps.right.y}")), mention: ["step right might not have a result"])
let optionalField = edit(edit(haiku, "steps.write.result", J(#"{"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}, "note": {"type": "string"}}}"#)),
                         "result", J(#"{"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}, "note": {"type": "string"}}}"#))
expect("a field that may be absent goes into an optional field", checked(edit(optionalField, "end.note", .text("{steps.write.note}"))).isValid,
       checked(edit(optionalField, "end.note", .text("{steps.write.note}"))).problems.joined(separator: "; "))
problems("a field that may be absent doesn't go into a required one", edit(optionalField, "end.text", .text("{steps.write.note}")), mention: ["may have no value", "can't be left out"])
problems("a field that may be absent doesn't go inside text", edit(optionalField, "steps.tell.with.body", .text("Note: {steps.write.note}")), mention: ["may have no value, so it can't go inside text"])
expect("a field that may be absent goes into Judge state and Notify's body", checked(edit(edit(optionalField, "steps.check.with.state.note", .text("{steps.write.note}")),
                                                                                         "steps.tell.with.body", .text("{steps.write.note}"))).isValid)

// Sub-tasks.
let child = J(#"""
{
  "name": "Child", "description": "x",
  "input": {"type": "object", "required": ["n"], "properties": {"n": {"type": "integer"}, "label": {"type": "string"}}},
  "result": {"type": "object", "required": ["twice"], "properties": {"twice": {"type": "number"}, "note": {"type": "string"}}},
  "start": "go",
  "steps": {"go": {"use": "claude", "with": {"prompt": "Double {input.n}"}, "result": {"type": "object", "required": ["twice"], "properties": {"twice": {"type": "number"}}}, "next": {"ok": "end"}}},
  "end": {"twice": "{steps.go.twice}"}
}
"""#)
func parent(taskName: String = "Child", input: String = #"{"n": 2}"#, end: String = #"{"total": "{steps.sub.twice}"}"#) -> TaskValue {
    J(#"{"name": "Parent", "description": "x", "input": {"type": "object", "properties": {"count": {"type": "integer"}, "word": {"type": "string"}}}, "#
      + #""result": {"type": "object", "required": ["total"], "properties": {"total": {"type": "number"}}}, "start": "sub", "steps": {"sub": {"use": "task", "#
      + #""with": {"task": ""# + taskName + #"", "input": "# + input + #"}, "next": {"ok": "end", "failed": "fail"}}}, "end": "# + end + "}")
}
let library = TaskLibrary { $0 == "Child" ? child : nil }
expect("a Task that runs a sub-task is valid", checked(parent(), library: library).isValid, checked(parent(), library: library).problems.joined(separator: "; "))
expect("and its depth is one", checked(parent(), library: library).definition?.depth == 1 && checked(parent(), library: library).definition?.subTasks == ["Child"])
expect("a binding into the child's input keeps its type: an integer fits, and an optional one can't go into a required field",
       checked(parent(input: #"{"n": "{input.count}"}"#), library: library).problems.contains { $0.contains("may have no value") }
       && !checked(parent(input: #"{"n": "{input.count}"}"#), library: library).problems.contains { $0.contains("is needed") })
problems("a child input of the wrong type", parent(input: #"{"n": "{input.word}"}"#), mention: ["{input.word} is text, and a whole number is needed"], library: library)
problems("a child input field the child doesn't have", parent(input: #"{"n": 1, "zzz": 2}"#), mention: ["zzz isn't a field here"], library: library)
problems("a child input field it needs and isn't given", parent(input: "{}"), mention: ["n is missing"], library: library)
problems("a sub-task that doesn't exist", parent(taskName: "Nope"), mention: ["no Task is called \"Nope\""], library: library)
problems("a built-in as a sub-task", parent(taskName: "Claude prompt"), mention: ["Claude prompt is a built-in Task"], library: library)
problems("a binding to a field the child doesn't give", parent(end: #"{"total": "{steps.sub.zzz}"}"#), mention: ["step sub gives no field \"zzz\""], library: library)
let cycleA = parent(taskName: "Parent")
problems("a Task that runs itself", cycleA, mention: ["reaches itself", "Parent → Parent"], library: library)
let ping = edit(edit(parent(taskName: "Pong"), "name", .text("Ping")), "steps.sub.with.input", .object([:]))
let pong = edit(edit(parent(taskName: "Ping"), "name", .text("Pong")), "steps.sub.with.input", .object([:]))
let pingLibrary = TaskLibrary { $0 == "Ping" ? ping : $0 == "Pong" ? pong : nil }
problems("two Tasks that run each other", ping, mention: ["reaches itself"], library: pingLibrary)
func nested(_ name: String, calls next: String?) -> TaskValue {
    // L4 is the Child Task, which needs `n`.
    let input: TaskValue = next == "L4" ? J(#"{"n": 1}"#) : .object([:])
    var value = next.map { edit(edit(parent(taskName: $0), "steps.sub.with.input", input), "name", .text(name)) } ?? edit(child, "name", .text(name))
    if next != nil { value = edit(value, "end", J(#"{"total": 1}"#)) }
    return value
}
let chain = ["L0": nested("L0", calls: "L1"), "L1": nested("L1", calls: "L2"), "L2": nested("L2", calls: "L3"), "L3": nested("L3", calls: "L4"), "L4": nested("L4", calls: nil)]
let deepLibrary = TaskLibrary { chain[$0] }
expect("sub-tasks 3 deep are valid", checked(chain["L1"]!, library: deepLibrary).definition?.depth == 3,
       checked(chain["L1"]!, library: deepLibrary).problems.joined(separator: "; "))
problems("sub-tasks 4 deep are refused", chain["L0"]!, mention: ["4 deep: the limit is 3"], library: deepLibrary)
problems("an invalid sub-task shows its problem", parent(), mention: ["sub-task Child"], library: TaskLibrary { $0 == "Child" ? edit(child, "start", .text("zzz")) : nil })

// A nameless file found under a name, naming itself or a Task above it as a sub-task, is a cycle and not a stack overflow.
let nameless = J(#"""
{"description": "x", "input": {"type": "object"}, "result": {"type": "object"}, "start": "again",
 "steps": {"again": {"use": "task", "with": {"task": "loop"}, "next": {"ok": "end", "failed": "fail"}}}, "end": {}}
"""#)
let namelessCheck = TaskDefinition.check(nameless, library: TaskLibrary { $0 == "loop" ? nameless : nil }, foundAs: "loop")
expect("a nameless file that names itself is a cycle", namelessCheck.problems.contains { $0.contains("reaches itself") } && namelessCheck.problems.contains { $0.contains("name is required") },
       namelessCheck.problems.joined(separator: "; "))
let namelessDeeper = TaskDefinition.check(edit(nameless, "steps.again.with.task", .text("other")),
                                          library: TaskLibrary { $0 == "loop" ? edit(nameless, "steps.again.with.task", .text("other")) : $0 == "other" ? edit(nameless, "steps.again.with.task", .text("loop")) : nil },
                                          foundAs: "loop")
expect("and so is two nameless files that name each other", namelessDeeper.problems.contains { $0.contains("reaches itself") }, namelessDeeper.problems.joined(separator: "; "))
// A wide tree of sub-tasks that all name the same ones is read once for each, not once for each path to it.
var layers: [String: TaskValue] = [:]
for level in 0..<12 {
    let calls = level == 11 ? nil : "T\(level + 1)"
    var steps: [String: TaskValue] = [:]
    for step in 0..<3 {
        steps["s\(step)"] = calls.map { J(#"{"use": "task", "with": {"task": ""# + $0 + #""}, "next": {"ok": "s\#(step + 1)", "failed": "fail"}}"#) }
            ?? J(#"{"use": "notify", "with": {"title": "x"}, "next": {"ok": "end"}}"#)
    }
    steps["s3"] = J(#"{"use": "notify", "with": {"title": "x"}, "next": {"ok": "end"}}"#)
    layers["T\(level)"] = .object(["name": .text("T\(level)"), "description": .text("x"), "input": J(#"{"type": "object"}"#), "result": J(#"{"type": "object"}"#),
                                  "start": .text("s0"), "steps": .object(steps), "end": .object([:])])
}
let started = Date()
let wide = TaskDefinition.check(layers["T0"]!, library: TaskLibrary { layers[$0] }, foundAs: "T0")
expect("a tree of sub-tasks 12 deep is refused quickly, not walked", wide.definition == nil && wide.problems.contains { $0.contains("deep: the limit is 3") }
       && Date().timeIntervalSince(started) < 2, "\(wide.problems.first ?? "") \(Date().timeIntervalSince(started)) s")
expect("an object doesn't fit a child's input that lacks one of its fields",
       !TaskSchema.object(["a": .text]).accepts(.object(["a": .text, "b": .text])) && TaskSchema.object(["a": .text, "b": .text]).accepts(.object(["a": .text])))
expect("a problem doesn't quote a long value of the file", {
    let long = String(repeating: "x", count: 200)
    return checked(edit(haiku, "steps.write.use", .text(long))).problems.joined().count < 400 && !checked(edit(haiku, "steps.write.use", .text(long))).problems.joined().contains(long)
}())

// MARK: Bindings

let context = TaskTemplate.Context(input: ["n": .number(3), "list": .list([.number(1)]), "word": .text("hi")], steps: ["a": ["x": .object(["k": .bool(true)])]])
expect("a text that is one binding keeps the field's type", TaskTemplate.resolve(.text("{input.n}"), in: context) == .value(.number(3)))
expect("asked as text it is written as text", TaskTemplate.resolve(.text("{input.n}"), in: context, asText: true) == .value(.text("3")))
expect("a binding inside text is written as text: a whole number with no decimal point, a list or an object as JSON",
       TaskTemplate.resolve(.text("n={input.n} l={input.list} x={steps.a.x} w={input.word}"), in: context) == .value(.text(#"n=3 l=[1] x={"k":true} w=hi"#)))
expect("a field with no value is absent, and left out of an object", TaskTemplate.resolve(.text("{input.nothing}"), in: context) == .absent
       && TaskTemplate.resolve(.object(["a": .text("{input.nothing}"), "b": .text("{input.word}")]), in: context) == .value(.object(["b": .text("hi")])))
expect("absent inside text is a failure", { if case .failure = TaskTemplate.resolve(.text("x {input.nothing}"), in: context) { return true } else { return false } }())

// MARK: The engine

let clock = t0
struct Sim {
    var run: TaskRun
    var commands: [TaskEngine.Command] = []
    var all: [TaskEngine.Command] = []

    /// `trusting` skips the check, for a Task the check would refuse (it never ends) but the engine must still bound.
    init?(_ task: TaskValue, input: [String: TaskValue], library: TaskLibrary = .empty, depth: Int = 0, limit: Int = 60, trusting: Bool = false) {
        guard let definition = trusting ? TaskDefinition.trusted(task) : TaskDefinition.check(task, library: library).definition,
              case .success(let advance) = TaskEngine.begin(definition, raw: task, input: input, trigger: .byHand(at: clock), folder: "/work", limitMinutes: limit,
                                                           depth: depth, now: clock) else { return nil }
        run = advance.run
        commands = advance.commands
        all = advance.commands
    }

    mutating func send(_ event: TaskEngine.Event) {
        let advance = TaskEngine.advance(run, event, now: clock)
        run = advance.run
        commands = advance.commands
        all += advance.commands
    }

    var step: TaskRunStep? { run.steps.last }
    var started: TaskEngine.Command? { commands.first { if case .startStep = $0 { true } else { false } } }
    var child: TaskEngine.Command? { commands.first { if case .startChild = $0 { true } else { false } } }
    var ended: RunState? { commands.compactMap { if case .end(let state) = $0 { state } else { nil } }.first }
}

if var sim = Sim(haiku, input: ["topic": .text("autumn")]) {
    expect("a new Run starts its first step", sim.run.state == .running && sim.run.steps.count == 1 && sim.run.steps[0].name == "write" && sim.run.steps[0].state == .started)
    if case .startStep(let entry, let name, let capability, let with, let result, _)? = sim.started {
        expect("the command carries the step with its prompt resolved and its result schema",
               entry == 0 && name == "write" && capability == .claude && with["prompt"] == .text("Write a haiku about autumn.") && result != nil, "\(with)")
    } else {
        expect("the first command starts the step", false, "\(sim.commands)")
    }
    expect("the Run keeps a copy of its Task, its input and its limit", sim.run.definition == haiku && sim.run.input["topic"] == .text("autumn") && sim.run.limitMinutes == 60
           && sim.run.folder == "/work" && sim.run.trigger.origin == .hand && sim.run.trigger.automation == nil)
    sim.send(.attached(pane: UUID(uuidString: "55555555-5555-5555-5555-555555555555"), child: nil, launch: RunLaunch(folder: "/work", agent: nil, skipPermissions: false, dontAsk: false, allowedTools: [])))
    expect("a pane's id goes on its step", sim.step?.pane?.uuidString == "55555555-5555-5555-5555-555555555555" && sim.step?.launch?.folder == "/work")
    sim.send(.waiting("Needs permission"))
    expect("a step that waits on the person makes the Run wait", sim.run.state == .waiting && sim.step?.state == .waiting && sim.run.detail == "Needs permission")
    sim.send(.waiting(nil))
    expect("and goes on when it no longer does", sim.run.state == .running && sim.step?.state == .started && sim.run.detail == nil)
    sim.send(.outcome("ok", result: J(#"{"text": "leaves fall slowly down"}"#), actor: "Claude"))
    expect("a result moves onto the step and the judge starts", sim.run.steps[0].state == .done && sim.run.steps[0].result == J(#"{"text": "leaves fall slowly down"}"#)
           && sim.step?.name == "check")
    if case .startStep(_, _, let capability, let with, _, let decides)? = sim.started {
        expect("the Judge's question is resolved from the earlier step", capability == .judge && with["noul"] == .text("Is `text` a haiku about `topic`?")
               && with["state"] == J(#"{"text": "leaves fall slowly down", "topic": "autumn"}"#) && decides, "\(with)")
    } else {
        expect("the next command starts the Judge", false, "\(sim.commands)")
    }
    sim.send(.outcome("no", reason: "Jev picked no (0.12)", actor: "Jev", probability: 0.12))
    expect("a no goes back to write: every visit is an entry of its own", sim.run.steps.map(\.name) == ["write", "check", "write"] && sim.run.steps[1].outcome == "no"
           && sim.run.steps[1].result == J(#"{"probability": 0.12}"#) && sim.step?.state == .started)
    sim.send(.outcome("ok", result: J(#"{"text": "second try"}"#), actor: "Claude"))
    sim.send(.outcome("yes", reason: "Jev picked yes (0.93)", actor: "Jev", probability: 0.93))
    expect("a binding reads the latest visit", sim.step?.name == "tell" && sim.step?.state == .sending)
    if case .startStep(_, _, let capability, let with, _, _)? = sim.started {
        expect("the Notify step is recorded as sending, with its body from the latest result", capability == .notify && with["body"] == .text("second try")
               && with["title"] == .text("Haiku ready"), "\(with)")
    } else {
        expect("the next command starts the Notify", false, "\(sim.commands)")
    }
    sim.send(.outcome("ok", reason: "Told you: Haiku ready", actor: "Harness"))
    expect("a Notify step is recorded as sent, and the Run ends with its result", sim.run.steps.last?.state == .sent && sim.run.state == .done
           && sim.run.result == J(#"{"text": "second try"}"#) && sim.run.endedAt == clock && sim.ended == .done)
    expect("every pass is on record, in lines marked with who acted", sim.run.lines.map(\.actor) == ["Claude", "Jev", "Claude", "Jev", "Harness"], "\(sim.run.lines.map(\.actor))")
    expect("a Judge's line is what it said", sim.run.lines[1].text == "Jev picked no (0.12)" && sim.run.lines[3].text == "Jev picked yes (0.93)")
    sim.send(.outcome("ok"))
    expect("an ended Run takes no more events", sim.run.state == .done && sim.commands.isEmpty)
} else {
    expect("the haiku Run starts", false)
}

expect("a Run is refused for an input that doesn't fit, naming each field", {
    let definition = found.definition!
    if case .failure(let refusal) = TaskEngine.begin(definition, raw: haiku, input: ["topic": .number(3), "x": .text("y")], trigger: .byHand(at: clock), folder: nil,
                                                    limitMinutes: 60, now: clock) {
        return refusal.problems.contains { $0.contains("topic must be text") } && refusal.problems.contains { $0.contains("x isn't a field") }
    }
    return false
}())

// failed and else: a failed outcome takes its own edge or fails the Run, and else never catches it.
if var sim = Sim(haiku, input: ["topic": .text("x")]) {
    sim.send(.outcome("failed", reason: "boom"))
    expect("a failed Claude step takes its failed edge, and that fails the Run with the step and the reason", sim.run.state == .failed && sim.run.detail == "Failed at write: boom"
           && sim.ended == .failed && sim.run.steps[0].state == .failed, "\(sim.run.detail ?? "")")
}
let noFailedEdge = edit(haiku, "steps.write.next", J(#"{"ok": "check", "else": "tell"}"#))
if var sim = Sim(noFailedEdge, input: ["topic": .text("x")]) {
    sim.send(.outcome("failed", reason: "boom"))
    expect("else doesn't catch failed: with no failed edge the Run fails with the reason", sim.run.state == .failed && sim.run.detail == "Failed at write: boom", "\(sim.run.state) \(sim.run.detail ?? "")")
}
if var sim = Sim(elseTask, input: ["topic": .text("x")]) {
    sim.send(.outcome("ok", result: J(#"{"text": "t"}"#)))
    sim.send(.outcome("no"))
    expect("else catches an outcome with no edge of its own", sim.step?.name == "write" && sim.run.steps.count == 3, "\(sim.run.steps.map(\.name))")
}
if var sim = Sim(haiku, input: ["topic": .text("x")]) {
    sim.send(.outcome("ok", result: J(#"{"text": "t"}"#)))
    sim.send(.outcome("failed", reason: "nobody answered", actor: "Harness"))
    expect("a Judge that failed with no failed edge fails the Run", sim.run.state == .failed && sim.run.detail == "Failed at check: nobody answered", "\(sim.run.detail ?? "")")
}
let failEdge = edit(haiku, "steps.check.next.no", .text("fail"))
if var sim = Sim(failEdge, input: ["topic": .text("x")]) {
    sim.send(.outcome("ok", result: J(#"{"text": "t"}"#)))
    sim.send(.outcome("no", actor: "Jev", probability: 0.1))
    expect("an edge to fail ends the Run failed with the step and the outcome", sim.run.state == .failed && sim.run.detail == "Failed at check: no", "\(sim.run.detail ?? "")")
}
if var sim = Sim(haiku, input: ["topic": .text("x")]) {
    sim.send(.outcome("ok", result: J(#"{"title": "wrong"}"#)))
    expect("a Claude result that doesn't fit its schema fails the step, naming the fields", sim.run.state == .failed && (sim.run.detail ?? "").contains("text is missing") && (sim.run.detail ?? "").contains("title isn't a field"), "\(sim.run.detail ?? "")")
}
if var sim = Sim(haiku, input: ["topic": .text("x")]) {
    sim.send(.outcome("teleported"))
    expect("an outcome the step doesn't have fails it", sim.run.state == .failed && (sim.run.detail ?? "").contains("teleported"), "\(sim.run.detail ?? "")")
}

// A Judge with a Choice: the label is the branch and its fields are readable.
let choiceTask = edit(edit(haiku, "steps.check.with", J(choiceWith)), "steps.check.next", J(#"{"a": "tell", "b": "write", "unsure": "fail"}"#))
expect("a Choice Task with an unsure edge is valid", checked(choiceTask).isValid, checked(choiceTask).problems.joined(separator: "; "))
if var sim = Sim(choiceTask, input: ["topic": .text("x")]) {
    sim.send(.outcome("ok", result: J(#"{"text": "t"}"#)))
    if case .startStep(_, _, _, let with, _, let decides)? = sim.started {
        expect("a Task that names unsure keeps Claude from deciding; the options keep their order", !decides && with["options"]?.list?.compactMap { $0.object?["label"]?.text } == ["a", "b"])
    } else {
        expect("the Choice Judge starts", false)
    }
    sim.send(.outcome("unsure", actor: "Jev"))
    expect("unsure takes the unsure edge", sim.run.state == .failed && sim.run.detail == "Failed at check: unsure", "\(sim.run.detail ?? "")")
}
if var sim = Sim(choiceTask, input: ["topic": .text("x")]) {
    sim.send(.outcome("ok", result: J(#"{"text": "t"}"#)))
    sim.send(.outcome("a", actor: "Jev", probability: 0.8))
    expect("a Choice's label and probability are the step's result", sim.run.steps[1].result == J(#"{"label": "a", "probability": 0.8}"#) && sim.step?.name == "tell")
}

// The bounds.
let spin = J(#"""
{"name": "Spin", "description": "x", "input": {"type": "object"}, "result": {"type": "object"}, "start": "a",
 "steps": {"a": {"use": "notify", "with": {"title": "x"}, "next": {"ok": "a"}}}, "end": {}}
"""#)
expect("a Task that only loops is valid but can't reach end", checked(spin).problems.contains { $0.contains("end can't be reached") })
let spinning = edit(spin, "steps.a.next.ok", .text("b"))
let spinTask = edit(edit(spinning, "steps.b", J(#"{"use": "notify", "with": {"title": "y"}, "next": {"ok": "a", "else": "end"}}"#)), "steps.a.next", J(#"{"ok": "b"}"#))
if var sim = Sim(spinTask, input: [:], trusting: true) {
    var guardCount = 0
    while sim.run.state == .running, guardCount < 200 {
        sim.send(.outcome("ok"))
        guardCount += 1
    }
    expect("a loop is bounded at 50 steps", sim.run.state == .failed && sim.run.detail == "Reached its limit of 50 steps" && sim.run.steps.count == 50, "\(sim.run.steps.count) \(sim.run.detail ?? "")")
} else {
    expect("the looping Task starts", false)
}
if var sim = Sim(haiku, input: ["topic": .text("x")], limit: 5) {
    sim.send(.attached(pane: UUID(), child: nil, launch: nil))
    sim.send(.worked(200))
    sim.send(.worked(101))
    expect("working time only counts: the host says when the budget is out", sim.run.state == .running && sim.run.awake == 301 && sim.commands.isEmpty)
    sim.send(.limitPassed(minutes: 5))
    expect("a Run that works past the budget fails with that reason and stops its step", sim.run.state == .failed && sim.run.detail == "Worked past 5 minutes"
           && sim.commands.contains(.stopStep(entry: 0)) && sim.ended == .failed, "\(sim.run.detail ?? "") \(sim.commands)")
}
if var sim = Sim(haiku, input: ["topic": .text("x")]) {
    sim.send(.stop())
    expect("Stop stops the step and ends the Run stopped, saying the person did", sim.run.state == .stopped && sim.run.detail == "Stopped by you"
           && sim.commands == [.stopStep(entry: 0), .end(.stopped)] && sim.run.steps[0].outcome == "stopped", "\(sim.commands)")
}

// Sub-tasks: a child Run is the step's outcome.
if var sim = Sim(parent(), input: [:], library: library) {
    expect("a Task step starts a child with its input resolved", { if case .startChild(0, "Child", let input)? = sim.child { input == ["n": .number(2)] } else { false } }(), "\(sim.commands)")
    let childID = UUID()
    sim.send(.attached(pane: nil, child: childID, launch: nil))
    expect("the child's id goes on the step", sim.step?.child == childID)
    sim.send(.childEnded(child: UUID(), state: .done, result: J(#"{"twice": 4}"#), reason: nil))
    expect("a child's end that is not this step's child changes nothing", sim.run.state == .running && sim.commands.isEmpty && sim.step?.state == .started)
    sim.send(.childEnded(child: childID, state: .done, result: J(#"{"twice": 4}"#), reason: nil))
    expect("a child that ended with a result is the step's ok, and its fields are readable", sim.run.state == .done && sim.run.result == J(#"{"total": 4}"#) && sim.run.steps[0].result == J(#"{"twice": 4}"#), "\(sim.run.state) \(sim.run.detail ?? "")")
}
if var sim = Sim(parent(), input: [:], library: library) {
    let childID = UUID()
    sim.send(.attached(pane: nil, child: childID, launch: nil))
    sim.send(.childEnded(child: childID, state: .failed, result: nil, reason: "Failed at go: boom"))
    expect("a failed child fails the parent's step with the child's reason", sim.run.state == .failed && sim.run.detail == "Failed at sub: Failed at go: boom", "\(sim.run.detail ?? "")")
}
let forgiving = edit(parent(), "steps.sub.next", J(#"{"ok": "end", "failed": "recover"}"#))
let recovering = edit(edit(forgiving, "steps.recover", J(#"{"use": "notify", "with": {"title": "child failed: {steps.sub.zzz}"}, "next": {"ok": "end"}}"#)), "end", J(#"{"total": 0}"#))
expect("a parent may name where a failed child goes", checked(edit(recovering, "steps.recover.with.title", .text("child failed")), library: library).isValid,
       checked(edit(recovering, "steps.recover.with.title", .text("child failed")), library: library).problems.joined(separator: "; "))
if var sim = Sim(edit(recovering, "steps.recover.with.title", .text("child failed")), input: [:], library: library) {
    let childID = UUID()
    sim.send(.attached(pane: nil, child: childID, launch: nil))
    sim.send(.childEnded(child: childID, state: .stopped, result: nil, reason: nil))
    expect("a stopped child is failed to its parent, which takes its failed edge", sim.run.state == .running && sim.step?.name == "recover", "\(sim.run.state) \(sim.step?.name ?? "")")
}

// Stop through a tree: the parent's stop names the child to stop, and the host stops it the same way.
if var parentSim = Sim(parent(), input: [:], library: library) {
    let childID = UUID()
    parentSim.send(.attached(pane: nil, child: childID, launch: nil))
    parentSim.send(.stop())
    expect("Stop on a parent stops its step and its child, with the person's reason", parentSim.run.state == .stopped
           && parentSim.commands == [.stopStep(entry: 0), .stopChild(childID, reason: "Stopped by you"), .end(.stopped)], "\(parentSim.commands)")
    var failing = Sim(parent(), input: [:], library: library)!
    failing.send(.attached(pane: nil, child: childID, launch: nil))
    failing.send(.limitPassed(minutes: 60))
    expect("a parent that fails stops its child with its own reason, not the person's", failing.commands.contains(.stopChild(childID, reason: "Worked past 60 minutes")), "\(failing.commands)")
    var budget = Sim(parent(), input: [:], library: library)!
    budget.send(.attached(pane: nil, child: childID, launch: nil))
    budget.send(.worked(4000))
    expect("a parent whose child works only counts the time and does not fail over it", budget.run.state == .running && budget.run.awake == 4000 && budget.commands.isEmpty)
    budget.send(.childEnded(child: childID, state: .failed, result: nil, reason: "Worked past 60 minutes"))
    expect("the child's limit reaches the parent as its step's failed, which the parent's Task may take",
           budget.run.state == .failed && budget.run.detail == "Failed at sub: Worked past 60 minutes", "\(budget.run.detail ?? "")")
}

// Depth: a child can be 3 deep, and no deeper.
let reachDeep = Sim(parent(), input: [:], library: library, depth: 3)
expect("a Task step at the depth limit fails the Run", reachDeep?.run.state == .failed && (reachDeep?.run.detail ?? "").contains("nest 3 deep at most"), "\(reachDeep?.run.detail ?? "")")
let tooDeep = TaskEngine.begin(checked(haiku).definition!, raw: haiku, input: ["topic": .text("x")], trigger: .byHand(at: clock), folder: nil, limitMinutes: 60, depth: 4, now: clock)
expect("a Run 4 deep is refused", { if case .failure = tooDeep { true } else { false } }())
expect("a child Run at depth 3 starts and is marked", Sim(haiku, input: ["topic": .text("x")], depth: 3)?.run.depth == 3 && Sim(haiku, input: ["topic": .text("x")])?.run.depth == nil)

// Absent values: decision 5.
let absentTask = J(#"""
{"name": "Absent", "description": "x", "input": {"type": "object", "properties": {"nick": {"type": "string"}, "n": {"type": "number"}}},
 "result": {"type": "object", "required": ["line"], "properties": {"line": {"type": "string"}, "nick": {"type": "string"}, "n": {"type": "number"}}},
 "start": "s", "steps": {"s": {"use": "notify", "with": {"title": "t", "body": "{input.nick}"}, "next": {"ok": "end"}}},
 "end": {"line": "n is {input.n}", "nick": "{input.nick}", "n": "{input.n}"}}
"""#)
expect("a binding to an optional input is valid only where it can be left out", checked(absentTask).problems.contains { $0.contains("end.line: {input.n} may have no value, so it can't go inside text") },
       checked(absentTask).problems.joined(separator: "; "))
let absentFixed = edit(absentTask, "end.line", .text("fixed"))
if var sim = Sim(absentFixed, input: ["n": .number(3)]) {
    expect("an absent optional body is left out of the step's input", { if case .startStep(_, _, _, let with, _, _)? = sim.started { with["body"] == nil && with["title"] == .text("t") } else { false } }())
    sim.send(.outcome("ok"))
    expect("and an absent field is left out of the result; a number stays a number", sim.run.result == J(#"{"line": "fixed", "n": 3}"#), "\(sim.run.result?.jsonText ?? "")")
}

// Restarts: a restart in each step state, with fake adapters.
func claudeRun(_ task: TaskValue = haiku) -> Sim? {
    guard var sim = Sim(task, input: ["topic": .text("x")]) else { return nil }
    sim.send(.attached(pane: UUID(), child: nil, launch: nil))
    return sim
}
if var sim = claudeRun() {
    sim.send(.restarted(.init(paneBack: true)))
    expect("a Claude step whose pane is back is reattached: nothing changes", sim.run.steps == claudeRun()!.run.steps.map { var s = $0; s.pane = sim.run.steps[0].pane; return s } && sim.commands.isEmpty && sim.run.state == .running)
}
if var sim = claudeRun() {
    sim.send(.restarted(.init(paneBack: false)))
    expect("a Claude step whose session is gone fails with \"the session had ended\"", sim.run.state == .failed && sim.run.detail == "Failed at write: the session had ended", "\(sim.run.detail ?? "")")
}
if var sim = claudeRun() {
    sim.send(.restarted(.init(paneBack: false, result: J(#"{"text": "from the file"}"#))))
    expect("but its result file is taken if it is there", sim.run.steps[0].result == J(#"{"text": "from the file"}"#) && sim.step?.name == "check")
}
if var sim = claudeRun() {
    sim.send(.outcome("ok", result: J(#"{"text": "t"}"#)))
    sim.send(.restarted(.init()))
    expect("a Judge that was waiting for an answer is asked again", { if case .startStep(1, "check", .judge, _, _, _)? = sim.started { true } else { false } }() && sim.run.steps.count == 2, "\(sim.commands)")
}
if var sim = claudeRun() {
    sim.send(.outcome("ok", result: J(#"{"text": "t"}"#)))
    sim.send(.outcome("yes", actor: "Jev", probability: 0.9))
    sim.send(.restarted(.init()))
    expect("a Notify still marked sending counts as sent and is not sent again", sim.run.state == .done && sim.run.steps.last?.state == .sent && sim.started == nil, "\(sim.commands)")
}
if var sim = Sim(parent(), input: [:], library: library) {
    let childID = UUID()
    sim.send(.attached(pane: nil, child: childID, launch: nil))
    sim.send(.restarted(.init(child: .going)))
    expect("a child that goes follows its own rules", sim.run.state == .running && sim.commands.isEmpty)
    sim.send(.restarted(.init(child: .ended(state: .done, result: J(#"{"twice": 8}"#), reason: nil))))
    expect("a child that ended meanwhile is the step's outcome", sim.run.state == .done && sim.run.result == J(#"{"total": 8}"#))
}
if var sim = Sim(parent(), input: [:], library: library) {
    sim.send(.attached(pane: nil, child: UUID(), launch: nil))
    sim.send(.restarted(.init(child: nil)))
    expect("a child Run that was lost fails the step", sim.run.state == .failed && (sim.run.detail ?? "").contains("lost"), "\(sim.run.detail ?? "")")
}

// Website: its outcomes and its restart rule are in the engine already, though the check refuses the step.
let siteRaw = J(#"""
{"name": "Site", "description": "x", "input": {"type": "object", "required": ["site"], "properties": {"site": {"type": "string", "format": "uri"}}},
 "result": {"type": "object", "properties": {"text": {"type": "string"}}}, "start": "look",
 "steps": {"look": {"use": "website", "with": {"site": "{input.site}", "goal": "find the price"}, "next": {"found": "end", "finished": "end", "gave up": "fail"}}},
 "end": {"text": "{steps.look.text}"}}
"""#)
expect("the check refuses the Website step by name", checked(siteRaw).problems.contains { $0.contains("Website steps arrive in the next build") })
if let definition = TaskDefinition.trusted(siteRaw), case .success(var started) = TaskEngine.begin(definition, raw: siteRaw, input: ["site": .text("https://shop.example")], trigger: .byHand(at: clock),
                                                                                                    folder: nil, limitMinutes: 60, now: clock) {
    expect("a Website step is started with its site and goal", { if case .startStep(_, _, .website, let with, _, _)? = started.commands.first { with["site"] == .text("https://shop.example") && with["goal"] == .text("find the price") } else { false } }())
    let before = started
    started = TaskEngine.advance(started.run, .restarted(.init(submitAllowed: false)), now: clock)
    expect("a Website step interrupted with no submit allowed starts again from the site", { if case .startStep(0, _, .website, _, _, _)? = started.commands.first { true } else { false } }() && started.run.state == .running
           && started.run.steps[0].reason == "Started again after a restart", "\(started.commands)")
    let waiting = TaskEngine.advance(before.run, .restarted(.init(submitAllowed: true)), now: clock)
    expect("after an allowed submit the Run waits on the person: Retry and Stop", waiting.run.state == .waiting && waiting.run.steps[0].state == .interrupted && waiting.commands.isEmpty
           && (waiting.run.detail ?? "").contains("Retry or Stop"), "\(waiting.run.detail ?? "")")
    let retried = TaskEngine.advance(waiting.run, .retry, now: clock)
    expect("Retry starts the step again", retried.run.state == .running && retried.run.steps[0].state == .started && !retried.commands.isEmpty)
    let stopped = TaskEngine.advance(waiting.run, .stop(), now: clock)
    expect("and Stop ends the Run", stopped.run.state == .stopped && stopped.commands.last == .end(.stopped))
    let found = TaskEngine.advance(before.run, .outcome("found", result: J(#"{"text": "$5", "page": "https://shop.example/p"}"#), actor: "Claude"), now: clock)
    expect("Website's found outcome gives its text", found.run.state == .done && found.run.result == J(#"{"text": "$5"}"#), "\(found.run.detail ?? "")")
    let gaveUp = TaskEngine.advance(before.run, .outcome("gave up", reason: "no way through"), now: clock)
    expect("and gave up takes its edge", gaveUp.run.state == .failed && gaveUp.run.detail == "Failed at look: no way through" || gaveUp.run.detail == "Failed at look: gave up", "\(gaveUp.run.detail ?? "")")
}

// MARK: The Judge, with stub voices

struct Stub: JudgeVoice {
    var name: String
    var reply: Result<JudgeAnswer, Error>

    func answer(_ question: JudgeQuestion) async throws -> JudgeAnswer { try reply.get() }
}

struct Boom: Error {}

let noulQuestion = JudgeQuestion(text: "Is it?", kind: .noul)
let choice = JudgeQuestion(text: "Which?", kind: .choice([.init(label: "a", criterion: "is a"), .init(label: "b", criterion: "is b"), .init(label: "c", criterion: "is c")]))

func judged(_ question: JudgeQuestion, jev: Stub?, claude: Stub?, claudeDecides: Bool = true) -> JudgeResult {
    var result: JudgeResult?
    let done = DispatchSemaphore(value: 0)
    Task {
        result = await TaskJudge.judge(question, jev: jev, claude: claude, claudeDecides: claudeDecides)
        done.signal()
    }
    done.wait()
    return result!
}

let jevYes = Stub(name: "Jev", reply: .success(.noul(0.93)))
let claudeNo = Stub(name: "Claude", reply: .success(.noul(0.1)))
expect("every Judge step uses the 0.7 bar", TaskJudge.bar == 0.7)
expect("a Noul at the bar is followed as yes", judged(noulQuestion, jev: Stub(name: "Jev", reply: .success(.noul(0.7))), claude: claudeNo) == .verdict(outcome: "yes", actor: "Jev", probability: 0.7, line: "Jev picked yes (0.70)"))
expect("a Noul at 0.3 or less is followed as no", judged(noulQuestion, jev: Stub(name: "Jev", reply: .success(.noul(0.3))), claude: nil) == .verdict(outcome: "no", actor: "Jev", probability: 0.3, line: "Jev picked no (0.30)"))
expect("Jev is followed and Claude not asked", judged(noulQuestion, jev: jevYes, claude: nil) == .verdict(outcome: "yes", actor: "Jev", probability: 0.93, line: "Jev picked yes (0.93)"))
if case .verdict(let outcome, let actor, _, let line) = judged(noulQuestion, jev: Stub(name: "Jev", reply: .success(.noul(0.5))), claude: Stub(name: "Claude", reply: .success(.noul(0.8)))) {
    expect("between the bars Claude picks, and the line says why", outcome == "yes" && actor == "Claude" && line.contains("Jev was unsure"), line)
} else {
    expect("between the bars Claude picks", false)
}
if case .verdict(let outcome, let actor, _, let line) = judged(choice, jev: Stub(name: "Jev", reply: .success(.choice(["a": 0.5, "b": 0.45, "c": 0.05]))), claude: Stub(name: "Claude", reply: .success(.choice(["a": 0, "b": 1, "c": 0])))) {
    expect("a Choice below the bar goes to Claude", outcome == "b" && actor == "Claude" && line.contains("Jev was unsure (a at 0.50)"), line)
} else {
    expect("a Choice below the bar goes to Claude", false)
}
expect("a Choice at the bar is followed", judged(choice, jev: Stub(name: "Jev", reply: .success(.choice(["a": 0.1, "b": 0.7, "c": 0.2]))), claude: nil) == .verdict(outcome: "b", actor: "Jev", probability: 0.7, line: "Jev picked b (0.70)"))
if case .verdict(_, let actor, _, let line) = judged(noulQuestion, jev: nil, claude: claudeNo) {
    expect("without Jev (no TypeSafe) Claude picks and says so", actor == "Claude" && line.contains("there is no Jev"), line)
} else {
    expect("without Jev Claude picks", false)
}
if case .verdict(_, let actor, _, let line) = judged(noulQuestion, jev: Stub(name: "Jev", reply: .failure(Boom())), claude: claudeNo) {
    expect("when Jev fails Claude picks", actor == "Claude" && line.contains("didn't answer"), line)
} else {
    expect("when Jev fails Claude picks", false)
}
if case .verdict(_, _, _, let line) = judged(noulQuestion, jev: Stub(name: "Jev", reply: .failure(JudgeUnavailable("the relevance filter isn't on TypeSafe"))), claude: claudeNo) {
    expect("an unavailable Jev says why", line.contains("the relevance filter isn't on TypeSafe"), line)
} else {
    expect("an unavailable Jev says why", false)
}
expect("a Task that names an unsure edge keeps Claude from deciding", judged(noulQuestion, jev: Stub(name: "Jev", reply: .success(.noul(0.5))), claude: claudeNo, claudeDecides: false)
       == .unsure(actor: "Jev", line: "Unsure: Jev was unsure (yes at 0.50)"))
expect("and so does a missing Jev, which is the harness's doing and not Jev's", judged(noulQuestion, jev: nil, claude: claudeNo, claudeDecides: false)
       == .unsure(actor: "Harness", line: "Unsure: there is no Jev"))
expect("neither voice answering fails the step", { if case .failed = judged(noulQuestion, jev: Stub(name: "Jev", reply: .failure(Boom())), claude: Stub(name: "Claude", reply: .failure(Boom()))) { true } else { false } }())
expect("Claude's answer that names no option fails the step", { if case .failed = judged(choice, jev: nil, claude: Stub(name: "Claude", reply: .success(.choice(["z": 1])))) { true } else { false } }())
expect("an answer of the wrong kind is no pick", { if case .failed = judged(choice, jev: nil, claude: Stub(name: "Claude", reply: .success(.noul(1)))) { true } else { false } }())

// MARK: task_result, in a scratch folder

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("engine-check-\(getpid())", isDirectory: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let pane = scratch.appendingPathComponent("pane", isDirectory: true)
let resultSchema = TaskSchema.read(J(#"{"type": "object", "required": ["amount", "currency"], "properties": {"amount": {"type": "number"}, "currency": {"type": "string", "enum": ["USD", "EUR"]}, "note": {"type": "string"}}}"#), at: "r").schema!
expect("a pane with no schema lists no task_result", TaskResultTool.tools(in: pane).isEmpty && !TaskResultTool.isPrepared(in: pane))
expect("and a call there is refused", TaskResultTool.call(["amount": 1], in: pane).isError)
do {
    try TaskResultTool.prepare(resultSchema, in: pane)
    expect("the host's schema file makes the pane list task_result", TaskResultTool.isPrepared(in: pane) && TaskResultTool.tools(in: pane).count == 1)
    let tool = TaskResultTool.tools(in: pane)[0]
    let input = tool["inputSchema"] as? [String: Any]
    expect("its input schema is the step's result schema", tool["name"] as? String == "task_result" && input?["type"] as? String == "object"
           && (input?["required"] as? [String]) == ["amount", "currency"] && ((input?["properties"] as? [String: Any])?.keys.sorted() ?? []) == ["amount", "currency", "note"])
    let bad = TaskResultTool.call(["amount": "five", "extra": 1], in: pane)
    let badText = (bad.content.first?["text"] as? String) ?? ""
    expect("a call that doesn't fit is refused, naming each wrong field", bad.isError && badText.contains("amount must be a number") && badText.contains("currency is missing") && badText.contains("extra isn't a field"), badText)
    expect("and nothing is kept", TaskResultTool.accepted(in: pane) == nil)
    let wrongEnum = TaskResultTool.call(["amount": 5, "currency": "GBP"], in: pane)
    expect("an enum is checked", wrongEnum.isError && ((wrongEnum.content.first?["text"] as? String) ?? "").contains("one of USD, EUR"))
    let good = TaskResultTool.call(["amount": 5, "currency": "USD"], in: pane)
    expect("a call that fits is kept in a result file", !good.isError && TaskResultTool.accepted(in: pane) == J(#"{"amount": 5, "currency": "USD"}"#))
    expect("a second call is refused", TaskResultTool.call(["amount": 6, "currency": "EUR"], in: pane).isError && TaskResultTool.accepted(in: pane) == J(#"{"amount": 5, "currency": "USD"}"#))
    TaskResultTool.clear(in: pane)
    expect("the host removes both files when the step ends", !TaskResultTool.isPrepared(in: pane) && TaskResultTool.accepted(in: pane) == nil)
    try TaskResultTool.prepare(resultSchema, in: pane)
    expect("a new step's schema starts clean", TaskResultTool.accepted(in: pane) == nil)
} catch {
    expect("the scratch folder can be written", false, "\(error)")
}

// MARK: The runs file

let automation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
let panes = (UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
let slot = Date(timeIntervalSince1970: 1_792_000_000)
let launch = RunLaunch(folder: "/work/x", agent: "reviewer", skipPermissions: false, dontAsk: true, allowedTools: ["Bash(git status)", "Edit"])
let going = TaskRun(id: panes.0, task: "Claude prompt", input: ["prompt": .text("Say hello"), "folder": .text("/work/x")],
                    trigger: TaskRunTrigger(automation: automation, slot: slot, late: true, manual: false), state: .running, startedAt: slot,
                    steps: [TaskRunStep(name: "claude", capability: "claude", pane: panes.0, conversation: "moved", launch: launch, worked: 90)])
let message = TaskRun(id: panes.1, task: "Claude prompt", input: ["prompt": .text("Say hello")],
                      trigger: TaskRunTrigger(automation: automation, slot: slot.addingTimeInterval(900), manual: true), state: .message, detail: "Found 3",
                      startedAt: slot.addingTimeInterval(900), endedAt: slot.addingTimeInterval(1200), opened: true,
                      steps: [TaskRunStep(name: "claude", capability: "claude", pane: panes.1)])
var skipped = TaskRun(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, task: "Claude prompt", input: ["prompt": .text("Say hello")],
                      trigger: TaskRunTrigger(automation: automation, slot: slot.addingTimeInterval(1800)), state: .skipped, detail: "The last run was still going")
skipped.count = 3
let written = String(decoding: (try? TaskRunFile.encoded([going, message, skipped])) ?? Data(), as: UTF8.self)
expect("an automation's Run is written byte for byte as slice 1 wrote it (the file's version apart)",
       written.replacingOccurrences(of: "\"version\" : 2", with: "\"version\" : 1") == sliceOneRuns + "\n", "got:\n\(written)")
expect("the runs file is at version 2", written.contains("\"version\" : 2") && TaskRunFile.currentVersion == 2)

let folder = scratch.appendingPathComponent("files", isDirectory: true)
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let file = TaskRunFile.url(in: folder)
try? Data((sliceOneRuns + "\n").utf8).write(to: file)
if case .loaded(let runs) = TaskRunFile.read(at: file) {
    expect("a version 1 file reads", runs == [going, message, skipped], "\(runs.count) runs")
} else {
    expect("a version 1 file reads", false, "\(TaskRunFile.read(at: file))")
}
try? Data(written.utf8).write(to: file)
expect("a version 2 file reads the same Runs", TaskRunFile.read(at: file) == .loaded([going, message, skipped]))
try? Data("{\"version\": 3, \"runs\": []}".utf8).write(to: file)
expect("a version 3 file is read as newer and never written over", TaskRunFile.read(at: file) == .newer(3) && TaskRunFile.read(at: file).problem != nil)
try? Data("not json".utf8).write(to: file)
if case .unreadable = TaskRunFile.read(at: file) {} else { expect("an unreadable file stays unreadable", false) }

// A Task's own Run survives its file, and the lists keep the right ones.
if let sim = Sim(haiku, input: ["topic": .text("x")]) {
    var own = sim.run
    own.steps[0].pane = UUID()
    own.steps[0].actor = "Claude"
    own.steps[0].probability = 0.5
    own.awake = 12
    own.trigger = .session(titled: "Planning", at: clock)
    do {
        try TaskRunFile.write([own], to: TaskRunFile.url(in: folder))
        expect("a Task's own Run survives the file, with its copy of the Task", TaskRunFile.read(at: TaskRunFile.url(in: folder)) == .loaded([own]))
    } catch {
        expect("the Run can be written", false, "\(error)")
    }
    expect("its trigger says how it started", own.trigger.startedBy == "By a session: Planning" && TaskRunTrigger.byHand(at: clock).startedBy == "By hand")
}
var list = TaskRunList()
func owned(_ task: String, going: Bool = false) -> TaskRun {
    TaskRun(task: task, trigger: .byHand(at: clock), state: going ? .running : .done, startedAt: clock, endedAt: going ? nil : clock)
}
let running = owned("Haiku", going: true)
list.record(running)
for _ in 0..<25 { list.record(owned("Haiku")) }
list.record(owned("Other"))
expect("each Task keeps its last 20 of the Runs no automation started, and a Run still going is never dropped",
       list.runs.filter { $0.task == "Haiku" }.count == 20 && list.runs.contains { $0.id == running.id } && list.runs.filter { $0.task == "Other" }.count == 1)
list.record(going)
expect("an automation's Runs are not counted with them", list.runs(of: automation).count == 1 && list.runs.filter { $0.task == "Haiku" }.count == 20)
let parentRun = owned("Parent", going: true)
var childRun = owned("Child", going: true)
childRun.trigger = .child(of: parentRun.id, step: "sub", at: clock)
var grandChild = owned("Grand", going: true)
grandChild.trigger = .child(of: childRun.id, step: "again", at: clock)
var tree = TaskRunList([grandChild, childRun, parentRun])
expect("a Run's children and the top of its tree are found", tree.children(of: parentRun.id).map(\.id) == [childRun.id] && tree.root(of: grandChild.id)?.id == parentRun.id
       && tree.root(of: parentRun.id)?.id == parentRun.id && tree.run(childRun.id)?.task == "Child")
tree.runs[0].trigger.parent = grandChild.id
expect("a loop in the parents doesn't hang the search", tree.root(of: grandChild.id) != nil)

// A state a newer build wrote is read as done, and the new states are words.
expect("the new states are words", RunState.failed.text == "Failed" && RunState.stopped.text == "Stopped" && !RunState.failed.isGoing && RunState.failed.ran)

// MARK: Marks the engine adds to the command line

expect("task_result is allowed in a pane that lists it", ClaudeCommand.hookSettings(problems: false, taskResult: true).contains(TaskResultTool.qualifiedName)
       && !ClaudeCommand.hookSettings(problems: false).contains(TaskResultTool.qualifiedName))

if failures > 0 {
    FileHandle.standardError.write(Data("error: check-engine: \(failures) of \(cases) checks failed\n".utf8))
    exit(1)
}
print("check-engine: \(cases) checks passed")
