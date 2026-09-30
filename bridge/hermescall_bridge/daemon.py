import asyncio
import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from aiohttp import web

from hermescall_common.client import RelaySession
from hermescall_common.e2e import Channel

from .api import build_app
from .audio import SpeechTrack
from .calls import CallManager, Ring
from .chat import ChatService
from .chatstore import ChatStore
from .config import Config, ConfigError
from .conversation import Conversation
from .devices import DeviceRegistry
from .hermes import HermesClient
from .phone import PhoneService
from .present import Fetcher, PresentService, fetch_image
from .seen import SeenLog
from .state import Device, State, StateStore
from .tasks import TaskService
from .tts import KokoroTts

log = logging.getLogger(__name__)


@dataclass
class Bridge:
    relay: RelaySession
    calls: CallManager
    devices: DeviceRegistry
    chat: ChatService
    phone: PhoneService
    presenter: PresentService
    tasks: TaskService
    app: web.Application
    seen: SeenLog


def outbound_note(ring: Ring | None, chat_context: str = "") -> str:
    if ring is None:
        note = "The owner called you from the Hermes Call app."
    else:
        note = (
            "You placed this call to your owner yourself. "
            f"Reason you called: {ring.reason or 'not given'}. "
            f'You already opened the call by saying: "{ring.first_message}". Continue from there.'
        )
    return f"{note}\n\n{chat_context}" if chat_context else note


def build_bridge(
    state: State,
    store: StateStore,
    api_token: str,
    hermes: HermesClient,
    tts: KokoroTts,
    transcribe: Callable[[np.ndarray], Awaitable[str]],
    call_token: str = "",
    agent_name: str = "Hermes",
    image_fetcher: Fetcher = fetch_image,
    transcribe_long: Callable[[np.ndarray], Awaitable[str]] | None = None,
) -> Bridge:
    async def on_event(message: dict) -> None:
        kind = message["t"]
        if kind == "e2e" and isinstance(message.get("from"), str) and isinstance(message.get("data"), str):
            await calls.on_e2e(message["from"], message["data"])
        elif kind == "pair_join":
            await devices.on_pair_join(message)
        elif kind == "pair_msg":
            await devices.on_pair_msg(message)
        elif kind == "pair_abort":
            await devices.on_pair_abort(message)
        elif kind == "presence":
            tasks.on_presence(message.get("device_id"), message.get("online"))

    def make_conversation(out: SpeechTrack, approve: Callable, ring: Ring | None, caption: Callable) -> Conversation:
        note = outbound_note(ring, chat.recent_context())
        return Conversation(
            hermes, tts, transcribe, out, approve, note, agent_name=agent_name, on_caption=caption, on_progress=tasks.submit
        )

    def status() -> dict:
        return {
            "relay": state.endpoint.authority,
            "connected": relay.connected.is_set(),
            "devices": len(state.devices),
            "in_call": calls.active is not None,
            "chat_adapter": time.monotonic() - chat.last_poll < 90,
        }

    async def on_ready() -> None:
        await chat.on_relay_ready()

    relay = RelaySession(state.endpoint, "bridge", state.bridge_id, state.key("sign_sk"), on_event, on_ready)
    seen = SeenLog(store.directory)
    seen_peers, seen_mail = seen.load()
    channel = Channel(state.bridge_id, state.key("box_sk"), seen_peers, seen_mail=seen_mail, on_mark=seen.mark)

    async def unpair(device_id: str) -> bool:
        """Revoke a phone everywhere (API, CLI and the phone's own `unpair`). False: unknown device."""
        if not await devices.revoke(device_id):
            return False
        await calls.forget_device(device_id)
        phone.forget_device(device_id)
        tasks.forget_device(device_id)
        chat.forget_device(device_id)
        return True

    async def missed(ring: Ring, status: str) -> bool:
        return await chat.missed_call(ring.reason, ring.first_message, status)

    async def other_messages(device: Device, body: dict) -> None:
        if body["type"] == "phone_answer":
            await phone.on_answer(device, body)
        elif body["type"] == "task_prefs":
            await tasks.on_prefs(device, body)
        else:
            await chat.handle(device, body)

    chat = ChatService(
        state, relay, channel, transcribe, agent_name, tts, ChatStore(store.directory / "chat.db"), transcribe_long
    )
    phone = PhoneService(state, relay, channel)
    presenter = PresentService(chat, image_fetcher)
    tasks = TaskService(state, relay, channel, store.load_task_prefs(), store.save_task_prefs)
    calls = CallManager(state, relay, channel, make_conversation, unpair, other_messages, missed, chat.note_call)
    devices = DeviceRegistry(state, store, relay, agent_name)
    app = build_app(api_token, calls, devices, status, call_token, chat, phone, presenter, tasks, unpair)
    return Bridge(relay, calls, devices, chat, phone, presenter, tasks, app, seen)


async def serve(config: Config) -> None:
    from .stt import Transcriber

    store = StateStore(config.state_dir)
    state = store.load()
    if not state.paired:
        raise ConfigError("bridge is not paired with a relay; run: hermes-call-bridge relay add '<pairing link>'")
    hermes = HermesClient(config.hermes_url, config.secret("hermes_api_key"), config.hermes_session, config.hermes_model)
    tts = KokoroTts(config.tts_url, config.tts_voice)
    log.info("loading speech recognition model %s", config.stt_model)
    transcriber = Transcriber(str(Path(config.stt_model_dir) / config.stt_model), config.stt_threads)
    bridge = build_bridge(
        state,
        store,
        config.secret("api_token"),
        hermes,
        tts,
        transcriber.transcribe,
        config.secret("call_token"),
        config.agent_name,
        transcribe_long=transcriber.transcribe_background,
    )
    runner = web.AppRunner(bridge.app, access_log=None)
    await runner.setup()
    await web.TCPSite(runner, config.api_host, config.api_port).start()
    log.info("local API on %s:%s", config.api_host, config.api_port)
    try:
        await bridge.relay.run()
    finally:
        await runner.cleanup()
        await hermes.close()
        await tts.close()


def run(config: Config) -> None:
    asyncio.run(serve(config))
