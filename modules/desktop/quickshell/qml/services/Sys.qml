pragma Singleton
// CPU, memory/swap and disk sampling. FileView reads procfs directly (no
// `cat` fork); disk free space has no statvfs binding in QML, so that one
// sample runs `df` through a Process.
import QtQuick
import Quickshell
import Quickshell.Io
import qs

Singleton {
    id: root

    readonly property int cpuPeriodMs: 3000
    readonly property int memswapPeriodMs: 5000
    readonly property int diskPeriodMs: 30000

    property var cpu: ({
            usage: "00",
            tooltip: ""
        })
    property var memswap: ({
            text: "",
            tooltip: ""
        })
    property var disk: ({
            free: "",
            tooltip: ""
        })

    // Previous /proc/stat snapshot, so usage is a delta between two ticks
    // rather than a since-boot average.
    property var _prevStat: null

    function _humanKib(kib: real): string {
        let b = kib * 1024;
        const units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
        for (let i = 0; i < units.length; i++) {
            if (b < 1024 || i === 5)
                return i === 0 ? `${b.toFixed(0)}${units[i]}` : `${b.toFixed(1)}${units[i]}`;
            b /= 1024;
        }
        return `${b.toFixed(1)}PiB`;
    }

    function _humanShort(kib: real): string {
        if (kib >= 1048576)
            return `${(kib / 1048576).toFixed(1)}G`;
        return `${(kib / 1024).toFixed(0)}M`;
    }

    function _readStat(text: string): var {
        const out = {};
        for (const line of text.split("\n")) {
            const sp = line.indexOf(" ");
            if (sp < 0)
                continue;
            const name = line.slice(0, sp);
            if (!(name === "cpu" || (name.startsWith("cpu") && /^[0-9]+$/.test(name.slice(3)))))
                continue;
            const v = line.slice(sp + 1).trim().split(/\s+/).map(Number);
            const idleAll = v[3] + v[4];
            const busy = v[0] + v[1] + v[2] + v[5] + v[6] + v[7];
            out[name] = [busy + idleAll, idleAll];
        }
        return out;
    }

    function _sampleCpu(): void {
        const cur = root._readStat(statFile.text());
        if (root._prevStat === null) {
            // First read only seeds the delta; the real sample comes on the
            // next reload.
            root._prevStat = cur;
            return;
        }
        const prev = root._prevStat;

        function pct(name) {
            const t2 = cur[name][0], i2 = cur[name][1];
            const t1 = prev[name] ? prev[name][0] : 0, i1 = prev[name] ? prev[name][1] : 0;
            const dt = t2 - t1, di = i2 - i1;
            return dt > 0 ? Math.floor((dt - di) * 100 / dt) : 0;
        }

        const cores = Object.keys(cur).filter(n => n !== "cpu").sort((a, b) => parseInt(a.slice(3)) - parseInt(b.slice(3)));
        const labels = {};
        for (const n of cores)
            labels[n] = `${n}:`;
        const width = cores.reduce((w, n) => Math.max(w, labels[n].length), 0);
        const tooltip = cores.map(n => `${labels[n].padEnd(width)} ${pct(n)}%`).join("\n");
        const usage = pct("cpu");
        root._prevStat = cur;
        root.cpu = {
            usage: String(usage).padStart(2, "0"),
            tooltip
        };
    }

    function _sampleMemSwap(): void {
        let total = 0, avail = 0;
        for (const line of meminfoFile.text().split("\n")) {
            const sp = line.indexOf(":");
            if (sp < 0)
                continue;
            const key = line.slice(0, sp);
            if (key === "MemTotal")
                total = parseInt(line.slice(sp + 1));
            else if (key === "MemAvailable")
                avail = parseInt(line.slice(sp + 1));
        }
        const ramPct = total > 0 ? Math.floor((total - avail) * 100 / total) : 0;

        let zramUsed = 0, diskUsed = 0;
        const swapLines = swapsFile.text().split("\n").slice(1);
        for (const line of swapLines) {
            const fields = line.trim().split(/\s+/);
            if (fields.length < 4)
                continue;
            const used = parseInt(fields[3]);
            if (fields[0].startsWith("/dev/zram"))
                zramUsed += used;
            else
                diskUsed += used;
        }

        // Field 2 (0-based) of mm_stat is mem_used_total in bytes: the real RAM
        // the compressed pages occupy. Only zram0-3 are probed: FileView has no
        // glob, and forking `ls` to enumerate /sys/block just for a tooltip line
        // isn't worth it.
        let zramReal = 0;
        for (const fv of [zramMm0, zramMm1, zramMm2, zramMm3]) {
            if (!fv.loaded)
                continue;
            const parts = fv.text().trim().split(/\s+/);
            const bytes = parts.length > 2 ? parseInt(parts[2]) : NaN;
            if (!isNaN(bytes))
                zramReal += Math.floor(bytes / 1024);
        }

        root.memswap = {
            text: `${Config.glyph.ram} ${ramPct}%`,
            tooltip: `RAM ${ramPct}% used\nzram ${root._humanShort(zramUsed)} pages \u2192 ${root._humanShort(zramReal)} in RAM\ndisk swap ${root._humanShort(diskUsed)}`
        };
    }

    function _sampleDisk(text: string): void {
        const lines = text.split("\n").filter(l => l.trim() !== "");
        if (lines.length < 2)
            return;
        const [size, used, avail] = lines[1].trim().split(/\s+/).map(Number);
        const denom = used + avail;
        const pcent = denom > 0 ? Math.round(used * 100 / denom) : 0;
        root.disk = {
            free: root._humanKib(avail),
            tooltip: `${root._humanKib(used)} used out of ${root._humanKib(size)} on / (${pcent}%)`
        };
    }

    FileView {
        id: statFile
        path: "/proc/stat"
        onLoaded: root._sampleCpu()
    }

    Timer {
        interval: root.cpuPeriodMs
        running: true
        repeat: true
        onTriggered: statFile.reload()
    }

    FileView {
        id: meminfoFile
        path: "/proc/meminfo"
        onLoaded: root._sampleMemSwap()
    }

    FileView {
        id: swapsFile
        path: "/proc/swaps"
        onLoaded: root._sampleMemSwap()
    }

    FileView {
        id: zramMm0
        path: "/sys/block/zram0/mm_stat"
        printErrors: false
        onLoaded: root._sampleMemSwap()
        onLoadFailed: root._sampleMemSwap()
    }

    FileView {
        id: zramMm1
        path: "/sys/block/zram1/mm_stat"
        printErrors: false
        onLoaded: root._sampleMemSwap()
        onLoadFailed: root._sampleMemSwap()
    }

    FileView {
        id: zramMm2
        path: "/sys/block/zram2/mm_stat"
        printErrors: false
        onLoaded: root._sampleMemSwap()
        onLoadFailed: root._sampleMemSwap()
    }

    FileView {
        id: zramMm3
        path: "/sys/block/zram3/mm_stat"
        printErrors: false
        onLoaded: root._sampleMemSwap()
        onLoadFailed: root._sampleMemSwap()
    }

    Timer {
        interval: root.memswapPeriodMs
        running: true
        repeat: true
        onTriggered: {
            meminfoFile.reload();
            swapsFile.reload();
            zramMm0.reload();
            zramMm1.reload();
            zramMm2.reload();
            zramMm3.reload();
        }
    }

    Process {
        id: dfProc
        command: [Config.df, "--output=size,used,avail", "-k", "/"]
        stdout: StdioCollector {
            onStreamFinished: root._sampleDisk(this.text)
        }
    }

    Timer {
        interval: root.diskPeriodMs
        running: true
        triggeredOnStart: true
        repeat: true
        onTriggered: dfProc.running = true
    }
}
