//! Mermaid diagrams drawn on this Mac, for the planning panel's flows and
//! architecture changes: Mermaid's own command line (`@mermaid-js/mermaid-cli`
//! through npx, in a login shell for the PATH) renders each to a PNG, kept
//! by a hash of its source in `diagrams/` under Gannin's folder, so a
//! diagram is drawn once and again only when it changes. The first use
//! fetches the renderer and its browser, which takes a minute.
//!
//! Drawing happens on a thread of its own; `generation` moves on each time
//! one finishes, for views to redraw. Without Node, or when a diagram
//! won't draw, the reason is kept beside it and its source shows instead.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

/// The renderer, pinned so every Mac draws the same.
const CLI: &str = "@mermaid-js/mermaid-cli@11.4.2";

static GENERATION: AtomicU64 = AtomicU64::new(0);

fn drawing() -> &'static Mutex<HashSet<String>> {
    static DRAWING: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    DRAWING.get_or_init(|| Mutex::new(HashSet::new()))
}

fn dir() -> PathBuf {
    crate::paths::app_dir().join("diagrams")
}

fn key(source: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    CLI.hash(&mut hasher);
    source.trim().hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

/// Moves on each time a diagram is drawn (or fails to be).
pub fn generation() -> u64 {
    GENERATION.load(Ordering::Relaxed)
}

pub enum Diagram {
    /// The PNG, and its size in points (drawn at twice that).
    Drawn(PathBuf, f32, f32),
    Drawing,
    Failed(String),
}

/// The diagram for `source`: drawn already, being drawn (started now if
/// it isn't), or why it couldn't be.
pub fn diagram(source: &str) -> Diagram {
    let key = key(source);
    let png = dir().join(format!("{key}.png"));
    if let Some((w, h)) = png_size(&png) {
        return Diagram::Drawn(png, w as f32 / 2.0, h as f32 / 2.0);
    }
    if let Ok(error) = std::fs::read_to_string(dir().join(format!("{key}.err"))) {
        return Diagram::Failed(error);
    }
    let start = drawing().lock().map(|mut d| d.insert(key.clone())).unwrap_or(false);
    if start {
        let source = source.trim().to_string();
        std::thread::spawn(move || {
            // One at a time: npx fetching the renderer twice at once trips
            // over itself, and one browser is plenty.
            static ONE: Mutex<()> = Mutex::new(());
            let _turn = ONE.lock();
            if let Err(error) = draw(&key, &source) {
                let _ = std::fs::write(dir().join(format!("{key}.err")), error);
            }
            if let Ok(mut d) = drawing().lock() {
                d.remove(&key);
            }
            GENERATION.fetch_add(1, Ordering::Relaxed);
        });
    }
    Diagram::Drawing
}

/// Forgets why a diagram failed, so it's tried again.
pub fn retry(source: &str) {
    let _ = std::fs::remove_file(dir().join(format!("{}.err", key(source))));
    GENERATION.fetch_add(1, Ordering::Relaxed);
}

fn draw(key: &str, source: &str) -> Result<(), String> {
    let dir = dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let input = dir.join(format!("{key}.mmd"));
    let output = dir.join(format!("{key}.png"));
    let partial = dir.join(format!("{key}.drawing.png"));
    std::fs::write(&input, source).map_err(|e| e.to_string())?;
    let quote = |p: &std::path::Path| format!("'{}'", p.to_string_lossy().replace('\'', "'\\''"));
    let line = format!(
        "command -v npx >/dev/null 2>&1 || {{ echo 'Drawing diagrams needs Node (npx), which isn'\"'\"'t on this Mac.' >&2; exit 127; }}; npx -y {CLI} -q -i {} -o {} -b white -s 2",
        quote(&input),
        quote(&partial)
    );
    let out = std::process::Command::new(crate::paths::shell()).args(["-l", "-c", &line]).current_dir(&dir).output().map_err(|e| format!("Couldn't run npx: {e}"))?;
    let _ = std::fs::remove_file(&input);
    if !out.status.success() || png_size(&partial).is_none() {
        let _ = std::fs::remove_file(&partial);
        let err = String::from_utf8_lossy(&out.stderr);
        let reason = err.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with("at ") && !l.contains("npm warn")).find(|l| l.contains("Error") || l.contains("error") || l.contains("Parse")).or_else(|| err.lines().map(str::trim).filter(|l| !l.is_empty()).last()).unwrap_or("Mermaid gave nothing back.");
        return Err(reason.to_string());
    }
    std::fs::rename(&partial, &output).map_err(|e| e.to_string())
}

/// A PNG's width and height in pixels, from its header.
fn png_size(path: &std::path::Path) -> Option<(u32, u32)> {
    use std::io::Read;
    let mut head = [0u8; 24];
    std::fs::File::open(path).ok()?.read_exact(&mut head).ok()?;
    (head[..8] == [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]).then(|| (u32::from_be_bytes(head[16..20].try_into().unwrap()), u32::from_be_bytes(head[20..24].try_into().unwrap())))
}
