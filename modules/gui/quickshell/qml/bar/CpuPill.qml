import qs
import qs.components
import qs.services

Pill {
    color: Theme.yellow
    text: `${Config.glyph.cpu} ${Sys.cpu.usage}%`
    tooltip: Sys.cpu.tooltip
}
