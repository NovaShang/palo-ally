// PaloAlly Helper: starts Claude Code for the PaloAlly host so that macOS
// counts this app, not the host (bun, launchd or a terminal), as responsible
// for it. The owner gives the helper Full Disk Access once, and every Pal
// the host runs gets the same macOS permissions (docs/pals-prd.md §7.3).
//
//   PaloAllyHelper -- <command> [args...]   run a command (the host's Pals)
//   PaloAllyHelper --check <pid>            print the pid macOS holds responsible for <pid>
//   PaloAllyHelper --version
//
// How: the host starts the helper with the command to run. The helper starts
// itself again with responsibility disclaimed (posix_spawn with
// responsibility_spawnattrs_setdisclaim, as browsers do for their helpers),
// so the second copy is responsible for itself and is the signed app. That
// copy starts the command as its child, which inherits the responsibility.
// Standard input, output and error are inherited all the way down: the host
// talks to the command over its own pipes, with nothing copied in between.
// Signals the host sends go down the chain; each copy exits the way its child
// did. When file descriptor 3 is open, the second copy writes one JSON line
// there: {"pid": <the command's pid>, "responsible": <its responsible pid>}.
import Darwin
import MachO

let stageVar = "PALOALLY_HELPER_STAGE"
let version = "1"

typealias DisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

func symbol<T>(_ name: String, as _: T.Type) -> T? {
  guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
  return unsafeBitCast(p, to: T.self)
}

func fail(_ s: String) -> Never {
  let line = "PaloAlly Helper: \(s)\n"
  _ = line.withCString { write(2, $0, strlen($0)) }
  exit(70)
}

func responsible(for pid: pid_t) -> pid_t? {
  guard let f = symbol("responsibility_get_pid_responsible_for_pid", as: ResponsibleFn.self) else { return nil }
  return f(pid)
}

// The child, kept for the signal handlers (they can't capture anything).
var child: pid_t = 0

func forwardSignals() {
  for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2] {
    signal(sig) { s in
      if child > 0 { kill(child, s) }
    }
  }
  signal(SIGPIPE, SIG_IGN)
}

func executablePath() -> String {
  var size: UInt32 = 0
  _NSGetExecutablePath(nil, &size)
  var buf = [CChar](repeating: 0, count: Int(size) + 1)
  guard _NSGetExecutablePath(&buf, &size) == 0 else { fail("can't find myself") }
  return String(cString: buf)
}

// The environment as C strings, with or without the stage marker.
func environment(stage2: Bool) -> [String] {
  var out: [String] = []
  var p = environ
  while let e = p.pointee {
    let s = String(cString: e)
    if !s.hasPrefix(stageVar + "=") { out.append(s) }
    p += 1
  }
  if stage2 { out.append("\(stageVar)=2") }
  return out
}

func spawn(_ path: String, _ argv: [String], env: [String], disclaim: Bool) -> pid_t {
  var attr: posix_spawnattr_t? = nil
  posix_spawnattr_init(&attr)
  defer { posix_spawnattr_destroy(&attr) }
  // The child starts with default signal handling and nothing blocked.
  var none = sigset_t()
  sigemptyset(&none)
  posix_spawnattr_setsigmask(&attr, &none)
  var all = sigset_t()
  sigfillset(&all)
  posix_spawnattr_setsigdefault(&attr, &all)
  posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
  if disclaim {
    guard let f = symbol("responsibility_spawnattrs_setdisclaim", as: DisclaimFn.self) else { fail("this macOS can't disclaim responsibility") }
    guard f(&attr, 1) == 0 else { fail("disclaiming responsibility failed") }
  }
  var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
  var cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
  defer {
    for p in cargs { free(p) }
    for p in cenv { free(p) }
  }
  var pid: pid_t = 0
  let rc = posix_spawnp(&pid, path, nil, &attr, &cargs, &cenv)
  guard rc == 0 else { fail("can't start \(path): \(String(cString: strerror(rc)))") }
  return pid
}

// Waits for the child and leaves the same way it did.
func waitAndExit() -> Never {
  var status: Int32 = 0
  while waitpid(child, &status, 0) < 0 {
    if errno != EINTR { fail("lost the child: \(String(cString: strerror(errno)))") }
  }
  let low = status & 0x7f
  if low == 0 { exit((status >> 8) & 0xff) }
  if low != 0x7f {
    signal(low, SIG_DFL)
    kill(getpid(), low)
  }
  exit(128 + low)
}

func report(_ json: String) {
  guard fcntl(3, F_GETFD) != -1 else { return }
  let line = json + "\n"
  _ = line.withCString { write(3, $0, strlen($0)) }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { fail("usage: PaloAllyHelper -- <command> [args...] | --check <pid> | --version") }

switch first {
case "--version":
  print(version)
  exit(0)
case "--check":
  guard args.count == 2, let pid = pid_t(args[1]) else { fail("usage: --check <pid>") }
  guard let r = responsible(for: pid) else { fail("this macOS doesn't say") }
  print(r)
  exit(0)
case "--":
  args.removeFirst()
default:
  fail("unknown option \(first)")
}
guard let command = args.first else { fail("no command to run") }

forwardSignals()
if getenv(stageVar) == nil {
  // Stage 1 (the host's child): start a copy of this app that is responsible for itself.
  child = spawn(executablePath(), [CommandLine.arguments[0], "--"] + args, env: environment(stage2: true), disclaim: true)
  waitAndExit()
}
// Stage 2: responsible for itself; the command inherits that.
unsetenv(stageVar)
if fcntl(3, F_GETFD) != -1 { _ = fcntl(3, F_SETFD, FD_CLOEXEC) }
child = spawn(command, args, env: environment(stage2: false), disclaim: false)
report("{\"pid\":\(child),\"responsible\":\(responsible(for: child) ?? -1),\"helper\":\(getpid())}")
waitAndExit()
