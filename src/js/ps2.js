// ---------------------------------------------------------------------------
//  Intel 8042 keyboard controller with a scancode-set-1 keyboard.
//
//  Browser key events are translated to XT scancodes and queued; the guest
//  reads them from port 0x60 and is interrupted on IRQ 1.  The same events are
//  handed to the BIOS as ASCII so INT 16h works for guests that never install
//  a keyboard driver.
// ---------------------------------------------------------------------------

// KeyboardEvent.code -> [scancode, unshifted ascii, shifted ascii]
const KEYMAP = new Map(Object.entries({
  Escape: [0x01, 27, 27],
  Digit1: [0x02, 49, 33], Digit2: [0x03, 50, 64], Digit3: [0x04, 51, 35],
  Digit4: [0x05, 52, 36], Digit5: [0x06, 53, 37], Digit6: [0x07, 54, 94],
  Digit7: [0x08, 55, 38], Digit8: [0x09, 56, 42], Digit9: [0x0a, 57, 40],
  Digit0: [0x0b, 48, 41], Minus: [0x0c, 45, 95], Equal: [0x0d, 61, 43],
  Backspace: [0x0e, 8, 8], Tab: [0x0f, 9, 9],
  KeyQ: [0x10, 113, 81], KeyW: [0x11, 119, 87], KeyE: [0x12, 101, 69],
  KeyR: [0x13, 114, 82], KeyT: [0x14, 116, 84], KeyY: [0x15, 121, 89],
  KeyU: [0x16, 117, 85], KeyI: [0x17, 105, 73], KeyO: [0x18, 111, 79],
  KeyP: [0x19, 112, 80], BracketLeft: [0x1a, 91, 123],
  BracketRight: [0x1b, 93, 125], Enter: [0x1c, 13, 13],
  ControlLeft: [0x1d, 0, 0],
  KeyA: [0x1e, 97, 65], KeyS: [0x1f, 115, 83], KeyD: [0x20, 100, 68],
  KeyF: [0x21, 102, 70], KeyG: [0x22, 103, 71], KeyH: [0x23, 104, 72],
  KeyJ: [0x24, 106, 74], KeyK: [0x25, 107, 75], KeyL: [0x26, 108, 76],
  Semicolon: [0x27, 59, 58], Quote: [0x28, 39, 34], Backquote: [0x29, 96, 126],
  ShiftLeft: [0x2a, 0, 0], Backslash: [0x2b, 92, 124],
  KeyZ: [0x2c, 122, 90], KeyX: [0x2d, 120, 88], KeyC: [0x2e, 99, 67],
  KeyV: [0x2f, 118, 86], KeyB: [0x30, 98, 66], KeyN: [0x31, 110, 78],
  KeyM: [0x32, 109, 77], Comma: [0x33, 44, 60], Period: [0x34, 46, 62],
  Slash: [0x35, 47, 63], ShiftRight: [0x36, 0, 0],
  NumpadMultiply: [0x37, 42, 42], AltLeft: [0x38, 0, 0], Space: [0x39, 32, 32],
  CapsLock: [0x3a, 0, 0],
  F1: [0x3b, 0, 0], F2: [0x3c, 0, 0], F3: [0x3d, 0, 0], F4: [0x3e, 0, 0],
  F5: [0x3f, 0, 0], F6: [0x40, 0, 0], F7: [0x41, 0, 0], F8: [0x42, 0, 0],
  F9: [0x43, 0, 0], F10: [0x44, 0, 0], F11: [0x57, 0, 0], F12: [0x58, 0, 0],
  NumLock: [0x45, 0, 0], ScrollLock: [0x46, 0, 0],
  Numpad7: [0x47, 55, 55], Numpad8: [0x48, 56, 56], Numpad9: [0x49, 57, 57],
  NumpadSubtract: [0x4a, 45, 45],
  Numpad4: [0x4b, 52, 52], Numpad5: [0x4c, 53, 53], Numpad6: [0x4d, 54, 54],
  NumpadAdd: [0x4e, 43, 43],
  Numpad1: [0x4f, 49, 49], Numpad2: [0x50, 50, 50], Numpad3: [0x51, 51, 51],
  Numpad0: [0x52, 48, 48], NumpadDecimal: [0x53, 46, 46],
  NumpadEnter: [0xe01c, 13, 13], ControlRight: [0xe01d, 0, 0],
  NumpadDivide: [0xe035, 47, 47], AltRight: [0xe038, 0, 0],
  Home: [0xe047, 0, 0], ArrowUp: [0xe048, 0, 0], PageUp: [0xe049, 0, 0],
  ArrowLeft: [0xe04b, 0, 0], ArrowRight: [0xe04d, 0, 0],
  End: [0xe04f, 0, 0], ArrowDown: [0xe050, 0, 0], PageDown: [0xe051, 0, 0],
  Insert: [0xe052, 0, 0], Delete: [0xe053, 0, 0],
  MetaLeft: [0xe05b, 0, 0], MetaRight: [0xe05c, 0, 0],
}));

