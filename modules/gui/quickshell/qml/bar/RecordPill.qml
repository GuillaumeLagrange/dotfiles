import qs
import qs.components
import qs.services

Pill {
    visible: Recorder.recording
    interactive: true
    color: Theme.red
    text: Recorder.text
    onClicked: Recorder.toggle()
}
