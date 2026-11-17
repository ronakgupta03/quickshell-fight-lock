// Standalone Quickshell entrypoint for quickshell-fight-lock.
//
//   qs -p /path/to/quickshell-fight-lock -n -d
//   qs -p /path/to/quickshell-fight-lock ipc call lock preview
//   qs -p /path/to/quickshell-fight-lock ipc call lock lock
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: shell

    Lock { id: locker }

    // Lock, preview, toggleFight and status only - deliberately nothing that unlocks.
    IpcHandler {
        target: "lock"
        function lock(): void { locker.lock() }
        function preview(): void { locker.preview() }
        function endPreview(): void { locker.endPreview() }
        function toggleFight(): void { locker.toggleFight() }
        function status(): string { return locker.locked ? "locked" : locker.previewing ? "preview" : "unlocked" }
    }
}
