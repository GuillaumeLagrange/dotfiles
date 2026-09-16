import qs
import qs.components
import qs.services

Pill {
    color: Theme.purple
    text: `${Config.glyph.disk} ${Sys.disk.free}`
    tooltip: Sys.disk.tooltip
}
