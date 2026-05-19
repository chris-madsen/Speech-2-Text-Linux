use anyhow::Result;
use log::{debug, error, info};
use std::sync::Arc;
use tokio::sync::mpsc;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::*;
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

pub enum X11Command {
    SetSecondary(String),
    PasteSecondaryFast(String),
}

pub struct X11Context {
    cmd_tx: mpsc::Sender<X11Command>,
}

impl X11Context {
    pub fn new(hotkey_tx: mpsc::Sender<crate::modules::monitor::HotkeyEvent>) -> Result<Self> {
        let (cmd_tx, cmd_rx) = mpsc::channel::<X11Command>(10);

        std::thread::spawn(move || {
            if let Err(e) = Self::x11_thread(cmd_rx, hotkey_tx) {
                error!("X11 thread error: {}", e);
            }
        });

        Ok(Self { cmd_tx })
    }

    pub async fn set_last_text(&self, text: String) {
        let _ = self.cmd_tx.send(X11Command::SetSecondary(text)).await;
    }

    pub async fn paste_secondary_fast(&self, text: String) -> Result<()> {
        self.cmd_tx
            .send(X11Command::PasteSecondaryFast(text))
            .await?;
        Ok(())
    }

    fn x11_thread(
        mut cmd_rx: mpsc::Receiver<X11Command>,
        hotkey_tx: mpsc::Sender<crate::modules::monitor::HotkeyEvent>,
    ) -> Result<()> {
        let (conn, screen_num) = x11rb::connect(None)?;
        let conn = Arc::new(conn);
        let screen = &conn.setup().roots[screen_num];

        // Grab Alt+V
        let v_keycode = 55;
        let _ = conn.ungrab_key(v_keycode, screen.root, ModMask::ANY);
        let modifiers = [
            ModMask::M1,
            ModMask::M1 | ModMask::M2,
            ModMask::M1 | ModMask::LOCK,
            ModMask::M1 | ModMask::M2 | ModMask::LOCK,
        ];
        for &mods in &modifiers {
            conn.grab_key(
                false,
                screen.root,
                mods,
                v_keycode,
                GrabMode::ASYNC,
                GrabMode::ASYNC,
            )?;
        }
        conn.flush()?;
        info!("Alt+V grabbed successfully.");

        let clipboard_atom = conn.intern_atom(false, b"CLIPBOARD")?.reply()?.atom;
        let primary_atom = conn.intern_atom(false, b"PRIMARY")?.reply()?.atom;
        let secondary_atom = conn.intern_atom(false, b"SECONDARY")?.reply()?.atom;
        let utf8_string_atom = conn.intern_atom(false, b"UTF8_STRING")?.reply()?.atom;
        let targets_atom = conn.intern_atom(false, b"TARGETS")?.reply()?.atom;
        let text_plain_atom = conn.intern_atom(false, b"text/plain")?.reply()?.atom;
        let text_plain_utf8_atom = conn
            .intern_atom(false, b"text/plain;charset=utf-8")?
            .reply()?
            .atom;

        // Create a window to own selections
        let win = conn.generate_id()?;
        conn.create_window(
            x11rb::COPY_FROM_PARENT as u8,
            win,
            screen.root,
            0,
            0,
            1,
            1,
            0,
            WindowClass::INPUT_OUTPUT,
            x11rb::COPY_FROM_PARENT,
            &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE),
        )?;
        conn.flush()?;

        let mut secondary_text = String::new();
        let mut clipboard_text = String::new();
        let mut restore_clipboard_after: Option<std::time::Instant> = None;

