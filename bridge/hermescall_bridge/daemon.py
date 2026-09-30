import asyncio
import contextlib
import logging
import signal
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from aiohttp import web

from hermescall_common.client import RelaySession
from hermescall_common.e2e import Channel

from .api import build_app
from .audio import SpeechTrack
from .calls import CallManager, CallTimeouts, Ring
from .chat import ChatService
from .chatstore import ChatStore
from .config import Config, ConfigError
from .conversation import Conversation, TurnSettings
from .devices import DeviceRegistry
from .health import HealthChecker, sd_notify, watchdog, watchdog_interval
from .hermes import HermesClient
from .metrics import METRICS
from .phone import PhoneService
from .present import Fetcher, PresentService, fetch_image
from .seen import SeenLog
from .sessions import PhoneSessions
from .state import Device, State, StateStore
from .tasks import TaskService
from .tts import KokoroTts

log = logging.getLogger(__name__)

SHUTDOWN_FLUSH_SECONDS = 5.0


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


@dataclass(frozen=True)
class BridgeOptions:
    """Everything optional beyond what tests need (the daemon fills it from bridge.toml)."""

    transcribe_long: Callable[[np.ndarray], Awaitable[str]] | None = None
    sessions: PhoneSessions | None = None
    turn_settings: TurnSettings | None = None
    timeouts: CallTimeouts = field(default_factory=CallTimeouts)
    turn_transport: str = "auto"
    # (Hermes URL, Kokoro URL) for /healthz; None: /healthz reports the relay only
    health_urls: tuple[str, str] | None = None


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
    options: BridgeOptions | None = None,
) -> Bridge:
    opts = options or BridgeOptions()
    sessions = opts.sessions

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

    async def on_ready() -> None:
        """Each step on its own: one failing must not keep the others (outbox, resumes) from running."""
        steps = await asyncio.gather(
            devices.flush_revocations(), calls.on_relay_ready(), chat.on_relay_ready(), return_exceptions=True
        )
        for name, result in zip(("revocations", "call", "chat"), steps, strict=True):
            if isinstance(result, Exception):
                log.error("after the relay reconnect, %s recovery failed: %r", name, result)

    def make_conversation(
        out: SpeechTrack, approve: Callable, ring: Ring | None, caption: Callable, device_id: str | None = None
    ) -> Conversation:
        note = outbound_note(ring, chat.recent_context())
        per_phone = sessions is not None and device_id is not None
        return Conversation(
            hermes,
            tts,
            transcribe,
            out,
            approve,
            note,
            settings=opts.turn_settings,
            agent_name=agent_name,
            on_caption=caption,
            on_progress=tasks.submit,
            session_id=sessions.session_id(device_id) if per_phone else None,
            on_turn=(lambda: sessions.note_turn(device_id)) if per_phone else None,
        )

    def status() -> dict:
        return {
            "relay": state.endpoint.authority,
            "connected": relay.connected.is_set(),
            "devices": len(state.devices),
            "in_call": calls.active is not None,
            "chat_adapter": time.monotonic() - chat.last_poll < 90,
        }

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
        if sessions is not None:
            sessions.forget(device_id)
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

    chat_store = ChatStore(store.directory / "chat.db")
    chat = ChatService(state, relay, channel, transcribe, agent_name, tts, chat_store, opts.transcribe_long)
    phone = PhoneService(state, relay, channel)
    presenter = PresentService(chat, image_fetcher)
    tasks = TaskService(state, relay, channel, store.load_task_prefs(), store.save_task_prefs)
    calls = CallManager(
        state,
        relay,
        channel,
        make_conversation,
        unpair,
        other_messages,
        missed,
        chat.note_call,
        opts.timeouts,
        opts.turn_transport,
    )
    phone.recent_activity = calls.last_activity
    devices = DeviceRegistry(state, store, relay, agent_name)
    _register_gauges(relay, calls, chat, state)
    health = HealthChecker(*opts.health_urls, relay.connected.is_set) if opts.health_urls else None
    app = build_app(api_token, calls, devices, status, call_token, chat, phone, presenter, tasks, unpair, health=health)
    return Bridge(relay, calls, devices, chat, phone, presenter, tasks, app, seen)


def _register_gauges(relay: RelaySession, calls: CallManager, chat: ChatService, state: State) -> None:
    depths: dict[str, int] = {}

    async def refresh() -> None:
        depths.update(await chat.depths())  # on the chat store's own worker thread

    METRICS.refresh = refresh
    METRICS.gauge("hermescall_bridge_relay_connected", "1 while connected to the relay.", lambda: relay.connected.is_set())
    METRICS.gauge("hermescall_bridge_in_call", "1 during a call.", lambda: calls.active is not None)
    METRICS.gauge("hermescall_bridge_devices", "Paired phones.", lambda: len(state.devices))
    METRICS.gauge("hermescall_bridge_chat_events_queued", "Chat events Hermes has not taken yet.", lambda: depths["events"])
    METRICS.gauge("hermescall_bridge_chat_inbox_pending", "Owner messages being processed.", lambda: depths["inbox"])
    METRICS.gauge("hermescall_bridge_chat_outbox_depth", "Agent messages waiting for the relay.", lambda: depths["outbox"])


def options_from(config: Config, transcribe_long: Callable | None) -> BridgeOptions:
    return BridgeOptions(
        transcribe_long=transcribe_long,
        sessions=PhoneSessions(config.hermes_session, config.state_dir / "sessions.json"),
        turn_settings=TurnSettings(end_silence_ms=config.end_silence_ms),
        timeouts=CallTimeouts(
            ring=config.ring_timeout,
            approval=config.approval_timeout,
            max_call=config.max_call_seconds,
            warning=config.call_warning_seconds,
            media=config.media_timeout,
        ),
        turn_transport=config.turn_transport,
        health_urls=(config.hermes_url, config.tts_url),
    )


async def shutdown(bridge: Bridge) -> None:
    """SIGTERM: hang up, try the outbox once more, persist replay marks, leave the relay."""
    sd_notify("STOPPING=1")
    if bridge.calls.active is not None:
        log.info("shutting down: hanging up the active call")
        await bridge.calls.end(bridge.calls.active.call_id)
    left = await bridge.chat.outbox.flush(SHUTDOWN_FLUSH_SECONDS)
    if left:
        log.warning("shutting down with %d chat message(s) still queued; they go out after the restart", left)
    bridge.seen.close()
    bridge.relay.stop()
    await bridge.chat.close()


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
    options = options_from(config, transcriber.transcribe_background)
    bridge = build_bridge(
        state,
        store,
        config.secret("api_token"),
        hermes,
        tts,
        transcriber.transcribe,
        config.secret("call_token"),
        config.agent_name,
        options=options,
    )
    runner = web.AppRunner(bridge.app, access_log=None)
    await runner.setup()
    await web.TCPSite(runner, config.api_host, config.api_port).start()
    log.info("local API on %s:%s", config.api_host, config.api_port)
    relay_task = asyncio.ensure_future(bridge.relay.run())
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(signum, stop.set)
    sd_notify("READY=1")
    interval = watchdog_interval()
    pinger = asyncio.ensure_future(watchdog(interval)) if interval else None
    try:
        await asyncio.wait({relay_task, asyncio.ensure_future(stop.wait())}, return_when=asyncio.FIRST_COMPLETED)
        await shutdown(bridge)
    finally:
        for task in (relay_task, pinger):
            if task is not None:
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task
        await runner.cleanup()
        await hermes.close()
        await tts.close()


def run(config: Config) -> None:
    asyncio.run(serve(config))
