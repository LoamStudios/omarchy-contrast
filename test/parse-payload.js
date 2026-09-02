#!/usr/bin/env node
// Unit tests for IPC and eyedropper parsers. Contrast.js is a QML pragma
// library; strip that line and evaluate it in a sandbox.
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const src = fs.readFileSync(path.join(__dirname, "..", "Contrast.js"), "utf8")
  .replace(/\.pragma library\s*/, "")
const sandbox = {}
vm.createContext(sandbox)
vm.runInContext(src, sandbox)

let failed = 0
function assert(name, cond) {
  if (!cond) {
    failed++
    console.error("FAIL", name)
  }
}

const p = sandbox.parseOpenPayload
const pick = sandbox.parsePickedColor

assert("empty", p("").ok && p("").fg === null)
assert("null", p(null).ok)
assert("object", p("{}").ok && !p("{}").fg)
assert("fg bg", p('{"fg":"#658baf","bg":"#111111"}').fg === "#658baf" && p('{"fg":"#658baf","bg":"#111111"}').bg === "#111111")
assert("3-digit", p('{"fg":"#fff"}').fg === "#ffffff")
assert("non-string", p(123).ok === false)
assert("array", p("[1]").ok === false)
assert("bad hex", p('{"fg":"not-a-colour"}').ok === false)
assert("long hex", p('{"fg":"' + "a".repeat(20) + '"}').ok === false)
assert("extra key", p('{"fg":"#ffffff","x":1}').ok === false)
assert("oversize", p("{" + "a".repeat(sandbox.MAX_IPC_BYTES) + "}").ok === false)
assert("nested", p('{"fg":{"r":1}}').ok === false)

assert("pick hex", pick("#aabbcc") === "#aabbcc")
assert("pick bare", pick("AABBCC\n") === "#aabbcc")
assert("pick junk", pick("copied #aabbcc from clipboard") === null)
assert("pick oversize", pick("#aabbcc" + "x".repeat(sandbox.MAX_PICK_BYTES)) === null)
assert("pick empty", pick("") === null)
assert("pick null", pick(null) === null)

if (failed) {
  console.error(failed + " failed")
  process.exit(1)
}
console.log("ok")
