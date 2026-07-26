//! Cancellazione, pausa e progress attraverso il confine FFI.

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crypto_core_rs::ControlFlags;

/// Token condiviso fra Swift e i thread Rust per annullare o mettere in pausa
/// un'operazione in corso (SPEC §5.3).
///
/// Swift lo conserva nel ViewModel per tutta la durata dell'operazione e lo
/// invalida al termine.
#[derive(uniffi::Object, Default)]
pub struct CancelToken {
    pub(crate) flags: ControlFlags,
}

#[uniffi::export]
impl CancelToken {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            flags: ControlFlags::new(),
        })
    }

    pub fn cancel(&self) {
        self.flags.request_cancel();
    }

    pub fn set_paused(&self, paused: bool) {
        self.flags.set_pause(paused);
    }

    pub fn is_cancelled(&self) -> bool {
        self.flags.cancel.load(Ordering::SeqCst)
    }
}

/// Notifiche di avanzamento verso Swift.
///
/// Viene invocato da un thread Rust, mai dal main actor: l'implementazione
/// Swift deve fare hop sul main actor prima di toccare stato osservabile
/// (SPEC §7).
#[uniffi::export(with_foreign)]
pub trait ProgressListener: Send + Sync {
    fn on_progress(&self, stage: String, done: u64, total: u64);
}

/// Intervallo minimo fra due notifiche: ~10 aggiornamenti al secondo.
const THROTTLE: Duration = Duration::from_millis(100);

/// Riduce la frequenza delle notifiche di progress.
///
/// SPEC §7 colloca il throttling in Swift. Farlo qui è strettamente migliore:
/// ogni notifica è un attraversamento del confine FFI, e su un file grande il
/// core ne emette migliaia al secondo. Filtrandole in Rust si evita di pagarne
/// il costo per poi scartarle.
///
/// L'ultima notifica di ogni stage (`done == total`) passa **sempre**:
/// scartarla lascerebbe la barra ferma appena sotto il 100%.
pub(crate) struct Throttled {
    listener: Option<Arc<dyn ProgressListener>>,
    last_emit: Option<Instant>,
    last_stage: String,
}

impl Throttled {
    pub(crate) fn new(listener: Option<Arc<dyn ProgressListener>>) -> Self {
        Self {
            listener,
            last_emit: None,
            last_stage: String::new(),
        }
    }

    pub(crate) fn emit(&mut self, stage: &str, done: u64, total: u64) {
        let Some(listener) = &self.listener else {
            return;
        };

        let is_final = total > 0 && done >= total;
        let stage_changed = stage != self.last_stage;
        let due = self.last_emit.is_none_or(|t| t.elapsed() >= THROTTLE);

        if is_final || stage_changed || due {
            listener.on_progress(stage.to_string(), done, total);
            self.last_emit = Some(Instant::now());
            self.last_stage = stage.to_string();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    #[derive(Default)]
    struct Counter {
        calls: AtomicUsize,
    }

    impl ProgressListener for Counter {
        fn on_progress(&self, _stage: String, _done: u64, _total: u64) {
            self.calls.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[test]
    fn token_riflette_la_cancellazione() {
        let t = CancelToken::new();
        assert!(!t.is_cancelled());
        t.cancel();
        assert!(t.is_cancelled());
    }

    #[test]
    fn throttling_scarta_le_notifiche_ravvicinate() {
        let counter = Arc::new(Counter::default());
        let mut th = Throttled::new(Some(counter.clone()));

        // 1000 notifiche intermedie dello stesso stage in rapida successione.
        for i in 0..1000 {
            th.emit("encrypt", i, 10_000);
        }

        let calls = counter.calls.load(Ordering::SeqCst);
        assert!(calls < 20, "atteso throttling aggressivo, {calls} chiamate");
        assert!(calls >= 1, "la prima notifica deve passare");
    }

    #[test]
    fn la_notifica_finale_passa_sempre() {
        let counter = Arc::new(Counter::default());
        let mut th = Throttled::new(Some(counter.clone()));

        th.emit("encrypt", 1, 100);
        let after_first = counter.calls.load(Ordering::SeqCst);
        // Subito dopo, quindi normalmente scartata dal throttling.
        th.emit("encrypt", 100, 100);

        assert_eq!(
            counter.calls.load(Ordering::SeqCst),
            after_first + 1,
            "done == total deve passare anche dentro la finestra di throttling"
        );
    }

    #[test]
    fn il_cambio_di_stage_passa_sempre() {
        let counter = Arc::new(Counter::default());
        let mut th = Throttled::new(Some(counter.clone()));

        th.emit("archiving", 1, 100);
        let after_first = counter.calls.load(Ordering::SeqCst);
        th.emit("encrypt", 1, 100);

        assert_eq!(counter.calls.load(Ordering::SeqCst), after_first + 1);
    }
}
