"""
SSH Session Manager for MCP Server.
Handles persistent SSH connections with PTY support.
"""

import re
import select
import socket
import time
from dataclasses import dataclass
from typing import Optional

import paramiko


@dataclass
class SessionConfig:
    host: str
    username: str
    password: Optional[str] = None
    key_path: Optional[str] = None
    port: int = 22
    settle_time: float = 1.0


class SSHSession:
    """Manages a persistent SSH session with PTY."""

    # ANSI escape sequence pattern
    ANSI_ESCAPE = re.compile(
        r'\x1B(?:'
        r'\][^\x07]*\x07|'           # OSC: ESC ] ... BEL
        r'\[[0-?]*[ -/]*[@-~]|'      # CSI: ESC [ ...
        r'[@-Z\\^_]'                  # Fe: ESC + single char
        r')'
    )

    # Shell prompt patterns
    PROMPT_PATTERNS = [
        r'[\$#%>]\s*$',                      # Standard shell prompts
        r'\]\s*[\$#%>]?\s*$',                # Prompts ending with ]
        r'^>>> \s*$',                        # Python REPL
        r'^\.\.\. \s*$',                     # Python continuation
        r'^In \[\d+\]:\s*$',                 # IPython/Jupyter
        r'^\w+>\s*$',                        # Simple REPL prompts
    ]

    def __init__(self):
        self.ssh: Optional[paramiko.SSHClient] = None
        self.channel: Optional[paramiko.Channel] = None
        self.config: Optional[SessionConfig] = None
        self.buffer: str = ""
        self.prompt_regex = re.compile('|'.join(self.PROMPT_PATTERNS))

    @property
    def is_connected(self) -> bool:
        return (
            self.channel is not None
            and not self.channel.closed
            and self.ssh is not None
            and self.ssh.get_transport() is not None
            and self.ssh.get_transport().is_active()
        )

    def connect(self, config: SessionConfig) -> str:
        """Establish SSH connection. Returns initial terminal output."""
        if self.is_connected:
            self.disconnect()

        self.config = config
        self.ssh = paramiko.SSHClient()
        self.ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        connect_kwargs = {
            "hostname": config.host,
            "port": config.port,
            "username": config.username,
        }

        if config.key_path:
            connect_kwargs["key_filename"] = config.key_path
        elif config.password:
            connect_kwargs["password"] = config.password

        self.ssh.connect(**connect_kwargs)

        self.channel = self.ssh.invoke_shell(
            term="xterm-256color",
            width=120,
            height=40,
        )
        self.channel.setblocking(0)

        # Wait for initial output (MOTD, prompt)
        time.sleep(1)
        initial_output = self._read_until_settled()

        # Disable echo
        self.channel.send("stty -echo\n")
        time.sleep(0.2)
        self._drain()

        self.buffer = initial_output
        return self._strip_ansi(initial_output)

    def disconnect(self) -> None:
        """Close the SSH connection."""
        if self.channel:
            try:
                self.channel.close()
            except:
                pass
            self.channel = None

        if self.ssh:
            try:
                self.ssh.close()
            except:
                pass
            self.ssh = None

        self.buffer = ""

    def execute(self, command: str, timeout: float = 90.0) -> str:
        """Execute a command and return the output."""
        if not self.is_connected:
            return "[ERROR: Not connected to SSH session]"

        # Send the command
        if not command.endswith('\n'):
            command += '\n'
        self.channel.send(command)

        # Add to buffer
        self.buffer += command

        # Wait for response
        time.sleep(0.5)
        output = self._read_until_settled(timeout=timeout)

        if output is None:
            # Hit continuation prompt - escape and report
            self._send_interrupt()
            return "[ERROR: Command caused syntax error - unclosed quote or incomplete command]"

        self.buffer += output
        return self._strip_ansi(output)

    def send_interrupt(self) -> str:
        """Send Ctrl+C to interrupt current process."""
        if not self.is_connected:
            return "[ERROR: Not connected]"

        self._send_interrupt()
        time.sleep(0.3)
        output = self._drain()
        return f"[Sent Ctrl+C]\n{self._strip_ansi(output)}"

    def send_eof(self) -> str:
        """Send Ctrl+D (EOF)."""
        if not self.is_connected:
            return "[ERROR: Not connected]"

        self.channel.send('\x04')
        time.sleep(0.3)
        output = self._drain()
        return f"[Sent Ctrl+D]\n{self._strip_ansi(output)}"

    def send_raw(self, data: str) -> str:
        """Send raw data to the terminal."""
        if not self.is_connected:
            return "[ERROR: Not connected]"

        # Handle escape sequences
        data = data.encode().decode('unicode_escape')
        self.channel.send(data)
        time.sleep(0.3)
        output = self._drain()
        return self._strip_ansi(output)

    def background_process(self) -> str:
        """Send Ctrl+Z then 'bg' to background current process."""
        if not self.is_connected:
            return "[ERROR: Not connected]"

        self.channel.send('\x1a')  # Ctrl+Z
        time.sleep(0.5)
        output = self._drain()

        self.channel.send('bg\n')
        time.sleep(0.5)
        output += self._drain()

        return f"[Process backgrounded]\n{self._strip_ansi(output)}"

    def get_buffer(self, last_n_chars: int = 8000) -> str:
        """Get recent terminal buffer."""
        clean = self._strip_ansi(self.buffer)
        if len(clean) > last_n_chars:
            return clean[-last_n_chars:]
        return clean

    def _strip_ansi(self, text: str) -> str:
        """Remove ANSI escape codes."""
        return self.ANSI_ESCAPE.sub('', text)

    def _looks_like_prompt(self, text: str) -> bool:
        """Check if text ends with a shell prompt."""
        if not text:
            return False

        clean = self._strip_ansi(text)
        lines = clean.rstrip().split('\n')
        if not lines:
            return False

        last_line = lines[-1]
        return bool(self.prompt_regex.search(last_line))

    def _is_continuation_prompt(self, text: str) -> bool:
        """Check if shell is in continuation mode."""
        if not text:
            return False

        clean = self._strip_ansi(text)
        lines = clean.rstrip().split('\n')
        if not lines:
            return False

        last_line = lines[-1].strip()
        return last_line in ('>', '>>', '> ', '>> ', 'dquote>', 'quote>')

    def _send_interrupt(self) -> None:
        """Send Ctrl+C."""
        self.channel.send('\x03')
        time.sleep(0.2)
        self._drain()

    def _drain(self) -> str:
        """Read all available data from channel."""
        output = ""
        while True:
            ready, _, _ = select.select([self.channel], [], [], 0.1)
            if ready:
                try:
                    chunk = self.channel.recv(4096).decode("utf-8", errors="replace")
                    if chunk:
                        output += chunk
                    else:
                        break
                except:
                    break
            else:
                break
        return output

    def _read_until_settled(self, timeout: float = 90.0) -> Optional[str]:
        """Read until terminal settles. Returns None if continuation prompt."""
        output = ""
        last_read_time = time.time()
        start_time = time.time()
        settle_time = self.config.settle_time if self.config else 1.0

        while True:
            ready, _, _ = select.select([self.channel], [], [], 0.1)

            if ready:
                try:
                    chunk = self.channel.recv(4096).decode("utf-8", errors="replace")
                    if chunk:
                        output += chunk
                        last_read_time = time.time()
                except socket.timeout:
                    pass

            quiet_time = time.time() - last_read_time
            elapsed = time.time() - start_time

            # Check for continuation prompt first
            if quiet_time > settle_time and self._is_continuation_prompt(output):
                self._send_interrupt()
                return None

            # Check for normal prompt
            if quiet_time > settle_time and self._looks_like_prompt(output):
                return output

            # Timeout - background the process
            if elapsed > timeout and output and not self._looks_like_prompt(output):
                self.channel.send('\x1a')  # Ctrl+Z
                time.sleep(0.5)
                output += self._drain()
                self.channel.send('bg\n')
                time.sleep(0.5)
                output += self._drain()
                output += "\n[Process sent to background after timeout]\n"
                return output

            # Channel died
            if self.channel.closed or self.channel.exit_status_ready():
                return output

        return output