// Scancodes INT 16h reports in AH when there is no ASCII equivalent.
export function keyEventToBios(code, shift, ctrl) {
  const e = KEYMAP.get(code);
  if (!e) return null;
  const scan = e[0] & 0xff;
  let ascii = shift ? e[2] : e[1];
  if (ctrl && ascii >= 64 && ascii < 128) ascii &= 0x1f;
  return { scan, ascii };
}

export class PS2 {
  constructor(pic) {
    this.pic = pic;
    this.output = [];             // bytes waiting at port 0x60
    this.fromMouse = [];          // parallel flags: true if the byte is mouse data
    this.commandByte = 0x45;      // translation on, keyboard interrupt enabled
    this.pendingCommand = 0;
    this.pendingKbdCommand = 0;
    this.shift = false;
    this.ctrl = false;
    this.alt = false;
    this.onReset = () => {};
    // The A20 gate is bit 1 of the controller's output port.
    this.onA20 = () => {};
    this.getA20 = () => true;
    this.resetState();
  }

  /** Power-on state, leaving the host callbacks alone. */
  resetState() {
    this.output = [];
    this.fromMouse = [];
    this.commandByte = 0x45;
    this.pendingCommand = 0;
    this.pendingKbdCommand = 0;
    this.shift = false;
    this.ctrl = false;
    this.alt = false;
    this.enabled = true;
    this.resetMouse();
  }

  // ---- the mouse ------------------------------------------------------------
  //  Packets flow only while the mouse is reporting (F4h, or INT 15h C200h)
  //  and the controller's aux port is clocked (command byte bit 5 clear).

  /** The mouse's own power-on state: stream mode, not reporting. */
  resetMouse() {
    this.mouseReporting = false;
    this.mouseRate = 100;
    this.mouseResolution = 2;
    this.mouseScaling2 = false;
    this.mouseParam = 0;             // a command waiting for its argument
    for (let i = this.output.length - 1; i >= 0; i--) {
      if (this.fromMouse[i]) { this.output.splice(i, 1); this.fromMouse.splice(i, 1); }
    }
  }

  get auxEnabled() { return (this.commandByte & 0x20) === 0; }

  /** Turn reporting on or off, opening the aux port and its IRQ to go with it. */
  setMouseReporting(on) {
    this.mouseReporting = on;
    if (on) this.commandByte = (this.commandByte | 0x02) & ~0x20;
  }

  queue(byte, isMouse = false) {
    this.output.push(byte & 0xff);
    this.fromMouse.push(isMouse);
    if (this.output.length > 64) { this.output.shift(); this.fromMouse.shift(); }
    this.raise();
  }

  raise() {
    if (!this.output.length) return;
    const mouse = this.fromMouse[0];
    if (mouse) {
      if (this.commandByte & 0x02) this.pic.raise(12);
    } else if (this.commandByte & 0x01) {
      this.pic.raise(1);
    }
  }

  /** Feed a key press or release using a KeyboardEvent.code value. */
  key(code, pressed) {
    const e = KEYMAP.get(code);
    if (!e) return null;
    if (code === 'ShiftLeft' || code === 'ShiftRight') this.shift = pressed;
    if (code === 'ControlLeft' || code === 'ControlRight') this.ctrl = pressed;
    if (code === 'AltLeft' || code === 'AltRight') this.alt = pressed;

    const raw = e[0];
    if (raw > 0xff) {
      this.queue(0xe0);
      this.queue((raw & 0xff) | (pressed ? 0 : 0x80));
    } else {
      this.queue(raw | (pressed ? 0 : 0x80));
    }
    if (!pressed) return null;
    return keyEventToBios(code, this.shift, this.ctrl);
  }

  get status() {
    // bit0 output buffer full, bit2 system flag, bit5 mouse data
    let s = 0x14;
    if (this.output.length) s |= 0x01;
    if (this.output.length && this.fromMouse[0]) s |= 0x20;
    return s;
  }

  read(port) {
    if (port === 0x64) return this.status;
    if (!this.output.length) return 0x00;
    const b = this.output.shift();
    this.fromMouse.shift();
    this.pic.lower(1);
    this.pic.lower(12);
    this.raise();
    return b;
  }

  write(port, val) {
    val &= 0xff;
    if (port === 0x64) return this.command(val);
    return this.data(val);
  }

