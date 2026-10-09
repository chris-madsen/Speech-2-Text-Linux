use anyhow::{anyhow, Context, Result};
use log::{debug, error, info, warn};
use std::process::Command;
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
    CaptureTargetWindow,
    TriggerManualPaste,
    ClearLastText,
}

pub struct X11Context {
    cmd_tx: mpsc::Sender<X11Command>,
}

#[derive(Clone, Copy)]
struct X11Atoms {
    clipboard: Atom,
    primary: Atom,
    secondary: Atom,
    utf8_string: Atom,
    string: Atom,
    targets: Atom,
    text_plain: Atom,
    text_plain_utf8: Atom,
    saved_clipboard_property: Atom,
    saved_primary_property: Atom,
    net_active_window: Atom,
    wm_class: Atom,
    net_wm_name: Atom,
    wm_name: Atom,
}

struct X11Session {
    conn: Arc<RustConnection>,
    root: Window,
    win: Window,
    atoms: X11Atoms,
}

struct RestorePlan {
    earliest_restore_at: std::time::Instant,
    force_restore_at: std::time::Instant,
    clipboard_restore: Option<String>,
    primary_restore: Option<String>,
    clipboard_served: bool,
}

#[derive(Clone, Debug)]
struct WindowContext {
    id: Window,
    class: String,
    title: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PasteShortcut {
    ShiftInsert,
    CtrlV,
    CtrlShiftV,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PasteBackend {
    Native,
    Xclip,
}

impl PasteShortcut {
    fn label(self) -> &'static str {
        match self {
            Self::ShiftInsert => "shift+insert",
            Self::CtrlV => "ctrl+v",
            Self::CtrlShiftV => "ctrl+shift+v",
        }
    }
}

impl PasteBackend {
    fn label(self) -> &'static str {
        match self {
            Self::Native => "native",
            Self::Xclip => "xclip",
        }
    }
}

