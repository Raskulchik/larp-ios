//! Discord Rich Presence: коннект к локальному клиенту Discord (IPC/Unix socket),
//! активность задаёт телефон через демон. Логика — как в music-player-tui/src/discord_rpc.rs.
use discord_rich_presence::{
    DiscordIpc, DiscordIpcClient, activity, activity::ActivityType,
};
use std::sync::mpsc;
use std::time::Duration;

#[derive(Clone)]
pub enum RpcCommand {
    SetActivity {
        title: String,
        artist: String,
        artwork_url: Option<String>,
        duration_ms: Option<u64>,
        state: String,
        /// Позиция в треке (ms) — стартовый timestamp сдвигается назад, чтобы таймер Discord не врал.
        position_ms: Option<u64>,
        show_timer: bool,
    },
    Clear,
}

impl RpcCommand {
    fn apply(&self, client: &mut DiscordIpcClient) -> Result<(), Box<dyn std::error::Error>> {
        match self {
            RpcCommand::Clear => {
                client.clear_activity()?;
            }
            RpcCommand::SetActivity {
                title,
                artist,
                artwork_url,
                duration_ms,
                state,
                position_ms,
                show_timer,
            } => {
                let mut assets = activity::Assets::new();
                if let Some(url) = artwork_url {
                    assets = assets.large_image(url);
                }

                let mut act = activity::Activity::new()
                    .state(artist.as_str())
                    .details(format!("{} • {}", state, title))
                    .assets(assets)
                    .activity_type(ActivityType::Listening);

                if *show_timer {
                    if let Some(dur) = duration_ms {
                        let now = now_ms();
                        let start = now - position_ms.unwrap_or(0).min(*dur) as i64;
                        act = act.timestamps(activity::Timestamps::new().start(start).end(start + *dur as i64));
                    }
                }

                client.set_activity(act)?;
            }
        }
        Ok(())
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

pub struct DiscordRpc {
    cmd_tx: mpsc::Sender<RpcCommand>,
}

impl DiscordRpc {
    /// Запускает фоновый поток с reconnect'ом. DiscordRpc::new("")
    /// вернёт None, если client_id пустой (RPC выключен).
    pub fn new(client_id: &str) -> Option<Self> {
        if client_id.is_empty() {
            return None;
        }
        let client_id = client_id.to_string();
        let (cmd_tx, cmd_rx) = mpsc::channel();
        std::thread::spawn(move || {
            run_rpc_loop(&client_id, cmd_rx);
        });
        Some(Self { cmd_tx })
    }

    pub fn set_activity(
        &self,
        title: &str,
        artist: &str,
        artwork_url: Option<&str>,
        duration_ms: Option<u64>,
        state: &str,
        position_ms: Option<u64>,
        show_timer: bool,
    ) {
        let _ = self.cmd_tx.send(RpcCommand::SetActivity {
            title: title.to_string(),
            artist: artist.to_string(),
            artwork_url: artwork_url.map(|s| s.to_string()),
            duration_ms,
            state: state.to_string(),
            position_ms,
            show_timer,
        });
    }

    pub fn clear(&self) {
        let _ = self.cmd_tx.send(RpcCommand::Clear);
    }
}

fn try_connect(client: &mut DiscordIpcClient) -> bool {
    match client.connect() {
        Ok(()) => {
            eprintln!("[discord] connected");
            true
        }
        Err(e) => {
            eprintln!("[discord] connect failed (will retry): {e}");
            false
        }
    }
}

fn run_rpc_loop(client_id: &str, rx: mpsc::Receiver<RpcCommand>) {
    let mut client = DiscordIpcClient::new(client_id);
    let mut connected = try_connect(&mut client);
    let mut pending: Option<RpcCommand> = None;

    loop {
        if !connected {
            std::thread::sleep(Duration::from_secs(5));
            if try_connect(&mut client) {
                connected = true;
                if let Some(cmd) = pending.clone() {
                    if let Err(e) = cmd.apply(&mut client) {
                        eprintln!("[discord] apply after reconnect: {e}");
                        connected = false;
                    }
                }
            }
            continue;
        }

        match rx.recv_timeout(Duration::from_secs(1)) {
            Ok(cmd) => {
                if let Err(e) = cmd.apply(&mut client) {
                    eprintln!("[discord] command failed: {e}");
                    connected = false;
                }
                pending = Some(cmd.clone());
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
}