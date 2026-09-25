"""Pair a BlueZ device on behalf of the bar, answering its own pairing prompts.

BlueZ asks the agent registered by whoever called Pair(); quickshell cannot
export one, so it runs this instead. The agent is not the default one, so an
unsolicited pairing attempt from elsewhere still finds nobody to accept it.

Usage: bt-pair /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX
Exits 0 once the device is paired, trusted and connected; prints BlueZ's error
on stderr and exits 1 otherwise. SIGTERM cancels the pairing.
"""

import asyncio
import signal
import sys

from dbus_fast import BusType, DBusError
from dbus_fast.aio import MessageBus
from dbus_fast.service import ServiceInterface, method

AGENT_PATH = "/qs/bt_pair_agent"


class Agent(ServiceInterface):
    # Just Works for everything: the only pairing this agent sees is the one
    # the user started from the bar a moment ago.
    def __init__(self):
        super().__init__("org.bluez.Agent1")

    @method()
    def Release(self):
        pass

    @method()
    def RequestPinCode(self, device: "o") -> "s":
        return "0000"

    @method()
    def DisplayPinCode(self, device: "o", pincode: "s"):
        pass

    @method()
    def RequestPasskey(self, device: "o") -> "u":
        return 0

    @method()
    def DisplayPasskey(self, device: "o", passkey: "u", entered: "q"):
        pass

    @method()
    def RequestConfirmation(self, device: "o", passkey: "u"):
        pass

    @method()
    def RequestAuthorization(self, device: "o"):
        pass

    @method()
    def AuthorizeService(self, device: "o", uuid: "s"):
        pass

    @method()
    def Cancel(self):
        pass


async def interface(bus, path, name):
    introspection = await bus.introspect("org.bluez", path)
    return bus.get_proxy_object("org.bluez", path, introspection).get_interface(name)


async def main(path):
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    bus.export(AGENT_PATH, Agent())
    manager = await interface(bus, "/org/bluez", "org.bluez.AgentManager1")
    await manager.call_register_agent(AGENT_PATH, "NoInputNoOutput")

    device = await interface(bus, path, "org.bluez.Device1")

    loop = asyncio.get_running_loop()
    pairing = asyncio.ensure_future(device.call_pair())
    loop.add_signal_handler(signal.SIGTERM, pairing.cancel)

    try:
        await pairing
    except asyncio.CancelledError:
        try:
            await device.call_cancel_pairing()
        except DBusError:
            pass
        return 1
    except DBusError as err:
        # Pairing a device that is already paired is what we wanted anyway.
        if err.type != "org.bluez.Error.AlreadyExists":
            print(err.text, file=sys.stderr)
            return 1

    # With no agent behind the bar, BlueZ refuses an untrusted device that
    # reconnects on its own (a mouse waking up), so trust it.
    await device.set_trusted(True)
    if not await device.get_connected():
        try:
            await device.call_connect()
        except DBusError as err:
            print(err.text, file=sys.stderr)
            return 1
    return 0


sys.exit(asyncio.run(main(sys.argv[1])))
