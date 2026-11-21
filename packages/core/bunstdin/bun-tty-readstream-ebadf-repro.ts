import { fstatSync } from "node:fs"
import tty from "node:tty"
import { dlopen, FFIType, ptr } from "bun:ffi"

const F_GETFL = 3
const F_SETFL = 4
const O_NONBLOCK = process.platform === "darwin" ? 0x0004 : 0x0800

const libc = dlopen(process.platform === "darwin" ? "libc.dylib" : "libc.so.6", {
  fcntl: { args: [FFIType.i32, FFIType.i32, FFIType.i32], returns: FFIType.i32 },
})

const libpty = dlopen(process.platform === "darwin" ? "libc.dylib" : "libutil.so.1", {
  openpty: {
    args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr],
    returns: FFIType.i32,
  },
})

function fdState(fd: number): string {
  try {
    fstatSync(fd)
    return "open"
  } catch (error) {
    return error instanceof Error ? error.message : String(error)
  }
}

const master = new Int32Array(1)
const slave = new Int32Array(1)
if (libpty.symbols.openpty(ptr(master), ptr(slave), null, null, null) !== 0) {
  throw new Error("openpty failed")
}

const masterFd = master[0]!
const flags = libc.symbols.fcntl(masterFd, F_GETFL, 0)
libc.symbols.fcntl(masterFd, F_SETFL, flags | O_NONBLOCK)

const stream = new tty.ReadStream(masterFd)

console.log("before resume", { masterFd: fdState(masterFd), streamFd: stream.fd })

stream.on("error", (error) => {
  console.log("error", error instanceof Error ? error.message : String(error))
  console.log("after error", { masterFd: fdState(masterFd), streamFd: stream.fd })
})

stream.on("close", () => {
  console.log("close", { masterFd: fdState(masterFd), streamFd: stream.fd, destroyed: stream.destroyed })
})

stream.resume()
await Bun.sleep(50)

console.log("after sleep", { masterFd: fdState(masterFd), streamFd: stream.fd, destroyed: stream.destroyed })