impl X11Context {
    pub fn new(hotkey_tx: mpsc::Sender<crate::modules::monitor::HotkeyEvent>) -> Result<Self> {
        let (cmd_tx, cmd_rx) = mpsc::channel::<X11Command>(64);

        std::thread::spawn(move || {
            if let Err(e) = Self::x11_thread(cmd_rx, hotkey_tx) {
                error!("X11 thread error: {:#}", e);
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

    pub async fn capture_target_window(&self) {
        let _ = self.cmd_tx.send(X11Command::CaptureTargetWindow).await;
    }

    pub async fn trigger_manual_paste(&self) {
        let _ = self.cmd_tx.send(X11Command::TriggerManualPaste).await;
    }

    pub async fn clear_last_text(&self) {
        let _ = self.cmd_tx.send(X11Command::ClearLastText).await;
    }

    fn x11_thread(
        mut cmd_rx: mpsc::Receiver<X11Command>,
        hotkey_tx: mpsc::Sender<crate::modules::monitor::HotkeyEvent>,
    ) -> Result<()> {
        let mut secondary_text = String::new();
        let mut warned_unavailable = false;
        let mut target_window: Option<Window> = None;
        let mut capture_target_on_connect = false;
        let mut persistent_restore_plan: Option<(Option<String>, Option<String>)> = None;

        loop {
            let mut pending_paste = false;
            match Self::connect_session() {
                Ok(mut session) => {
                    warned_unavailable = false;

                    while let Ok(cmd) = cmd_rx.try_recv() {
                        match cmd {
                            X11Command::SetSecondary(text) => secondary_text = text,
                            X11Command::PasteSecondaryFast(text) => {
                                if !text.is_empty() {
                                    secondary_text = text;
                                }
                                pending_paste = true;
                            }
                            X11Command::CaptureTargetWindow => {
                                capture_target_on_connect = true;
                            }
                            X11Command::TriggerManualPaste => {
                                pending_paste = true;
                            }
                            X11Command::ClearLastText => {
                                secondary_text.clear();
                                pending_paste = false;
                            }
                        }
                    }

                    if capture_target_on_connect {
                        target_window = Self::query_active_window(&session).ok().flatten();
                        if let Some(window) = target_window {
                            debug!("captured target window id={window}");
                        }
                        capture_target_on_connect = false;
                    }

                    if !secondary_text.is_empty() {
                        Self::publish_secondary(&session, &secondary_text)?;
                    }

                    if pending_paste && !secondary_text.is_empty() {
                        let mut clipboard_text = String::new();
                        let mut primary_text = String::new();
                        let mut restore_plan = None;
                        if let Err(e) = Self::perform_paste(
                            &session,
                            &secondary_text,
                            &mut clipboard_text,
                            &mut primary_text,
                            &mut restore_plan,
                            target_window,
                        ) {
                            warn!("Deferred X11 paste after reconnect failed: {:#}", e);
                        }
                    }

                    if let Err(e) = Self::run_connected(
                        &mut session,
                        &mut cmd_rx,
                        &hotkey_tx,
                        &mut secondary_text,
                        &mut target_window,
                        &mut persistent_restore_plan,
                    ) {
                        warn!("X11 session lost, retrying: {:#}", e);
                        std::thread::sleep(std::time::Duration::from_millis(300));
                    }
                }
                Err(e) => {
                    while let Ok(cmd) = cmd_rx.try_recv() {
                        match cmd {
                            X11Command::SetSecondary(text) => secondary_text = text,
                            X11Command::PasteSecondaryFast(text) => {
                                if !text.is_empty() {
                                    secondary_text = text;
                                }
                                pending_paste = true;
                            }
                            X11Command::CaptureTargetWindow => {
                                capture_target_on_connect = true;
                            }
                            X11Command::TriggerManualPaste => {
                                pending_paste = true;
                            }
                            X11Command::ClearLastText => {
                                secondary_text.clear();
                                pending_paste = false;
                            }
                        }
                    }

                    if pending_paste {
                        debug!("X11 unavailable; paste deferred until a session is available");
                    }
                    if !warned_unavailable {
                        warn!("X11 unavailable: {:#}", e);
                        warned_unavailable = true;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(500));
                }
            }
        }
    }

    fn connect_session() -> Result<X11Session> {
        Self::import_graphical_env_from_systemd();
        let display = std::env::var("DISPLAY")
            .ok()
            .filter(|value| !value.trim().is_empty());
        let (conn, screen_num) = x11rb::connect(display.as_deref())
            .context("failed to connect to X11 display for paste automation")?;
        let conn = Arc::new(conn);
        let root = conn.setup().roots[screen_num].root;

        let atoms = X11Atoms {
            clipboard: conn.intern_atom(false, b"CLIPBOARD")?.reply()?.atom,
            primary: conn.intern_atom(false, b"PRIMARY")?.reply()?.atom,
            secondary: conn.intern_atom(false, b"SECONDARY")?.reply()?.atom,
            utf8_string: conn.intern_atom(false, b"UTF8_STRING")?.reply()?.atom,
            string: u32::from(AtomEnum::STRING),
            targets: conn.intern_atom(false, b"TARGETS")?.reply()?.atom,
            text_plain: conn.intern_atom(false, b"text/plain")?.reply()?.atom,
            text_plain_utf8: conn
                .intern_atom(false, b"text/plain;charset=utf-8")?
                .reply()?
                .atom,
            saved_clipboard_property: conn
                .intern_atom(false, b"S2T_SAVED_CLIPBOARD")?
                .reply()?
                .atom,
            saved_primary_property: conn.intern_atom(false, b"S2T_SAVED_PRIMARY")?.reply()?.atom,
            net_active_window: conn
                .intern_atom(false, b"_NET_ACTIVE_WINDOW")?
                .reply()?
                .atom,
            wm_class: conn.intern_atom(false, b"WM_CLASS")?.reply()?.atom,
            net_wm_name: conn.intern_atom(false, b"_NET_WM_NAME")?.reply()?.atom,
            wm_name: conn.intern_atom(false, b"WM_NAME")?.reply()?.atom,
        };

        let win = conn.generate_id()?;
        conn.create_window(
            x11rb::COPY_FROM_PARENT as u8,
            win,
            root,
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

        Ok(X11Session {
            conn,
            root,
            win,
            atoms,
        })
    }

    fn run_connected(
        session: &mut X11Session,
        cmd_rx: &mut mpsc::Receiver<X11Command>,
        hotkey_tx: &mpsc::Sender<crate::modules::monitor::HotkeyEvent>,
        secondary_text: &mut String,
        target_window: &mut Option<Window>,
        persistent_restore_plan: &mut Option<(Option<String>, Option<String>)>,
    ) -> Result<()> {
        let mut clipboard_text = String::new();
        let mut primary_text = String::new();
        // Restore any pending clipboard state that survived a previous reconnect
        let mut restore_plan: Option<RestorePlan> =
            persistent_restore_plan.take().map(|(cb, pr)| RestorePlan {
                earliest_restore_at: std::time::Instant::now(),
                force_restore_at: std::time::Instant::now()
                    + std::time::Duration::from_millis(3_000),
                clipboard_restore: cb,
                primary_restore: pr,
                clipboard_served: false,
            });

        loop {
            let mut do_paste = false;
            while let Ok(cmd) = cmd_rx.try_recv() {
                match cmd {
                    X11Command::SetSecondary(text) => {
                        *secondary_text = text;
                        Self::publish_secondary(session, secondary_text)?;
                    }
                    X11Command::PasteSecondaryFast(text) => {
                        if !text.is_empty() {
                            *secondary_text = text;
                        }
                        // Drain all pending commands first; paste once at end.
                        do_paste = true;
                    }
                    X11Command::CaptureTargetWindow => {
                        *target_window = Self::query_active_window(session)?;
                        if let Some(window) = *target_window {
                            debug!("captured target window id={window}");
                        }
                    }
                    X11Command::TriggerManualPaste => {
                        // Re-capture active window so paste goes to wherever focus is now
                        *target_window = Self::query_active_window(session)?;
                        if let Some(w) = *target_window {
                            debug!("ManualPaste: re-captured active window id={w}");
                        }
                        do_paste = true;
                    }
                    X11Command::ClearLastText => {
                        secondary_text.clear();
                        // Do NOT publish empty secondary to X11: that would cause
                        // the next Shift+Insert to fall back to the system clipboard.
                    }
                }
            }
            if do_paste {
                Self::perform_paste(
                    session,
                    secondary_text,
                    &mut clipboard_text,
                    &mut primary_text,
                    &mut restore_plan,
                    *target_window,
                )?;
            }

            Self::maybe_restore_clipboard(
                session,
                &mut clipboard_text,
                &mut primary_text,
                &mut restore_plan,
            )?;

            if let Some(event) = session.conn.poll_for_event()? {
                Self::handle_event(
                    session,
                    event,
                    hotkey_tx,
                    secondary_text,
                    &clipboard_text,
                    &primary_text,
                    &mut restore_plan,
                )?;
            } else {
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        }
    }

    fn publish_secondary(session: &X11Session, secondary_text: &str) -> Result<()> {
        let ts = get_timestamp(&session.conn, session.win)?;
        session
            .conn
            .set_selection_owner(session.win, session.atoms.secondary, ts)?;
        session.conn.flush()?;
        debug!(
            "secondary buffer published to X11 (chars={})",
            secondary_text.chars().count()
        );
        Ok(())
    }

    fn perform_paste(
        session: &X11Session,
        secondary_text: &str,
        clipboard_text: &mut String,
        primary_text: &mut String,
        restore_plan: &mut Option<RestorePlan>,
        target_window: Option<Window>,
    ) -> Result<()> {
        info!("Performing fast native paste...");
        if secondary_text.trim().is_empty() {
            debug!("secondary buffer empty; skip paste");
            return Ok(());
        }

        let backend = select_paste_backend();
        debug!("selected X11 paste backend: {}", backend.label());
        if backend == PasteBackend::Xclip {
            return Self::perform_paste_via_xclip(session, secondary_text, target_window);
        }

        let preserve = env_bool("S2T_PRESERVE_CLIPBOARD", true);
        let saved_clipboard = if preserve {
            Self::read_selection_text(session, session.atoms.clipboard)?
        } else {
            None
        };
        let saved_primary = if preserve {
            Self::read_selection_text(session, session.atoms.primary)?
        } else {
            None
        };

        // Take ownership of CLIPBOARD, PRIMARY and SECONDARY with our text.
        *clipboard_text = secondary_text.to_string();
        *primary_text = secondary_text.to_string();
        Self::publish_secondary(session, secondary_text)?;

        let ts = get_timestamp(&session.conn, session.win)?;
        session
            .conn
            .set_selection_owner(session.win, session.atoms.clipboard, ts)?;
        session
            .conn
            .set_selection_owner(session.win, session.atoms.primary, ts)?;
        session.conn.flush()?;

        // Drain any pending X11 events (e.g. leftover SelectionRequests from
        // a previous paste) before sending ctrl+v, so Chrome doesn't miss our
        // new CLIPBOARD ownership notification.
        while let Some(ev) = session.conn.poll_for_event()? {
            drop(ev);
        }

        let window_ctx = Self::resolve_window_context(session, target_window)?;
        if let Some(ctx) = &window_ctx {
            debug!(
                "paste target window id={} class='{}' title='{}'",
                ctx.id, ctx.class, ctx.title
            );
        }
        if let Some(window) = target_window {
            let _ = Self::refocus_target_window(session, window);
        }

        // Use auto-detected paste shortcut (ctrl+v for GUI, ctrl+shift+v for terminal).
        let keys = Self::select_paste_shortcut(window_ctx.as_ref());
        Self::release_common_modifiers(&session.conn)?;
        Self::send_paste_shortcut(
            session,
            target_window.or_else(|| window_ctx.as_ref().map(|ctx| ctx.id)),
            keys,
        )?;

        let restore_delay_ms = clipboard_restore_delay_ms(secondary_text);
        let force_restore_delay_ms = clipboard_force_restore_delay_ms(secondary_text);
        *restore_plan = Some(RestorePlan {
            earliest_restore_at: std::time::Instant::now()
                + std::time::Duration::from_millis(restore_delay_ms),
            force_restore_at: std::time::Instant::now()
                + std::time::Duration::from_millis(force_restore_delay_ms),
            clipboard_restore: saved_clipboard,
            primary_restore: saved_primary,
            clipboard_served: false,
        });
        debug!(
            "scheduled clipboard restore earliest={} ms force={} ms via {}",
            restore_delay_ms,
            force_restore_delay_ms,
            keys.label()
        );
        Ok(())
    }

    fn perform_paste_via_xclip(
        session: &X11Session,
        secondary_text: &str,
        target_window: Option<Window>,
    ) -> Result<()> {
        let preserve_clipboard = env_bool("S2T_PRESERVE_CLIPBOARD", true);
        let saved_clipboard = if preserve_clipboard {
            read_xclip_selection("clipboard")?
        } else {
            None
        };

        write_xclip_selection("clipboard", secondary_text)?;
        Self::publish_secondary(session, secondary_text)?;

        let window_ctx = Self::resolve_window_context(session, target_window)?;
        if let Some(ctx) = &window_ctx {
            debug!(
                "paste target window id={} class='{}' title='{}' via xclip",
                ctx.id, ctx.class, ctx.title
            );
        }
        if let Some(window) = target_window {
            let _ = Self::refocus_target_window(session, window);
        }

        let keys = Self::select_paste_shortcut(window_ctx.as_ref());
        Self::release_common_modifiers(&session.conn)?;
        Self::send_paste_shortcut(
            session,
            target_window.or_else(|| window_ctx.as_ref().map(|ctx| ctx.id)),
            keys,
        )?;

        let restore_delay_ms = clipboard_force_restore_delay_ms(secondary_text);
        debug!(
            "scheduled clipboard restore in {} ms via {} using xclip backend",
            restore_delay_ms,
            keys.label()
        );
        std::thread::sleep(std::time::Duration::from_millis(restore_delay_ms));

        if preserve_clipboard {
            restore_xclip_selection("clipboard", saved_clipboard.as_deref())?;
            debug!("clipboard restore completed via xclip");
        }
        Ok(())
    }

    fn maybe_restore_clipboard(
        session: &X11Session,
        clipboard_text: &mut String,
        primary_text: &mut String,
        restore_plan: &mut Option<RestorePlan>,
    ) -> Result<()> {
        let Some(plan) = restore_plan.as_ref() else {
            return Ok(());
        };
        let now = std::time::Instant::now();
        if now < plan.earliest_restore_at {
            return Ok(());
        }
        if !plan.clipboard_served && now < plan.force_restore_at {
            return Ok(());
        }

        let plan = restore_plan.take().expect("restore plan checked above");
        let ts = get_timestamp(&session.conn, session.win)?;

        match plan.clipboard_restore {
            Some(text) if !text.is_empty() => {
                *clipboard_text = text;
                session
                    .conn
                    .set_selection_owner(session.win, session.atoms.clipboard, ts)?;
            }
            _ => {
                clipboard_text.clear();
                session
                    .conn
                    .set_selection_owner(x11rb::NONE, session.atoms.clipboard, ts)?;
            }
        }

        match plan.primary_restore {
            Some(text) if !text.is_empty() => {
                *primary_text = text;
                session
                    .conn
                    .set_selection_owner(session.win, session.atoms.primary, ts)?;
            }
            _ => {
                primary_text.clear();
                session
                    .conn
                    .set_selection_owner(x11rb::NONE, session.atoms.primary, ts)?;
            }
        }

        session.conn.flush()?;
        debug!("clipboard restore completed");
        Ok(())
    }

    fn handle_event(
        session: &X11Session,
        event: x11rb::protocol::Event,
        hotkey_tx: &mpsc::Sender<crate::modules::monitor::HotkeyEvent>,
        secondary_text: &str,
        clipboard_text: &str,
        primary_text: &str,
        restore_plan: &mut Option<RestorePlan>,
    ) -> Result<()> {
        match event {
            x11rb::protocol::Event::SelectionRequest(e) => {
                let is_clipboard = e.selection == session.atoms.clipboard;
                let is_text_request = is_clipboard
                    && (e.target == session.atoms.utf8_string
                        || e.target == session.atoms.string
                        || e.target == session.atoms.text_plain
                        || e.target == session.atoms.text_plain_utf8);
                if is_clipboard {
                    debug!(
                        "clipboard selection requested by window={} target={}",
                        e.requestor, e.target
                    );
                }
                // Only mark served when the actual text content was requested,
                // not on TARGETS negotiation — Chrome always does TARGETS first,
                // then the real UTF8_STRING request. Marking served too early
                // releases clipboard ownership before Chrome gets the text,
                // causing it to hang waiting for a SelectionNotify that never comes.
                if is_text_request {
                    if let Some(plan) = restore_plan.as_mut() {
                        plan.clipboard_served = true;
                    }
                }
                let text_to_serve = if is_clipboard {
                    clipboard_text
                } else if e.selection == session.atoms.primary {
                    primary_text
                } else if e.selection == session.atoms.secondary {
                    secondary_text
                } else {
                    ""
                };
                Self::serve_selection_request(session, e, text_to_serve)?;
            }
            _ => {}
        }
        Ok(())
    }

    fn serve_selection_request(
        session: &X11Session,
        e: SelectionRequestEvent,
        text_to_serve: &str,
    ) -> Result<()> {
        let mut property = e.property;
        let mut success = false;

        if !text_to_serve.is_empty() {
            if property == x11rb::NONE {
                property = e.target;
            }

            if e.target == session.atoms.targets {
                let atoms = [
                    session.atoms.targets,
                    session.atoms.utf8_string,
                    session.atoms.string,
                    session.atoms.text_plain,
                    session.atoms.text_plain_utf8,
                ];
                session.conn.change_property32(
                    PropMode::REPLACE,
                    e.requestor,
                    property,
                    AtomEnum::ATOM,
                    &atoms,
                )?;
                success = true;
            } else if e.target == session.atoms.utf8_string
                || e.target == session.atoms.string
                || e.target == session.atoms.text_plain
                || e.target == session.atoms.text_plain_utf8
            {
                session.conn.change_property8(
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
        session
            .conn
            .send_event(false, e.requestor, EventMask::NO_EVENT, notify)?;
        session.conn.flush()?;
        Ok(())
    }

    fn read_selection_text(session: &X11Session, selection: Atom) -> Result<Option<String>> {
        let owner = session.conn.get_selection_owner(selection)?.reply()?.owner;
        if owner == x11rb::NONE || owner == session.win {
            return Ok(None);
        }

        let property = if selection == session.atoms.clipboard {
            session.atoms.saved_clipboard_property
        } else if selection == session.atoms.primary {
            session.atoms.saved_primary_property
        } else {
            return Err(anyhow!("unsupported selection atom {}", selection));
        };

        let ts = get_timestamp(&session.conn, session.win)?;
        let _ = session.conn.delete_property(session.win, property);
        session.conn.convert_selection(
            session.win,
            selection,
            session.atoms.utf8_string,
            property,
            ts,
        )?;
        session.conn.flush()?;

        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(180);
        while std::time::Instant::now() < deadline {
            if let Some(event) = session.conn.poll_for_event()? {
                match event {
                    x11rb::protocol::Event::SelectionNotify(e)
                        if e.requestor == session.win && e.selection == selection =>
                    {
                        if e.property == x11rb::NONE {
                            return Ok(None);
                        }
                        let reply = session
                            .conn
                            .get_property(false, session.win, property, AtomEnum::ANY, 0, u32::MAX)?
                            .reply()?;
                        let _ = session.conn.delete_property(session.win, property);
                        if reply.value.is_empty() {
                            return Ok(None);
                        }
                        let text = String::from_utf8(reply.value)
                            .ok()
                            .map(|value| value.trim_matches('\0').to_string())
                            .filter(|value| !value.is_empty());
                        return Ok(text);
                    }
                    x11rb::protocol::Event::SelectionRequest(e) => {
                        Self::serve_selection_request(session, e, "")?;
                    }
                    _ => {}
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        Ok(None)
    }

    fn query_active_window(session: &X11Session) -> Result<Option<Window>> {
        let reply = session
            .conn
            .get_property(
                false,
                session.root,
                session.atoms.net_active_window,
                AtomEnum::WINDOW,
                0,
                1,
            )?
            .reply()?;
        let mut iter = reply.value32();
        let window = iter.as_mut().and_then(|values| values.next()).unwrap_or(0);
        if window == 0 || window == session.win {
            Ok(None)
        } else {
            Ok(Some(window))
        }
    }

    fn resolve_window_context(
        session: &X11Session,
        target_window: Option<Window>,
    ) -> Result<Option<WindowContext>> {
        let window =
            match target_window.or_else(|| Self::query_active_window(session).ok().flatten()) {
                Some(window) if window != session.win => window,
                _ => return Ok(None),
            };
        let class = Self::get_window_property_string(session, window, session.atoms.wm_class)
            .unwrap_or_default()
            .replace('\0', " ");
        let title = Self::get_window_title(session, window).unwrap_or_default();
        Ok(Some(WindowContext {
            id: window,
            class,
            title,
        }))
    }

    fn get_window_title(session: &X11Session, window: Window) -> Result<String> {
        let title = Self::get_window_property_string(session, window, session.atoms.net_wm_name)?;
        if !title.is_empty() {
            return Ok(title);
        }
        Self::get_window_property_string(session, window, session.atoms.wm_name)
    }

    fn get_window_property_string(
        session: &X11Session,
        window: Window,
        property: Atom,
    ) -> Result<String> {
        let reply = session
            .conn
            .get_property(false, window, property, AtomEnum::ANY, 0, 4096)?
            .reply()?;
        if reply.value.is_empty() {
            return Ok(String::new());
        }
        Ok(String::from_utf8_lossy(&reply.value)
            .trim_matches('\0')
            .to_string())
    }

    fn select_paste_shortcut(window_ctx: Option<&WindowContext>) -> PasteShortcut {
        if let Some(explicit) = env_string("S2T_PASTE_KEYS") {
            if !explicit.eq_ignore_ascii_case("auto") {
                return parse_paste_shortcut(&explicit)
                    .unwrap_or_else(|| parse_paste_shortcut("shift+insert").unwrap());
            }
        }

        let terminal = env_string("S2T_PASTE_KEYS_TERMINAL")
            .and_then(|v| parse_paste_shortcut(&v))
            .unwrap_or(PasteShortcut::CtrlShiftV);
        let gui = env_string("S2T_PASTE_KEYS_GUI")
            .and_then(|v| parse_paste_shortcut(&v))
            .unwrap_or(PasteShortcut::CtrlV);
        let fallback = env_string("S2T_PASTE_KEYS_FALLBACK")
            .and_then(|v| parse_paste_shortcut(&v))
            .unwrap_or(PasteShortcut::ShiftInsert);

        if let Some(ctx) = window_ctx {
            if is_terminal_class(&ctx.class) || is_vscode_terminal_focus(&ctx.class, &ctx.title) {
                return terminal;
            }
            return gui;
        }

        fallback
    }

    fn refocus_target_window(session: &X11Session, target_window: Window) -> Result<()> {
        if !env_bool("S2T_REFOCUS_TARGET_WINDOW", true) || target_window == 0 {
            return Ok(());
        }
        let settle_ms = env_u64("S2T_PASTE_FOCUS_SETTLE_MS", 80).clamp(20, 2_000);
        if command_exists("xdotool") {
            let status = Command::new("xdotool")
                .args(["windowactivate", "--sync", &target_window.to_string()])
                .status();
            match status {
                Ok(status) if status.success() => {
                    let _ = Command::new("xdotool")
                        .args(["windowfocus", &target_window.to_string()])
                        .status();
                    std::thread::sleep(std::time::Duration::from_millis(settle_ms));
                    return Ok(());
                }
                Ok(status) => warn!("xdotool windowactivate failed: {}", status),
                Err(e) => warn!("failed to execute xdotool windowactivate: {}", e),
            }
        }

        let _ =
            session
                .conn
                .set_input_focus(InputFocus::PARENT, target_window, x11rb::CURRENT_TIME);
        let _ = session.conn.flush();
        std::thread::sleep(std::time::Duration::from_millis(settle_ms));
        Ok(())
    }

    fn send_paste_shortcut(
        session: &X11Session,
        _target_window: Option<Window>,
        keys: PasteShortcut,
    ) -> Result<()> {
        if command_exists("xdotool") {
            let combo = match keys {
                PasteShortcut::ShiftInsert => "shift+Insert",
                PasteShortcut::CtrlV => "ctrl+v",
                PasteShortcut::CtrlShiftV => "ctrl+shift+v",
            };
            let status = Command::new("xdotool")
                .args(["key", "--clearmodifiers", combo])
                .status()
                .context("failed to execute xdotool key")?;
            if status.success() {
                return Ok(());
            }
            return Err(anyhow!("xdotool key failed with status {}", status));
        }

        match keys {
            PasteShortcut::ShiftInsert => Self::send_shift_insert(&session.conn),
            PasteShortcut::CtrlV => Self::send_ctrl_v(&session.conn),
            PasteShortcut::CtrlShiftV => Self::send_ctrl_shift_v(&session.conn),
        }
    }

    fn send_shift_insert(conn: &RustConnection) -> Result<()> {
        let shift_l = 50;
        let insert_key = 118;
        conn.xtest_fake_input(2, shift_l, 0, 0, 0, 0, 0)?;
        conn.xtest_fake_input(2, insert_key, 0, 0, 0, 0, 0)?;
        conn.xtest_fake_input(3, insert_key, 0, 0, 0, 0, 0)?;
        conn.xtest_fake_input(3, shift_l, 0, 0, 0, 0, 0)?;
        conn.flush()?;
        Ok(())
    }

    fn send_ctrl_v(conn: &RustConnection) -> Result<()> {
        let ctrl_l = 37;
        let v_key = 55;
        conn.xtest_fake_input(2, ctrl_l, 0, 0, 0, 0, 0)?;
        conn.xtest_fake_input(2, v_key, 0, 0, 0, 0, 0)?;
        conn.xtest_fake_input(3, v_key, 0, 0, 0, 0, 0)?;
        conn.xtest_fake_input(3, ctrl_l, 0, 0, 0, 0, 0)?;
        conn.flush()?;
        Ok(())
    }

    fn send_ctrl_shift_v(conn: &RustConnection) -> Result<()> {
        let ctrl_l = 37;
        let shift_l = 50;
        let v_key = 55;
        conn.xtest_fake_input(2, ctrl_l, 0, 0, 0, 0, 0)?;
        conn.xtest_fake_input(2, shift_l, 0, 0, 0, 0, 0)?;
        conn.xtest_fake_input(2, v_key, 0, 0, 0, 0, 0)?;
        conn.xtest_fake_input(3, v_key, 0, 0, 0, 0, 0)?;
        conn.xtest_fake_input(3, shift_l, 0, 0, 0, 0, 0)?;
        conn.xtest_fake_input(3, ctrl_l, 0, 0, 0, 0, 0)?;
        conn.flush()?;
        Ok(())
    }

    fn release_common_modifiers(conn: &RustConnection) -> Result<()> {
        for keycode in [37u8, 50, 62, 64, 105, 108, 133, 134] {
            conn.xtest_fake_input(3, keycode, 0, 0, 0, 0, 0)?;
        }
        conn.flush()?;
        Ok(())
    }

    fn import_graphical_env_from_systemd() {
        let need_display = std::env::var("DISPLAY")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .is_none();
        let need_xauth = std::env::var("XAUTHORITY")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .is_none();
        if !need_display && !need_xauth {
            return;
        }

        let output = match Command::new("systemctl")
            .args(["--user", "show-environment"])
            .output()
        {
            Ok(output) if output.status.success() => output,
            _ => return,
        };

        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            if value.trim().is_empty() {
                continue;
            }
            match key {
                "DISPLAY"
                | "WAYLAND_DISPLAY"
                | "XAUTHORITY"
                | "DBUS_SESSION_BUS_ADDRESS"
                | "XDG_SESSION_TYPE" => {
                    if std::env::var(key)
                        .ok()
                        .filter(|current| !current.trim().is_empty())
                        .is_none()
                    {
                        std::env::set_var(key, value);
                    }
                }
                _ => {}
            }
        }
    }
}

fn parse_paste_shortcut(raw: &str) -> Option<PasteShortcut> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "shift+insert" => Some(PasteShortcut::ShiftInsert),
        "ctrl+v" => Some(PasteShortcut::CtrlV),
        "ctrl+shift+v" => Some(PasteShortcut::CtrlShiftV),
        _ => None,
    }
}

fn parse_paste_backend(raw: &str) -> Option<PasteBackend> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "native" => Some(PasteBackend::Native),
        "xclip" => Some(PasteBackend::Xclip),
        "auto" => None,
        _ => None,
    }
}

fn env_bool(name: &str, default: bool) -> bool {
    match std::env::var(name) {
        Ok(raw) => match raw.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => true,
            "0" | "false" | "no" | "off" => false,
            _ => default,
        },
        Err(_) => default,
    }
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|raw| raw.trim().parse::<u64>().ok())
        .unwrap_or(default)
}

fn env_string(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|raw| raw.trim().to_string())
        .filter(|raw| !raw.is_empty())
}

fn select_paste_backend() -> PasteBackend {
    if let Some(explicit) =
        env_string("S2T_X11_PASTE_BACKEND").and_then(|value| parse_paste_backend(&value))
    {
        return explicit;
    }
    PasteBackend::Native
}

fn command_exists(name: &str) -> bool {
    Command::new("sh")
        .args(["-lc", &format!("command -v {} >/dev/null 2>&1", name)])
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn is_terminal_class(class_name: &str) -> bool {
    let cls = class_name.to_ascii_lowercase();
    [
        "gnome-terminal",
        "terminal",
        "kitty",
        "alacritty",
        "wezterm",
        "tilix",
        "konsole",
        "xterm",
        "rxvt",
        "st-",
        "foot",
    ]
    .iter()
    .any(|needle| cls.contains(needle))
}

fn is_vscode_terminal_focus(class_name: &str, title: &str) -> bool {
    let cls = class_name.to_ascii_lowercase();
    if !(cls.contains("vscodium") || cls.contains("code") || cls.contains("codium")) {
        return false;
    }
    let title = title.to_ascii_lowercase();
    ["terminal", "терминал", "tmux", "bash", "zsh", "fish"]
        .iter()
        .any(|needle| title.contains(needle))
}

fn clipboard_restore_delay_ms(text: &str) -> u64 {
    let base = env_u64("S2T_CLIPBOARD_RESTORE_DELAY_MS", 120).clamp(20, 5_000);
    let per_char = env_u64("S2T_CLIPBOARD_RESTORE_PER_CHAR_MS", 0).min(50);
    let extra_cap = env_u64("S2T_CLIPBOARD_RESTORE_EXTRA_MAX_MS", 2_500).min(30_000);
    let extra = (text.chars().count() as u64)
        .saturating_mul(per_char)
        .min(extra_cap);
    base.saturating_add(extra)
}

fn clipboard_force_restore_delay_ms(text: &str) -> u64 {
    let base = clipboard_restore_delay_ms(text);
    env_u64("S2T_CLIPBOARD_RESTORE_MAX_WAIT_MS", 1_500).clamp(base.max(120), 10_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_paste_backend_handles_supported_values() {
        assert_eq!(parse_paste_backend("native"), Some(PasteBackend::Native));
        assert_eq!(parse_paste_backend("xclip"), Some(PasteBackend::Xclip));
        assert_eq!(parse_paste_backend("AUTO"), None);
        assert_eq!(parse_paste_backend("unknown"), None);
    }

    #[test]
    fn select_paste_backend_defaults_to_native() {
        std::env::remove_var("S2T_X11_PASTE_BACKEND");
        assert_eq!(select_paste_backend(), PasteBackend::Native);
    }

    #[test]
    fn select_paste_backend_honors_explicit_override() {
        std::env::set_var("S2T_X11_PASTE_BACKEND", "xclip");
        assert_eq!(select_paste_backend(), PasteBackend::Xclip);
        std::env::remove_var("S2T_X11_PASTE_BACKEND");
    }
}

fn read_xclip_selection(selection: &str) -> Result<Option<String>> {
    let output = Command::new("xclip")
        .args(["-selection", selection, "-o"])
        .output()
        .with_context(|| format!("failed to read X11 {} selection via xclip", selection))?;
    if !output.status.success() {
        return Ok(None);
    }
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    if text.is_empty() {
        Ok(None)
    } else {
        Ok(Some(text))
    }
}

fn write_xclip_selection(selection: &str, text: &str) -> Result<()> {
    let mut child = Command::new("xclip")
        .args(["-selection", selection, "-i"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .with_context(|| format!("failed to spawn xclip for {} selection", selection))?;

    {
        let stdin = child
            .stdin
            .as_mut()
            .ok_or_else(|| anyhow!("xclip stdin unavailable for {} selection", selection))?;
        use std::io::Write as _;
        stdin.write_all(text.as_bytes())?;
        stdin.flush()?;
    }
    let _ = child.stdin.take();

    let status = child
        .wait()
        .with_context(|| format!("failed to wait for xclip {} selection", selection))?;
    if !status.success() {
        return Err(anyhow!(
            "xclip write failed for {} selection with status {}",
            selection,
            status
        ));
    }
    Ok(())
}

fn restore_xclip_selection(selection: &str, text: Option<&str>) -> Result<()> {
    match text {
        Some(value) => write_xclip_selection(selection, value),
        None => Ok(()),
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
