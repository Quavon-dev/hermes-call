class CryptoError(Exception):
    pass


class ProtocolError(Exception):
    pass


class SelfSignedRelay(ProtocolError):
    """The relay's certificate is not WebPKI-valid and no pin was given: the user must confirm its key."""

    def __init__(self, pin: str) -> None:
        super().__init__(f"relay uses a self-signed certificate with key {pin}; confirm it and pass it as the pin")
        self.pin = pin
