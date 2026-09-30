import ctypes
import shutil
import subprocess
from pathlib import Path

import pytest

from hermescall_common import cpace
from hermescall_common.errors import CryptoError

ROOT = Path(__file__).resolve().parents[2]
C_SOURCE = ROOT / "third_party" / "cpace" / "crypto_cpace.c"
ID_A, ID_B, AD = b"device", b"bridge", b"hermescall/v1/device-pair|relay.example|"


def _sodium_flags() -> list[str]:
    for prefix in ("/opt/homebrew", "/usr/local", "/usr"):
        if (Path(prefix) / "include" / "sodium.h").exists():
            return [f"-I{prefix}/include", f"-L{prefix}/lib"]
    pytest.skip("libsodium headers not installed")


@pytest.fixture(scope="module")
def ref(tmp_path_factory: pytest.TempPathFactory) -> ctypes.CDLL:
    cc = shutil.which("cc")
    if cc is None:
        pytest.skip("no C compiler")
    out = tmp_path_factory.mktemp("cpace") / "libcpace_ref.so"
    subprocess.run([cc, "-shared", "-fPIC", "-O2", *_sodium_flags(), str(C_SOURCE), "-lsodium", "-o", str(out)], check=True)
    lib = ctypes.CDLL(str(out))
    assert lib.crypto_cpace_init() >= 0
    return lib


def c_step1(lib: ctypes.CDLL, password: bytes) -> tuple[ctypes.Array, bytes]:
    state, public = ctypes.create_string_buffer(80), ctypes.create_string_buffer(48)
    rc = lib.crypto_cpace_step1(
        state,
        public,
        password,
        ctypes.c_size_t(len(password)),
        ID_A,
        ctypes.c_ubyte(len(ID_A)),
        ID_B,
        ctypes.c_ubyte(len(ID_B)),
        AD,
        ctypes.c_size_t(len(AD)),
    )
    assert rc == 0
    return state, public.raw


def c_step2(lib: ctypes.CDLL, public: bytes, password: bytes) -> tuple[bytes, bytes]:
    response, keys = ctypes.create_string_buffer(32), ctypes.create_string_buffer(64)
    rc = lib.crypto_cpace_step2(
        response,
        public,
        keys,
        password,
        ctypes.c_size_t(len(password)),
        ID_A,
        ctypes.c_ubyte(len(ID_A)),
        ID_B,
        ctypes.c_ubyte(len(ID_B)),
        AD,
        ctypes.c_size_t(len(AD)),
    )
    assert rc == 0
    return response.raw, keys.raw


def c_step3(lib: ctypes.CDLL, state: ctypes.Array, response: bytes) -> bytes:
    keys = ctypes.create_string_buffer(64)
    assert lib.crypto_cpace_step3(state, keys, response) == 0
    return keys.raw


@pytest.mark.parametrize("password", [b"K7QMX", b"x" * 109, b"y" * 200, b""])
def test_python_client_c_server(ref: ctypes.CDLL, password: bytes) -> None:
    state, public = cpace.step1(password, ID_A, ID_B, AD)
    response, server_keys = c_step2(ref, public, password)
    keys = cpace.step3(state, response)
    assert keys.client_sk + keys.server_sk == server_keys


@pytest.mark.parametrize("password", [b"K7QMX", b"z" * 150])
def test_c_client_python_server(ref: ctypes.CDLL, password: bytes) -> None:
    state, public = c_step1(ref, password)
    response, keys = cpace.step2(public, password, ID_A, ID_B, AD)
    assert c_step3(ref, state, response) == keys.client_sk + keys.server_sk


def test_wrong_password_yields_different_keys(ref: ctypes.CDLL) -> None:
    state, public = cpace.step1(b"RIGHT", ID_A, ID_B, AD)
    response, server_keys = c_step2(ref, public, b"WRONG")
    keys = cpace.step3(state, response)
    assert keys.client_sk + keys.server_sk != server_keys


def test_identity_point_rejected() -> None:
    state, _ = cpace.step1(b"pw", ID_A, ID_B, AD)
    with pytest.raises(CryptoError):
        cpace.step3(state, bytes(32))


def test_bad_lengths_rejected() -> None:
    with pytest.raises(CryptoError):
        cpace.step2(b"short", b"pw", ID_A, ID_B, AD)
    with pytest.raises(CryptoError):
        cpace.step1(b"pw", b"a" * 256, ID_B, AD)