  command(cmd) {
    switch (cmd) {
      case 0x20: this.queue(this.commandByte); return;
      case 0x60: this.pendingCommand = 0x60; return;
      case 0xa7: this.commandByte |= 0x20; return;       // aux port off
      case 0xa8: this.commandByte &= ~0x20; return;      // aux port on
      case 0xa9: this.queue(0x00); return;             // mouse interface test
      case 0xaa: this.queue(0x55); return;             // controller self test
      case 0xab: this.queue(0x00); return;             // keyboard interface test
      case 0xad: this.enabled = false; return;
      case 0xae: this.enabled = true; return;
      case 0xd0:                                       // read output port
        this.queue(0x01 | (this.getA20() ? 0x02 : 0));
        return;
      case 0xd1: this.pendingCommand = 0xd1; return;
      case 0xdd: this.onA20(false); return;            // A20 off, short form
      case 0xdf: this.onA20(true); return;             // A20 on, short form
      case 0xd2: this.pendingCommand = 0xd2; return;   // echo as keyboard data
      case 0xd3: this.pendingCommand = 0xd3; return;   // echo as mouse data
      case 0xd4: this.pendingCommand = 0xd4; return;
      default:
        if (cmd >= 0xf0) {
          // pulsing the output port's low bit is how a PC reboots
          if (!(cmd & 1)) this.onReset();
        }
        return;
    }
  }

  data(val) {
    if (this.pendingCommand === 0x60) {
      this.commandByte = val;
      this.pendingCommand = 0;
      return;
    }
    if (this.pendingCommand === 0xd1) {
      this.pendingCommand = 0;
      if (!(val & 1)) { this.onReset(); return; }
      this.onA20((val & 2) !== 0);
      return;
    }
    // The loopback commands hand the byte back as if a device had sent it.
    // Linux finds the mouse port, and proves IRQ 12 arrives, by this.
    if (this.pendingCommand === 0xd2 || this.pendingCommand === 0xd3) {
      const mouse = this.pendingCommand === 0xd3;
      this.pendingCommand = 0;
      this.queue(val, mouse);
      return;
    }
    if (this.pendingCommand === 0xd4) {                // byte destined for the mouse
      this.pendingCommand = 0;
      this.mouseData(val);
      return;
    }

    // parameters for a two-byte keyboard command
    if (this.pendingKbdCommand) {
      this.pendingKbdCommand = 0;
      this.queue(0xfa);
      return;
    }

    switch (val) {
      case 0xff: this.queue(0xfa); this.queue(0xaa); return;   // reset, self test ok
      case 0xf2: this.queue(0xfa); this.queue(0xab); this.queue(0x83); return;
      case 0xed: case 0xf0: case 0xf3:
        this.pendingKbdCommand = val;
        this.queue(0xfa);
        return;
      case 0xf4: case 0xf5: case 0xf6: case 0xfe:
        this.queue(0xfa);
        return;
      default:
        this.queue(0xfa);
        return;
    }
  }

  mouseData(val) {
    const ack = () => this.queue(0xfa, true);
    if (this.mouseParam) {                           // the argument of F3h or E8h
      if (this.mouseParam === 0xf3) this.mouseRate = val;
      else this.mouseResolution = val & 3;
      this.mouseParam = 0;
      return ack();
    }
    switch (val) {
      case 0xff:                                     // reset
        this.resetMouse();
        ack(); this.queue(0xaa, true); this.queue(0x00, true);
        return;
      case 0xf6: this.resetMouse(); return ack();    // defaults
      case 0xf4: this.mouseReporting = true; return ack();
      case 0xf5: this.mouseReporting = false; return ack();
      case 0xf3: case 0xe8: this.mouseParam = val; return ack();
      case 0xe6: this.mouseScaling2 = false; return ack();
      case 0xe7: this.mouseScaling2 = true; return ack();
      case 0xf2: ack(); this.queue(0x00, true); return;   // id: plain PS/2 mouse
      case 0xe9:                                     // status
        ack();
        this.queue((this.mouseReporting ? 0x20 : 0) | (this.mouseScaling2 ? 0x10 : 0), true);
        this.queue(this.mouseResolution, true);
        this.queue(this.mouseRate, true);
        return;
      default: return ack();
    }
  }

  /** Report a mouse movement / button state in the standard 3-byte packet. */
  mouseMove(dx, dy, buttons) {
    if (!this.mouseReporting || !this.auxEnabled) return;
    // A full buffer loses whole packets, never a byte of one: the guest finds
    // packet boundaries by counting, and one dropped byte misaligns the rest.
    if (this.output.length > 61) return;
    dx = Math.max(-255, Math.min(255, dx | 0));
    dy = Math.max(-255, Math.min(255, -(dy | 0)));
    const b0 = 0x08 | (buttons & 7) |
               (dx < 0 ? 0x10 : 0) | (dy < 0 ? 0x20 : 0);
    this.queue(b0, true);
    this.queue(dx & 0xff, true);
    this.queue(dy & 0xff, true);
  }
}
