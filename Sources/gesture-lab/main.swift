import AppKit

let usage = """
usage: gesture-lab [--replay <file.jsonl>] [--verbose]

  --replay <file>   replay a recorded touch stream through the recognizer
                    headless, print recognized gestures, and exit
  --verbose         with --replay: also print changed events and state
                    transitions
  -h, --help        show this help

With no arguments, opens the interactive gesture lab window.
"""

var replayPath: String?
var verbose = false
var argIndex = 1
let argv = CommandLine.arguments
while argIndex < argv.count {
    switch argv[argIndex] {
    case "--replay":
        argIndex += 1
        guard argIndex < argv.count else {
            fputs("gesture-lab: --replay requires a path\n\(usage)\n", stderr)
            exit(2)
        }
        replayPath = argv[argIndex]
    case "--verbose":
        verbose = true
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        fputs("gesture-lab: unknown argument '\(argv[argIndex])'\n\(usage)\n", stderr)
        exit(2)
    }
    argIndex += 1
}

if let replayPath {
    exit(Replay.run(path: replayPath, verbose: verbose))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