        loop {
            // Check commands
            while let Ok(cmd) = cmd_rx.try_recv() {
                match cmd {
                    X11Command::SetSecondary(text) => {
                        secondary_text = text;
                        let ts = get_timestamp(&conn, win)?;
                        conn.set_selection_owner(win, secondary_atom, ts)?;
                        conn.flush()?;
                    }
                    X11Command::PasteSecondaryFast(text) => {
                        info!("Performing fast native paste...");
                        if !text.is_empty() {
                            secondary_text = text;
                        }
                        if secondary_text.is_empty() {
                            debug!("secondary buffer empty; skip paste");
                            continue;
                        }
                        clipboard_text = secondary_text.clone();

                        // 2. Become owner of CLIPBOARD and PRIMARY
                        let ts = get_timestamp(&conn, win)?;
                        conn.set_selection_owner(win, clipboard_atom, ts)?;
                        conn.set_selection_owner(win, primary_atom, ts)?;

                        // 3. Trigger Shift+Insert natively
                        let shift_l = 50;
                        let shift_r = 62;
                        let insert_key = 118;
                        let alt_l = 64;
                        let alt_r = 108;
                        let l_ctrl = 37;

                        // Clear modifiers
                        conn.xtest_fake_input(3, alt_l, 0, 0, 0, 0, 0)?;
                        conn.xtest_fake_input(3, alt_r, 0, 0, 0, 0, 0)?;
                        conn.xtest_fake_input(3, shift_l, 0, 0, 0, 0, 0)?;
                        conn.xtest_fake_input(3, shift_r, 0, 0, 0, 0, 0)?;
                        conn.xtest_fake_input(3, l_ctrl, 0, 0, 0, 0, 0)?;

                        conn.xtest_fake_input(2, shift_l, 0, 0, 0, 0, 0)?;
                        conn.xtest_fake_input(2, insert_key, 0, 0, 0, 0, 0)?;
                        conn.xtest_fake_input(3, insert_key, 0, 0, 0, 0, 0)?;
                        conn.xtest_fake_input(3, shift_l, 0, 0, 0, 0, 0)?;
                        conn.flush()?;

                        // 4. Schedule restore
                        restore_clipboard_after =
                            Some(std::time::Instant::now() + std::time::Duration::from_millis(300));
                    }
                }
            }

            // Check restore timeout
            if let Some(time) = restore_clipboard_after {
                if std::time::Instant::now() >= time {
                    restore_clipboard_after = None;
                    if let Ok(ts) = get_timestamp(&conn, win) {
                        let _ = conn.set_selection_owner(x11rb::NONE, clipboard_atom, ts);
                        let _ = conn.set_selection_owner(x11rb::NONE, primary_atom, ts);
                    }
                    let _ = conn.flush();
                }
            }

            // Check X11 events
            if let Some(event) = conn.poll_for_event()? {
                match event {
                    x11rb::protocol::Event::KeyPress(e) => {
                        if e.detail == 55 && (u16::from(e.state) & u16::from(ModMask::M1)) != 0 {
                            debug!("Alt+V detected in X11 grab!");
                            let _ = hotkey_tx
                                .blocking_send(crate::modules::monitor::HotkeyEvent::ManualPaste);
                        }
                    }
                    x11rb::protocol::Event::SelectionRequest(e) => {
                        let text_to_serve =
                            if e.selection == clipboard_atom || e.selection == primary_atom {
                                &clipboard_text
                            } else if e.selection == secondary_atom {
                                &secondary_text
                            } else {
                                ""
                            };

                        let mut property = e.property;
                        let mut success = false;

                        if !text_to_serve.is_empty() {
                            if property == x11rb::NONE {
                                property = e.target;
                            }

                            if e.target == targets_atom {
                                let atoms = [
                                    targets_atom,
                                    utf8_string_atom,
                                    u32::from(AtomEnum::STRING),
                                    text_plain_atom,
                                    text_plain_utf8_atom,
                                ];
                                conn.change_property32(
                                    PropMode::REPLACE,
                                    e.requestor,
                                    property,
                                    AtomEnum::ATOM,
                                    &atoms,
                                )?;
                                success = true;
                            } else if e.target == utf8_string_atom
                                || e.target == u32::from(AtomEnum::STRING)
                                || e.target == text_plain_atom
                                || e.target == text_plain_utf8_atom
                            {
                                conn.change_property8(
                                    PropMode::REPLACE,
                                    e.requestor,
                                    property,
                                    e.target,
                                    text_to_serve.as_bytes(),
                                )?;
                                success = true;
                            }
                        }

                        let notify = SelectionNotifyEvent {
                            response_type: SELECTION_NOTIFY_EVENT,
                            sequence: 0,
                            time: e.time,
                            requestor: e.requestor,
                            selection: e.selection,
                            target: e.target,
                            property: if success { property } else { x11rb::NONE },
                        };
                        conn.send_event(false, e.requestor, EventMask::NO_EVENT, notify)?;
                        conn.flush()?;
                    }
                    _ => {}
                }
            } else {
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        }
    }
}

fn get_timestamp(conn: &RustConnection, win: u32) -> Result<u32> {
    let dummy_atom = conn.intern_atom(false, b"DUMMY_PROP")?.reply()?.atom;
    conn.change_property32(PropMode::REPLACE, win, dummy_atom, AtomEnum::INTEGER, &[0])?;
    conn.flush()?;

    let mut timestamp = x11rb::CURRENT_TIME;
    let start_wait = std::time::Instant::now();
    while start_wait.elapsed() < std::time::Duration::from_millis(100) {
        if let Some(event) = conn.poll_for_event()? {
            if let x11rb::protocol::Event::PropertyNotify(e) = event {
                if e.window == win && e.atom == dummy_atom {
                    timestamp = e.time;
                    break;
                }
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    Ok(timestamp)
}
